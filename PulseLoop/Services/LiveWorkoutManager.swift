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
        polling.start(sessionID: session.id)
        session.liveActivityID = liveActivity.start(
            sessionID: session.id.uuidString,
            activityName: ActivityMeta.label(type),
            activityType: type,
            startDate: timerStart(session),
            usesGps: useGps
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
        push(session, status: "paused", force: true)
    }

    func resume(_ session: ActivitySession) {
        ActivityRecorderService.resume(session, context: context)
        if session.useGps { gps.start(sessionId: session.id, activityType: session.type) }
        polling.resume()
        push(session, status: "recording", force: true)
    }

    func finish(_ session: ActivitySession) {
        gps.stop()
        polling.stop()
        liveActivity.end(sessionID: session.id.uuidString)
        ActivityRecorderService.finish(session, context: context)
    }

    func cancel(_ session: ActivitySession) {
        gps.stop()
        polling.stop()
        liveActivity.end(sessionID: session.id.uuidString)
        ActivityRecorderService.cancel(session, context: context)
    }

    // MARK: - Live Activity sync (called from the live screen's per-second tick)

    /// Push current state to the Live Activity, throttled: only when distance moved ≥ 30 m, or
    /// ≥ 20 s elapsed, or `force` (status change). Duration counts itself in the widget.
    func syncLiveActivity(_ session: ActivitySession) {
        push(session, status: session.status == .paused ? "paused" : "recording", force: false)
    }

    private func push(_ session: ActivitySession, status: String, force: Bool) {
        let distance = acceptedDistance(session.id)
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
                lastUpdated: Date()
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
            polling.recoverIfNeeded(activeSession: active)
            push(active, status: "recording", force: true)
        }
        applyPendingCommand()
    }

    /// Ensure the workout the live screen is showing is actively recording (polling + GPS + Live
    /// Activity). Called from `RecordLiveView.onAppear`, so the session the user is looking at always
    /// records — even after a relaunch where the freshness heuristic would otherwise skip it.
    func ensureActive(_ session: ActivitySession) {
        guard session.status == .recording else { return }
        if session.useGps && !gps.isTracking { gps.start(sessionId: session.id, activityType: session.type) }
        polling.recoverIfNeeded(activeSession: session)
        if session.liveActivityID == nil {
            session.liveActivityID = liveActivity.start(
                sessionID: session.id.uuidString,
                activityName: ActivityMeta.label(session.type),
                activityType: session.type,
                startDate: timerStart(session),
                usesGps: session.useGps
            )
        }
        push(session, status: "recording", force: true)
    }

    /// A recording session counts as live only if it saw activity recently; otherwise it was
    /// abandoned (the app didn't get to finish/cancel it) and must not keep polling.
    private func isFreshlyActive(_ session: ActivitySession) -> Bool {
        let last = [session.lastSensorPollAt, session.lastGpsPointAt].compactMap { $0 }.max() ?? session.startedAt
        return Date().timeIntervalSince(last) < 180
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

    private func acceptedDistance(_ sessionId: UUID) -> Double {
        let points = ActivityRepository.gpsPoints(sessionId: sessionId, context: context).filter { $0.accepted }
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + haversine($1.0, $1.1) }
    }

    private func haversine(_ a: ActivityGpsPoint, _ b: ActivityGpsPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dPhi = (b.latitude - a.latitude) * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(p1) * cos(p2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    private func paceSecondsPerKm(distanceMeters: Double, durationSeconds: Int) -> Double? {
        guard distanceMeters >= 50, durationSeconds > 0 else { return nil }
        return Double(durationSeconds) / (distanceMeters / 1000)
    }
}
