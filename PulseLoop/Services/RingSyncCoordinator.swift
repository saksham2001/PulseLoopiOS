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
    /// Set when the ring reports a completed HR measurement with no usable reading (not worn), so a
    /// spot measurement can fail fast instead of waiting out the full window.
    private var hrNoReadingReported = false

    /// Ring connection state, surfaced for the workout polling layer + UI.
    var connectionState: RingConnectionState { client.state }
    var isConnected: Bool { client.state == .connected }

    /// Max time to wait for an on-demand reading before giving up. A Colmi manual HR reading can need
    /// 15–30s of on-finger warm-up, so we poll up to this window and succeed the moment a value lands.
    private let hrMeasureSeconds: UInt64 = 30
    /// After the first valid bpm, keep reading this long so the reported value is settled, not a jumpy
    /// first sample.
    private let hrSettleSeconds: Int = 4
    private let spo2MeasureSeconds: UInt64 = 40

    private let client: RingBLEClient
    private let context: ModelContext

    /// The active connection's protocol engine. Command construction is delegated here so this
    /// coordinator stays device-agnostic — it owns timing/warm-up windows and UI state, the engine
    /// owns the protocol bytes and (for response-driven devices) the history machine.
    private var engine: RingSyncEngine? { client.syncEngine }

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

    /// Canonical startup sequence run on connect. Delegated to the active device's sync engine
    /// (jring fires its commands up front; Colmi drives a response-driven history machine).
    func runStartupSequence() {
        engine?.runStartup()
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
        engine?.startHeartRate()
        workoutHRActive = true
    }

    /// Stop the workout's live HR stream and restore the ring's normal background cadence.
    func stopWorkoutHeartRate() {
        guard workoutHRActive else { return }
        engine?.stopHeartRate()
        workoutHRActive = false
    }

    func querySleep() {
        guard client.state == .connected else { return }
        engine?.runStartup()
    }

    func findRing() {
        guard client.state == .connected else { return }
        engine?.findDevice()
    }

    func setGoal(steps: Int) {
        if client.state == .connected {
            engine?.setGoal(steps: steps)
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
        hrNoReadingReported = false
        // Spot reading: the engine picks the right command (jring live stream / Colmi manual 0x69
        // continuous stream). Always stop the stream when we're done so the ring doesn't keep measuring.
        engine?.measureHeartRateSpot()
        // Phase 1 — warm up: poll until the first real reading or the window elapses / no-reading.
        let firstReading = await pollForValue(
            window: hrMeasureSeconds,
            value: { self.latestHRValue },
            abort: { self.hrNoReadingReported }
        )
        // Phase 2 — settle: keep reading briefly so the reported value is stable, not a first jump.
        var result = firstReading
        if firstReading != nil {
            for _ in 0..<(hrSettleSeconds * 2) {   // 0.5s granularity
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let v = latestHRValue { result = v }   // latest stable sample
            }
        }
        engine?.stopHeartRate()
        hrState = result.map { .done($0) } ?? .failed
        return result
    }

    /// Poll a value getter every 0.5s up to `window` seconds; returns as soon as it's non-nil, or when
    /// `abort` becomes true, else nil at timeout.
    private func pollForValue(window: UInt64, value: () -> Int?, abort: () -> Bool) async -> Int? {
        let steps = Int(window) * 2   // 0.5s granularity
        for _ in 0..<steps {
            if let v = value() { return v }
            if abort() { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return value()
    }

    @discardableResult
    func measureSpO2() async -> Int? {
        guard spo2State != .measuring else { return nil }
        guard client.state == .connected else { spo2State = .failed; return nil }
        spo2State = .measuring
        latestSpO2Value = nil
        engine?.startSpO2()
        let result = await pollForValue(
            window: spo2MeasureSeconds,
            value: { self.latestSpO2Value },
            abort: { false }
        )
        engine?.stopSpO2()
        spo2State = result.map { .done($0) } ?? .failed
        return result
    }

    // MARK: - Event handling

    private func handle(_ event: PulseEvent) {
        switch event {
        case let .heartRateSample(bpm, _):
            latestHRValue = bpm
        case .heartRateComplete:
            // The ring finished a measurement without a usable reading (not worn / temporary error).
            if hrState == .measuring, latestHRValue == nil { hrNoReadingReported = true }
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
