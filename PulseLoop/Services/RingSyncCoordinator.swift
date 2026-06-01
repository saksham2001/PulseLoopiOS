import Foundation
import SwiftData

/// High-level orchestration of ring command flows. Subscribes to `PulseEventBus` to track the
/// latest measurement values and completion signals, and exposes app-facing actions
/// (`syncNow`, `measureHR`, `measureSpO2`, `querySleep`, `setGoal`). It only *orchestrates*
/// command writes — persistence is handled by `EventPersistenceSubscriber`.
@MainActor
@Observable
final class RingSyncCoordinator {
    enum MeasureState: Equatable {
        case idle
        case measuring
        case done(Int)
        case failed
    }

    private(set) var hrState: MeasureState = .idle
    private(set) var spo2State: MeasureState = .idle
    private(set) var lastSyncAt: Date?

    /// Latest live values, mirrored for UI (e.g. the live workout screen) without a query.
    private(set) var latestHRValue: Int?
    private(set) var latestSpO2Value: Int?
    private(set) var workoutHRActive = false

    /// Warm-up windows from Protocol.md (HR ~10–15s, SpO2 ~35–45s).
    private let hrMeasureSeconds: UInt64 = 12
    private let spo2MeasureSeconds: UInt64 = 40

    private let client: RingBLEClient
    private let context: ModelContext
    private let encoder = RingEncoder()

    private var streamTask: Task<Void, Never>?

    init(client: RingBLEClient, context: ModelContext) {
        self.client = client
        self.context = context
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                guard let self else { continue }
                self.handle(event)
            }
        }
    }

    // MARK: - Actions

    /// Canonical startup sequence run on connect: status → time sync → locale → activity query
    /// → history (which yields the sleep timeline) → history measurements.
    func runStartupSequence() {
        client.enqueueWrite(encoder.makeStatusCommand())
        client.enqueueWrite(encoder.makeTimeSyncCommand())
        client.enqueueWrite(encoder.makeLocaleCommand())
        client.enqueueWrite(encoder.makeActivityQueryCommand())
        client.enqueueWrite(encoder.makeHistoryQueryCommand())
        client.enqueueWrite(encoder.makeHistoryMeasurementQueryCommand())
        lastSyncAt = Date()
    }

    func syncNow() {
        guard client.state == .connected else { return }
        runStartupSequence()
    }

    /// Pull-to-refresh entry point. When connected, re-run the sync sequence; otherwise try to
    /// (re)connect so a pull-down can recover the link. The brief wait keeps the refresh spinner
    /// on screen while replies stream back in.
    func pullToRefresh() async {
        if client.state == .connected {
            runStartupSequence()
        } else if client.hasLastKnownRing {
            client.connectLastKnown()
        } else {
            client.startScanning()
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    // MARK: - Workout HR streaming

    /// Begin continuous live HR (0x14 stream) for the duration of a workout — the tightest cadence
    /// the ring supports. Samples persist via `EventPersistenceSubscriber` and attach to the active
    /// session through `ActivityRecorderService.linkSample`.
    func startWorkoutHeartRate() {
        guard client.state == .connected else { return }
        client.enqueueWrite(encoder.makeHeartRateStartCommand())
        workoutHRActive = true
    }

    /// Stop the workout's live HR stream and restore the ring's normal background cadence.
    func stopWorkoutHeartRate() {
        guard workoutHRActive else { return }
        client.enqueueWrite(encoder.makeHeartRateStopCommand())
        client.enqueueWrite(encoder.makeAutomaticHeartRateCommand(enabled: true, cadenceMinutes: 30))
        workoutHRActive = false
    }

    func querySleep() {
        guard client.state == .connected else { return }
        client.enqueueWrite(encoder.makeHistoryQueryCommand())
    }

    func findRing() {
        guard client.state == .connected else { return }
        client.enqueueWrite(encoder.makeFindRingCommand())
    }

    func setGoal(steps: Int) {
        if client.state == .connected {
            client.enqueueWrite(encoder.makeGoalCommand(steps: steps))
        }
        if let goal = MetricsRepository.goals(context: context) {
            goal.steps = steps
            goal.updatedAt = Date()
        } else {
            context.insert(UserGoal(steps: steps))
        }
        try? context.save()
    }

    /// Start HR streaming, collect for the warm-up window, stop, and return the latest bpm.
    /// Samples are persisted as they arrive by `EventPersistenceSubscriber`.
    @discardableResult
    func measureHR() async -> Int? {
        guard hrState != .measuring else { return nil }
        guard client.state == .connected else { hrState = .failed; return nil }
        hrState = .measuring
        latestHRValue = nil
        client.enqueueWrite(encoder.makeHeartRateStartCommand())
        try? await Task.sleep(nanoseconds: hrMeasureSeconds * 1_000_000_000)
        client.enqueueWrite(encoder.makeHeartRateStopCommand())
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let result = latestHRValue
        hrState = result.map { .done($0) } ?? .failed
        return result
    }

    @discardableResult
    func measureSpO2() async -> Int? {
        guard spo2State != .measuring else { return nil }
        guard client.state == .connected else { spo2State = .failed; return nil }
        spo2State = .measuring
        latestSpO2Value = nil
        client.enqueueWrite(encoder.makeSpO2StartCommand())
        try? await Task.sleep(nanoseconds: spo2MeasureSeconds * 1_000_000_000)
        client.enqueueWrite(encoder.makeSpO2StopCommand())
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let result = latestSpO2Value
        spo2State = result.map { .done($0) } ?? .failed
        return result
    }

    // MARK: - Event handling

    private func handle(_ event: PulseEvent) {
        switch event {
        case let .heartRateSample(bpm, _):
            latestHRValue = bpm
        case let .spo2Result(value, _):
            latestSpO2Value = value
        case let .spo2Progress(percent, _):
            if let percent { latestSpO2Value = percent }
        case .deviceStateChanged(.connected, _):
            lastSyncAt = Date()
        default:
            break
        }
    }
}
