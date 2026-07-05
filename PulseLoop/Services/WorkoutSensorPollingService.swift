import Foundation
import Combine
import SwiftData

/// Sensor capture companion for an active workout, driven by the session's `WorkoutVitalsPlan`:
///
/// - HR `.stream`: the continuous live stream (started by `LiveWorkoutManager`) delivers samples on
///   its own; this service only runs a periodic health check that restarts a stalled stream and
///   keeps `lastSensorPollAt` fresh for session recovery.
/// - HR `.spotPoll` (devices without a realtime stream): the legacy deterministic one-shot reads via
///   `RingSyncCoordinator.measureHR()`.
/// - SpO2 `.spotPoll` (devices with instant SpO2): periodic `measureSpO2()` reads. `.ringLog`/`.off`
///   never attempt a read — Colmi has no instant SpO2, so polling it only produced failures.
///
/// Every spot attempt / stream stall is recorded as an `ActivitySensorPollEvent` for the
/// recording-quality report. HR and SpO2 reads never overlap — there is only one ring.
@MainActor
final class WorkoutSensorPollingService: ObservableObject {
    private enum SensorKind {
        case heartRate
        case spo2
    }

    private let coordinator: RingSyncCoordinator
    private let context: ModelContext

    private var sessionID: UUID?
    private var plan: WorkoutVitalsPlan = .spotFallback
    private var pollingTask: Task<Void, Never>?
    private var nextHRPoll = Date.distantPast
    private var nextSpO2Poll = Date.distantPast
    /// Single in-flight guard: HR and SpO2 must never overlap (one ring, one read at a time).
    private var isPolling = false

    /// Poll cadence comes from the user's workout preferences, read at use-time so changes apply on
    /// the next poll. (Which sensors are captured at all is baked into the plan at session start.)
    private var prefs: WorkoutPrefs { WorkoutPrefsStore.shared.settings }
    private var hrInterval: TimeInterval { TimeInterval(prefs.hrPollIntervalSeconds) }
    private var spo2Interval: TimeInterval { TimeInterval(prefs.spo2PollIntervalSeconds) }
    /// While the ring is disconnected we don't burn the full interval — retry soon so a reconnect
    /// triggers a real read within ~10 s instead of up to a minute later.
    private let disconnectedRetry: TimeInterval = 10
    /// Stream mode: how often to check that samples are still flowing…
    private let streamCheckInterval: TimeInterval = 30
    /// …and how stale the newest sample may be (while connected) before the stream counts as
    /// stalled and gets restarted.
    private let streamStallSeconds: TimeInterval = 45

    /// Fired after each real read attempt on a connected ring (success or failure). Lets the
    /// orchestrator refresh the Live Activity so background HR/SpO₂ reach the Lock Screen.
    var onPollCompleted: (() -> Void)?

    init(coordinator: RingSyncCoordinator, context: ModelContext) {
        self.coordinator = coordinator
        self.context = context
    }

    // MARK: - Lifecycle

    func start(sessionID: UUID, plan: WorkoutVitalsPlan) {
        self.sessionID = sessionID
        self.plan = plan
        nextHRPoll = .now
        nextSpO2Poll = .now
        launchLoop()
    }

    func pause() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func resume() {
        guard sessionID != nil else { return }
        nextHRPoll = .now
        nextSpO2Poll = .now
        launchLoop()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        sessionID = nil
    }

    /// Called on app foreground / resume. Forces a fresh read if the latest persisted samples are
    /// stale, and (re)launches the loop if the session is recording but the task isn't running
    /// (e.g. after a relaunch).
    func recoverIfNeeded(activeSession: ActivitySession?, plan: WorkoutVitalsPlan) {
        guard let activeSession, activeSession.status == .recording else { return }
        self.plan = plan

        let samples = ActivityRepository.samples(sessionId: activeSession.id, context: context)
        let latestHR = samples.last { $0.kind == "hr" }?.timestamp
        let latestSpO2 = samples.last { $0.kind == "spo2" }?.timestamp
        let now = Date()

        if let latestHR, now.timeIntervalSince(latestHR) < 90 {
            // HR is fresh; leave the schedule untouched.
        } else {
            nextHRPoll = .now
        }

        if let latestSpO2, now.timeIntervalSince(latestSpO2) < 360 {
            // SpO2 is fresh; leave the schedule untouched.
        } else {
            nextSpO2Poll = .now
        }

        if pollingTask == nil {
            sessionID = activeSession.id
            launchLoop()
        }
    }

    // MARK: - Loop

    private func launchLoop() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()

                switch self.plan.hrMode {
                case .stream:
                    // Samples arrive on their own; just watch for a stalled stream.
                    if now >= self.nextHRPoll {
                        self.checkStreamHealth()
                        self.nextHRPoll = Date().addingTimeInterval(self.streamCheckInterval)
                    }
                case .spotPoll:
                    if !self.isPolling, now >= self.nextHRPoll {
                        let didRead = await self.poll(kind: .heartRate)
                        self.nextHRPoll = Date().addingTimeInterval(didRead ? self.hrInterval : self.disconnectedRetry)
                    } else if now >= self.nextHRPoll {
                        self.record(kind: "hr", status: "skipped")
                        self.nextHRPoll = Date().addingTimeInterval(self.hrInterval)
                    }
                case .off:
                    self.nextHRPoll = Date().addingTimeInterval(self.hrInterval)
                }

                switch self.plan.spo2Mode {
                case .spotPoll:
                    if !self.isPolling, now >= self.nextSpO2Poll {
                        let didRead = await self.poll(kind: .spo2)
                        self.nextSpO2Poll = Date().addingTimeInterval(didRead ? self.spo2Interval : self.disconnectedRetry)
                    } else if now >= self.nextSpO2Poll {
                        self.record(kind: "spo2", status: "skipped")
                        self.nextSpO2Poll = Date().addingTimeInterval(self.spo2Interval)
                    }
                case .ringLog, .off:
                    // No instant reading exists (or capture is off) — never attempt one.
                    self.nextSpO2Poll = Date().addingTimeInterval(self.spo2Interval)
                }

                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Stream health (HR `.stream` mode)

    /// The live HR stream should land a sample every few seconds. Track the newest linked sample so
    /// session recovery sees the workout as fresh, and if samples stop while the ring is connected,
    /// record the stall and re-issue the stream command (firmware occasionally drops the stream).
    private func checkStreamHealth() {
        guard let sessionID,
              let session = ActivityRepository.sessions(context: context).first(where: { $0.id == sessionID }),
              session.status == .recording else { return }
        let latest = ActivityRepository.samples(sessionId: sessionID, context: context)
            .last { $0.kind == MeasurementKind.heartRate.rawValue }?.timestamp
        if let latest, latest > (session.lastSensorPollAt ?? .distantPast) {
            session.lastSensorPollAt = latest
            try? context.save()
        }
        guard coordinator.isConnected else { return }
        let age = Date().timeIntervalSince(latest ?? session.startedAt)
        if age > streamStallSeconds {
            record(kind: "hr_stream", status: "stalled", errorMessage: "no sample in \(Int(age))s")
            coordinator.restartWorkoutHeartRateIfActive()
        }
        onPollCompleted?()
    }

    // MARK: - Polling

    /// Attempts one sensor read. Returns `true` if a real read happened on a connected ring (so the
    /// loop waits the full interval), `false` if the ring was disconnected (so the loop retries soon).
    @discardableResult
    private func poll(kind: SensorKind) async -> Bool {
        guard let sessionID else { return true }
        let kindRaw = kind == .heartRate ? "hr" : "spo2"

        // Defensive: a finished/cancelled/missing session should never trigger a real read.
        guard let session = ActivityRepository.sessions(context: context).first(where: { $0.id == sessionID }),
              session.status == .recording else {
            record(kind: kindRaw, status: "skipped")
            return true
        }

        // Ring is down (out of range / reconnecting): don't fail the read — skip and retry soon so
        // we resume promptly once it reconnects, without piling up false failures or hammering it.
        guard coordinator.isConnected else {
            record(kind: kindRaw, status: "skipped", errorMessage: "ring disconnected")
            return false
        }

        isPolling = true
        defer { isPolling = false }

        record(kind: kindRaw, status: "started")

        let value: Int? = kind == .heartRate
            ? await coordinator.measureHR()
            : await coordinator.measureSpO2()

        if let value {
            switch kind {
            case .heartRate: session.hrPollCount += 1
            case .spo2: session.spo2PollCount += 1
            }
            session.lastSensorPollAt = Date()
            record(kind: kindRaw, status: "success", value: Double(value))
        } else {
            switch kind {
            case .heartRate: session.hrPollFailureCount += 1
            case .spo2: session.spo2PollFailureCount += 1
            }
            record(kind: kindRaw, status: "failed", errorMessage: "no reading (disconnected or timeout)")
        }
        onPollCompleted?()
        return true
    }

    // MARK: - Bookkeeping

    private func record(kind: String, status: String, value: Double? = nil, errorMessage: String? = nil) {
        guard let sessionID else { return }
        context.insert(
            ActivitySensorPollEvent(
                sessionId: sessionID,
                kind: kind,
                status: status,
                value: value,
                errorMessage: errorMessage
            )
        )
        try? context.save()
    }
}
