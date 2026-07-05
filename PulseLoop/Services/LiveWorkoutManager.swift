import Foundation
import SwiftData

/// Single orchestrator for a live workout. Composes the recorder state machine, GPS recorder,
/// deterministic sensor polling, and the Live Activity so the views stay mostly UI. Injected via
/// `.environment(...)` like `RingSyncCoordinator` / `GpsRouteRecorder`.
@MainActor
@Observable
final class LiveWorkoutManager {
    private let coordinator: RingSyncCoordinator
    let gps: GpsRouteRecorder
    private let polling: WorkoutSensorPollingService
    private let liveActivity: WorkoutLiveActivityService
    private let context: ModelContext

    /// Set when a Live Activity / deep link asks the app to open a specific workout.
    private(set) var pendingDeepLinkSession: UUID?

    /// The vitals plan for the current workout (nil when nothing is recording). Computed from the
    /// connected device's capabilities at start/recovery; the live screen reads it to label the
    /// HR/SpO₂ tiles honestly (stream vs spot vs ring log).
    private(set) var activePlan: WorkoutVitalsPlan?

    // Throttle state for Live Activity pushes (duration auto-counts in the widget; we only push
    // on meaningful distance/HR/status changes).
    private var lastPushedDistance: Double = 0
    private var lastPushAt: Date = .distantPast

    init(coordinator: RingSyncCoordinator, gps: GpsRouteRecorder, context: ModelContext) {
        self.coordinator = coordinator
        self.gps = gps
        self.context = context
        self.polling = WorkoutSensorPollingService(coordinator: coordinator, context: context)
        self.liveActivity = WorkoutLiveActivityService()
        // After each real sensor poll (including background polls), refresh the Live Activity so the
        // Lock Screen HR/SpO₂ stay current even though the foreground per-second tick isn't running.
        self.polling.onPollCompleted = { [weak self] in self?.refreshLiveActivityForActiveSession() }
    }

    // MARK: - Lifecycle

    @discardableResult
    func start(type: String, useGps: Bool) -> ActivitySession {
        // Enforce a single active workout: cancel any orphaned recording/paused sessions left
        // over from a prior run (e.g. the app was killed mid-workout) so they can't keep being
        // recovered + polled in the background.
        for orphan in ActivityRepository.sessions(context: context)
            .filter({ $0.status == .recording || $0.status == .paused }) {
            ActivityRecorderService.cancel(orphan, context: context)
        }
        polling.stop()
        gps.stop()

        let session = ActivityRecorderService.start(type: type, useGps: useGps, notes: nil, context: context)
        if useGps { gps.start(sessionId: session.id, activityType: type) }
        let plan = vitalsPlan()
        activePlan = plan
        session.vitalsModeRaw = plan.vitalsModeRaw
        polling.start(sessionID: session.id, plan: plan)
        if plan.hrMode == .stream { coordinator.startWorkoutHeartRate() }
        if plan.bumpRingInterval { coordinator.applyWorkoutMeasurementInterval() }
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
        try? context.save()
        return session
    }

    func pause(_ session: ActivitySession) {
        ActivityRecorderService.pause(session, context: context)
        gps.stop()
        polling.pause()
        coordinator.stopWorkoutHeartRate()
        push(session, status: "paused", force: true)
    }

    func resume(_ session: ActivitySession) {
        ActivityRecorderService.resume(session, context: context)
        if session.useGps { gps.start(sessionId: session.id, activityType: session.type) }
        polling.resume()
        if (activePlan ?? vitalsPlan()).hrMode == .stream { coordinator.startWorkoutHeartRate() }
        push(session, status: "recording", force: true)
    }

    func finish(_ session: ActivitySession) {
        gps.stop()
        polling.stop()
        endWorkoutVitals()
        liveActivity.end(sessionID: session.id.uuidString)
        ActivityRecorderService.finish(session, context: context)
        // Reconcile with the ring's own log: anything it recorded while the phone was away lands
        // in this session (finished-window linking) and the summary refreshes as samples arrive.
        coordinator.syncWorkoutVitals()
    }

    func cancel(_ session: ActivitySession) {
        gps.stop()
        polling.stop()
        endWorkoutVitals()
        liveActivity.end(sessionID: session.id.uuidString)
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

    // MARK: - Live Activity sync (called from the live screen's per-second tick)

    /// Push current state to the Live Activity, throttled: only when distance moved ≥ 30 m, or
    /// ≥ 20 s elapsed, or `force` (status change). Duration counts itself in the widget.
    func syncLiveActivity(_ session: ActivitySession) {
        push(session, status: session.status == .paused ? "paused" : "recording", force: false)
    }

    private func push(_ session: ActivitySession, status: String, force: Bool) {
        let distance = acceptedDistance(session)
        let now = Date()
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
                pausedAt: status == "paused" ? now : nil,
                usesGps: session.useGps,
                distanceMeters: session.useGps ? distance : 0,
                paceSecondsPerKm: session.useGps ? pace : nil,
                lastHeartRate: coordinator.latestHRValue,
                lastSpO2: coordinator.latestSpO2Value,
                activityType: session.type,
                lastUpdated: Date(),
                useImperial: usesImperialUnits
            )
        )
    }

    /// Effective timer origin so the widget's self-counting `Text(timerInterval:)` shows elapsed time
    /// excluding paused spans: `now - timerStart == startedAt..now minus totalPauseSeconds`.
    private func timerStart(_ session: ActivitySession) -> Date {
        session.startedAt.addingTimeInterval(session.totalPauseSeconds)
    }

    /// Refresh the Live Activity for the currently recording session (used by the poll-completed hook
    /// so background HR/SpO₂ reads reach the Lock Screen). No-op if nothing is recording.
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
        if let active = ActivityRepository.sessions(context: context)
            .first(where: { $0.status == .recording }), isFreshlyActive(active) {
            if active.useGps && !gps.isTracking { gps.start(sessionId: active.id, activityType: active.type) }
            reattachVitals(active)
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

    // MARK: - Distance helpers (accepted points only; matches ActivityService.gpsDistance)

    private func acceptedDistance(_ session: ActivitySession) -> Double {
        let points = ActivityRepository.gpsPoints(sessionId: session.id, context: context)
        return RouteDistanceEngine.distanceMeters(points, profile: .profile(for: session.type))
    }

    private func paceSecondsPerKm(distanceMeters: Double, durationSeconds: Int) -> Double? {
        guard distanceMeters >= 50, durationSeconds > 0 else { return nil }
        return Double(durationSeconds) / (distanceMeters / 1000)
    }
}
