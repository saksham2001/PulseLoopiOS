import Foundation
import SwiftData

/// Single orchestrator for a live workout. Composes the recorder state machine, GPS recorder,
/// deterministic sensor polling, and the Live Activity so the views stay mostly UI. Injected via
/// `.environment(...)` like `RingSyncCoordinator` / `GpsRouteRecorder`.
///
/// Also owns `LiveWorkoutStats` — the O(1) rolling stats fed straight from `PulseEventBus`
/// (GPS fixes, HR/SpO₂ samples) that the live screen and Live Activity read, so nothing on the
/// per-second render path ever fetches or re-walks the whole route.
@MainActor
@Observable
final class LiveWorkoutManager {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private let coordinator: RingSyncCoordinator
    let gps: GpsRouteRecorder
    private let polling: WorkoutSensorPollingService
    private let liveActivity: WorkoutLiveActivityService
    private let context: ModelContext

    /// Set when a Live Activity / deep link asks the app to open a specific workout.
    private(set) var pendingDeepLinkSession: UUID?

    /// The vitals plan for the current workout (nil when nothing is recording). Computed from the
    /// connected device's capabilities at start/recovery; the live screen reads it to label the
    /// HR/SpO₂ tiles honestly (stream vs spot vs ring log). Can degrade mid-workout (stream → spot)
    /// when the polling service abandons a dead stream.
    private(set) var activePlan: WorkoutVitalsPlan?

    /// Rolling stats for the recording session (nil when nothing is recording).
    private(set) var stats: LiveWorkoutStats?

    // Throttle state for Live Activity pushes (duration auto-counts in the widget; we only push
    // on meaningful distance/HR/status changes).
    private var lastPushedDistance: Double = 0
    private var lastPushAt: Date = .distantPast
    /// Feeds `stats` from the event bus for the lifetime of the manager (events are ignored while
    /// no workout is recording, so all-day syncs can't storm it).
    private var eventTask: Task<Void, Never>?
    /// Time-based Live Activity refresh while a workout records — replaces the old dependency on
    /// the live screen's per-second tick, so the Lock Screen stays current even when the user
    /// navigates elsewhere in the app.
    private var pushTicker: Task<Void, Never>?

    init(coordinator: RingSyncCoordinator, gps: GpsRouteRecorder, context: ModelContext) {
        self.coordinator = coordinator
        self.gps = gps
        self.context = context
        self.polling = WorkoutSensorPollingService(coordinator: coordinator, context: context)
        self.liveActivity = WorkoutLiveActivityService()
        // After each real sensor poll (including background polls), refresh the Live Activity so the
        // Lock Screen HR/SpO₂ stay current even though the foreground per-second tick isn't running.
        self.polling.onPollCompleted = { [weak self] in self?.refreshLiveActivityForActiveSession() }
        // The stream died mid-workout and polling degraded HR to spot reads — keep the plan (and
        // therefore the tile subtitles) honest.
        self.polling.onPlanDegraded = { [weak self] plan in self?.activePlan = plan }
        startEventSubscription()
    }

    // MARK: - Event bus → live stats

    private func startEventSubscription() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                guard let self else { return }
                self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: PulseEvent) {
        guard let stats else { return }   // nothing recording — ignore (all-day syncs etc.)
        switch event {
        case let .gpsPoint(sessionId, latitude, longitude, _, horizontalAccuracy, _, _, accepted, _, timestamp):
            guard accepted, sessionId == stats.sessionId else { return }
            stats.addFix(latitude: latitude, longitude: longitude,
                         horizontalAccuracy: horizontalAccuracy, timestamp: timestamp)
            // Distance-based Live Activity cadence (time-based comes from the ticker).
            if abs(stats.distanceMeters - lastPushedDistance) >= 30 {
                refreshLiveActivityForActiveSession()
            }
        case let .heartRateSample(bpm, timestamp):
            stats.recordHR(bpm, at: timestamp, source: .live)
        case let .historyMeasurement(kind, value, timestamp):
            switch kind {
            case .heartRate:
                // Ring-log backfill: only samples inside the workout window may fill the tile.
                guard timestamp >= stats.startedAt else { return }
                stats.recordHR(Int(value), at: timestamp, source: .ringLog)
            case .spo2:
                // Ring-log SpO₂ (Colmi has no instant reading): tile shows the newest all-day value.
                stats.recordSpO2(Int(value), at: timestamp)
            default:
                break
            }
        case let .spo2Result(value, timestamp):
            stats.recordSpO2(value, at: timestamp)
        default:
            break
        }
    }

    /// Build (or rebuild after relaunch) the rolling stats for a session. Seeding replays the
    /// session's persisted points through the same accumulator, so recovered totals match.
    private func ensureStats(for session: ActivitySession) {
        if stats?.sessionId == session.id { return }
        let fresh = LiveWorkoutStats(
            sessionId: session.id,
            startedAt: session.startedAt,
            activityType: session.type,
            useGps: session.useGps,
            splitMeters: usesImperialUnits ? 1609.344 : 1000
        )
        fresh.seed(
            points: session.useGps ? ActivityRepository.gpsPoints(sessionId: session.id, context: context) : [],
            lastHRSample: ActivityRepository.latestSample(sessionId: session.id, kind: MeasurementKind.heartRate.rawValue, context: context),
            lastSpO2Sample: ActivityRepository.latestSample(sessionId: session.id, kind: MeasurementKind.spo2.rawValue, context: context)
        )
        seedRingLogSpO2(into: fresh)
        if session.status == .paused {
            let pausedEvent = ActivityRepository.events(sessionId: session.id, context: context).last { $0.kind == "paused" }
            fresh.setPaused(pausedEvent?.timestamp ?? Date())
        }
        stats = fresh
    }

    /// Colmi-style ring-log SpO₂: the tile shows the newest all-day log value, which may predate
    /// the workout.
    private func seedRingLogSpO2(into stats: LiveWorkoutStats) {
        guard (activePlan ?? vitalsPlan()).spo2Mode == .ringLog,
              let latest = MetricsRepository.latestMeasurement(kind: .spo2, context: context) else { return }
        stats.seedSpO2(value: Int(latest.value), at: latest.timestamp)
    }

    // MARK: - Lifecycle

    @discardableResult
    func start(type: String, useGps: Bool) -> ActivitySession {
        // Enforce a single active workout: cancel any orphaned recording/paused sessions left
        // over from a prior run (e.g. the app was killed mid-workout) so they can't keep being
        // recovered + polled in the background.
        for orphan in ActivityRepository.sessions(context: context)
            .filter({ $0.status == .recording || $0.status == .paused }) {
            liveActivity.end(sessionID: orphan.id.uuidString, finalState: nil)
            ActivityRecorderService.cancel(orphan, context: context)
        }
        polling.stop()
        gps.stop()

        let session = ActivityRecorderService.start(type: type, useGps: useGps, notes: nil, context: context)
        if useGps { gps.start(sessionId: session.id, activityType: type) }
        let plan = vitalsPlan()
        activePlan = plan
        session.vitalsModeRaw = plan.vitalsModeRaw
        stats = LiveWorkoutStats(
            sessionId: session.id,
            startedAt: session.startedAt,
            activityType: type,
            useGps: useGps,
            splitMeters: usesImperialUnits ? 1609.344 : 1000
        )
        if let stats { seedRingLogSpO2(into: stats) }
        polling.start(sessionID: session.id, plan: plan)
        if plan.hrMode == .stream { coordinator.startWorkoutHeartRate() }
        if plan.bumpRingInterval {
            coordinator.applyWorkoutMeasurementInterval(hrIntervalSeconds: WorkoutPrefsStore.shared.settings.hrPollIntervalSeconds)
        }
        session.liveActivityID = liveActivity.start(
            sessionID: session.id.uuidString,
            activityName: ActivityMeta.label(type),
            activityType: type,
            startDate: timerStart(session),
            displayOptions: WorkoutLiveActivityDisplayOptions(
                usesGps: useGps,
                useImperial: usesImperialUnits
            )
        )
        lastPushedDistance = 0
        lastPushAt = Date()
        startPushTicker()
        try? context.save()
        return session
    }

    func pause(_ session: ActivitySession) {
        ActivityRecorderService.pause(session, context: context)
        gps.stop()
        polling.pause()
        coordinator.stopWorkoutHeartRate()
        stats?.setPaused(Date())
        push(session, status: "paused", force: true)
    }

    func resume(_ session: ActivitySession) {
        ActivityRecorderService.resume(session, context: context)
        if session.useGps { gps.start(sessionId: session.id, activityType: session.type) }
        polling.resume()
        if (activePlan ?? vitalsPlan()).hrMode == .stream { coordinator.startWorkoutHeartRate() }
        stats?.setPaused(nil)
        push(session, status: "recording", force: true)
    }

    func finish(_ session: ActivitySession) {
        gps.stop()
        polling.stop()
        stopPushTicker()
        endWorkoutVitals()
        // Summary first (endedAt / distance / avg HR land on the session), then hand the Live
        // Activity its final "Workout complete" card — it lingers ~10 min with the real stats.
        ActivityRecorderService.finish(session, context: context)
        liveActivity.end(sessionID: session.id.uuidString, finalState: finishedState(session))
        stats = nil
        // Reconcile with the ring's own log: anything it recorded while the phone was away lands
        // in this session (finished-window linking) and the summary refreshes as samples arrive.
        coordinator.syncWorkoutVitals()
    }

    func cancel(_ session: ActivitySession) {
        gps.stop()
        polling.stop()
        stopPushTicker()
        endWorkoutVitals()
        liveActivity.end(sessionID: session.id.uuidString, finalState: nil)
        stats = nil
        ActivityRecorderService.cancel(session, context: context)
    }

    /// Tear down workout vitals capture: stop the live HR stream and put the ring's all-day
    /// measurement config back to the user's persisted settings (undoes the workout interval bump).
    private func endWorkoutVitals() {
        coordinator.stopWorkoutHeartRate()
        if activePlan?.bumpRingInterval == true { coordinator.applyMeasurementSettings() }
        activePlan = nil
    }

    /// Capability-driven capture plan for the currently paired device (spot fallback when no
    /// device/capabilities are stamped yet).
    private func vitalsPlan() -> WorkoutVitalsPlan {
        let capabilities = DeviceRepository.current(context: context)?.capabilities ?? []
        return WorkoutVitalsPlan.plan(for: capabilities, prefs: WorkoutPrefsStore.shared.settings)
    }

    // MARK: - Live Activity sync

    private func startPushTicker() {
        pushTicker?.cancel()
        pushTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                self.refreshLiveActivityForActiveSession()
            }
        }
    }

    private func stopPushTicker() {
        pushTicker?.cancel()
        pushTicker = nil
    }

    /// Push current state to the Live Activity, throttled: only when distance moved ≥ 30 m, or
    /// ≥ 20 s elapsed, or `force` (status change). All inputs are O(1) reads from `stats`.
    private func push(_ session: ActivitySession, status: String, force: Bool) {
        let now = Date()
        let distance = stats?.distanceMeters ?? 0
        let movedEnough = abs(distance - lastPushedDistance) >= 30
        let timeEnough = now.timeIntervalSince(lastPushAt) >= 20
        guard force || movedEnough || timeEnough else { return }
        lastPushedDistance = distance
        lastPushAt = now

        let elapsed = max(0, Int((session.endedAt ?? now).timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
        let pace = paceSecondsPerKm(distanceMeters: distance, durationSeconds: elapsed)
        liveActivity.update(
            sessionID: session.id.uuidString,
            state: WorkoutActivityAttributes.ContentState(
                status: status,
                elapsedSeconds: elapsed,
                startDate: timerStart(session),
                pausedAt: status == "paused" ? (stats?.pausedAt ?? now) : nil,
                usesGps: session.useGps,
                distanceMeters: session.useGps ? distance : 0,
                paceSecondsPerKm: session.useGps ? pace : nil,
                lastHeartRate: stats?.lastHR?.value ?? coordinator.latestHRValue,
                lastSpO2: stats?.lastSpO2?.value ?? coordinator.latestSpO2Value,
                activityType: session.type,
                lastUpdated: Date(),
                useImperial: usesImperialUnits
            )
        )
    }

    /// Final Live Activity content: frozen timer + summary stats. Requires the finish summary to
    /// have run (endedAt / distanceMeters / avgHeartRate populated).
    private func finishedState(_ session: ActivitySession) -> WorkoutActivityAttributes.ContentState {
        let endedAt = session.endedAt ?? Date()
        let elapsed = max(0, Int(endedAt.timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
        let distance = session.distanceMeters ?? stats?.distanceMeters ?? 0
        return WorkoutActivityAttributes.ContentState(
            status: "finished",
            elapsedSeconds: elapsed,
            startDate: timerStart(session),
            pausedAt: nil,
            usesGps: session.useGps,
            distanceMeters: session.useGps ? distance : 0,
            paceSecondsPerKm: session.useGps ? paceSecondsPerKm(distanceMeters: distance, durationSeconds: elapsed) : nil,
            lastHeartRate: stats?.lastHR?.value ?? coordinator.latestHRValue,
            lastSpO2: stats?.lastSpO2?.value ?? coordinator.latestSpO2Value,
            activityType: session.type,
            lastUpdated: Date(),
            useImperial: usesImperialUnits,
            avgHeartRate: session.avgHeartRate.map { Int($0.rounded()) }
        )
    }

    /// Effective timer origin so the widget's self-counting `Text(timerInterval:)` shows elapsed time
    /// excluding paused spans: `now - timerStart == startedAt..now minus totalPauseSeconds`.
    private func timerStart(_ session: ActivitySession) -> Date {
        session.startedAt.addingTimeInterval(session.totalPauseSeconds)
    }

    /// Refresh the Live Activity for the currently recording session (poll hook, GPS distance
    /// cadence, and the 20 s ticker all land here). No-op if nothing is recording.
    private func refreshLiveActivityForActiveSession() {
        guard let session = ActivityRepository.sessions(context: context)
            .first(where: { $0.status == .recording }) else { return }
        push(session, status: "recording", force: true)
    }

    // MARK: - Recovery + deep link

    /// On launch / foreground: re-attach to an in-progress recording (restart GPS, catch up polling,
    /// refresh the Live Activity) and apply any pending Lock Screen command.
    ///
    /// Only resumes a session that is *freshly active* — i.e. it had a sensor poll or GPS fix in the
    /// last few minutes. This recovers a genuinely interrupted workout (app killed and relaunched
    /// quickly) without silently re-polling the ring for sessions that were abandoned and never
    /// finished (which would otherwise record HR every minute forever).
    func recover() {
        // Re-adopt (or clean up) Live Activities that survived an app relaunch — without this the
        // in-memory handle map is empty and update/end silently no-op, leaving a zombie card whose
        // timer counts for 48 h.
        let liveSessions = ActivityRepository.sessions(context: context)
            .filter { $0.status == .recording || $0.status == .paused }
        liveActivity.reattach(activeSessionIDs: Set(liveSessions.map { $0.id.uuidString }))

        if let active = liveSessions.first(where: { $0.status == .recording }), isFreshlyActive(active) {
            if active.useGps && !gps.isTracking { gps.start(sessionId: active.id, activityType: active.type) }
            ensureStats(for: active)
            reattachVitals(active)
            startPushTicker()
            push(active, status: "recording", force: true)
        }
        applyPendingCommand()
    }

    /// Recompute the plan and (re)start vitals capture for an in-progress session — shared by
    /// `recover()` and `ensureActive(_:)` so relaunch/foreground always restores the stream.
    private func reattachVitals(_ session: ActivitySession) {
        let plan = activePlan ?? vitalsPlan()
        activePlan = plan
        session.vitalsModeRaw = plan.vitalsModeRaw
        polling.recoverIfNeeded(activeSession: session, plan: plan)
        if plan.hrMode == .stream {
            coordinator.startWorkoutHeartRate()
            // A long silence means the phone was suspended while the ring kept logging on its own —
            // pull the ring log now so the chart gap fills without waiting for finish.
            let last = session.lastSensorPollAt ?? session.startedAt
            if Date().timeIntervalSince(last) > 300 { coordinator.syncWorkoutVitals() }
        }
    }

    /// Ensure the workout the live screen is showing is actively recording (polling + GPS + Live
    /// Activity). Called from `RecordLiveView.onAppear`, so the session the user is looking at always
    /// records — even after a relaunch where the freshness heuristic would otherwise skip it.
    func ensureActive(_ session: ActivitySession) {
        guard session.status == .recording || session.status == .paused else { return }
        ensureStats(for: session)
        guard session.status == .recording else { return }
        if session.useGps && !gps.isTracking { gps.start(sessionId: session.id, activityType: session.type) }
        reattachVitals(session)
        if session.liveActivityID == nil {
            session.liveActivityID = liveActivity.start(
                sessionID: session.id.uuidString,
                activityName: ActivityMeta.label(session.type),
                activityType: session.type,
                startDate: timerStart(session),
                displayOptions: WorkoutLiveActivityDisplayOptions(
                    usesGps: session.useGps,
                    useImperial: usesImperialUnits
                )
            )
        }
        startPushTicker()
        push(session, status: "recording", force: true)
    }

    /// A recording session counts as live only if it saw activity recently; otherwise it was
    /// abandoned (the app didn't get to finish/cancel it) and must not keep polling. Stream-mode
    /// sessions get a longer window: the phone can be suspended for a while with the ring still
    /// logging on its own, and the reconcile fills the gap on recovery.
    private func isFreshlyActive(_ session: ActivitySession) -> Bool {
        let last = [session.lastSensorPollAt, session.lastGpsPointAt].compactMap { $0 }.max() ?? session.startedAt
        let window: TimeInterval = session.vitalsModeRaw == "stream" ? 600 : 180
        return Date().timeIntervalSince(last) < window
    }

    private var usesImperialUnits: Bool {
        (ProfileRepository.profile(context: context)?.units ?? .metric) == .imperial
    }

    /// Consume a command written by a Live Activity App Intent (pause/resume/finish) via the App Group.
    private func applyPendingCommand() {
        guard let defaults = UserDefaults(suiteName: WorkoutAppGroup.suite),
              let command = defaults.string(forKey: WorkoutAppGroup.commandKey),
              let sessionString = defaults.string(forKey: WorkoutAppGroup.commandSessionKey),
              let sessionID = UUID(uuidString: sessionString),
              let session = ActivityRepository.sessions(context: context).first(where: { $0.id == sessionID })
        else { return }
        defaults.removeObject(forKey: WorkoutAppGroup.commandKey)
        defaults.removeObject(forKey: WorkoutAppGroup.commandSessionKey)

        switch command {
        case "pause" where session.status == .recording: pause(session)
        case "resume" where session.status == .paused: resume(session)
        case "finish": finish(session); pendingDeepLinkSession = sessionID
        default: break
        }
    }

    /// Called from the URL handler for `pulseloop://workout/<id>`.
    func requestOpen(sessionID: UUID) { pendingDeepLinkSession = sessionID }
    func clearDeepLink() { pendingDeepLinkSession = nil }

    private func paceSecondsPerKm(distanceMeters: Double, durationSeconds: Int) -> Double? {
        guard distanceMeters >= 50, durationSeconds > 0 else { return nil }
        return Double(durationSeconds) / (distanceMeters / 1000)
    }
}
