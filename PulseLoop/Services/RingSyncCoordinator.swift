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

    /// The latest history-sync stage label (e.g. "Syncing sleep…"), or nil when not syncing.
    /// Driven by `.syncProgress` events; cleared on the `"done"` stage, on disconnect, or by a
    /// safety timeout so a dropped completion signal can't leave the progress bar stuck on.
    private(set) var syncStage: String?
    /// Whether a ring data sync is in flight — drives the thin progress bar under the header.
    var isSyncing: Bool { syncStage != nil }
    private var syncTimeoutTask: Task<Void, Never>?
    /// Hard ceiling on how long the bar stays up without a fresh progress event.
    private let syncStallTimeout: UInt64 = 20

    /// Latest live values, mirrored for UI (e.g. the live workout screen) without a query.
    private(set) var latestHRValue: Int?
    private(set) var latestSpO2Value: Int?
    private(set) var workoutHRActive = false
    /// Set when the ring reports a completed HR measurement with no usable reading (not worn), so a
    /// spot measurement can fail fast instead of waiting out the full window.
    private var hrNoReadingReported = false
    /// True once the *current* measurement has produced at least one real bpm — distinguishes a fresh
    /// reading from a stale `latestHRValue` left on screen from a previous measurement.
    private var measurementReceivedReading = false

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
    /// (jring fires its commands up front; Colmi drives a response-driven history machine). The user's
    /// persisted measurement config is pushed into the engine first so the connect handshake reflects
    /// it (the engine emits the commands itself, so we don't double-send here).
    func runStartupSequence() {
        if let device = DeviceRepository.current(context: context) {
            let config = MeasurementConfigRepository.configOrDefault(deviceId: device.id, context: context)
            engine?.setMeasurementSettings(config.asSettings)
        }
        if let profile = ProfileRepository.profile(context: context) {
            engine?.setUserProfile(profileValues(from: profile))
        }
        let cal = CalibrationStore.shared.settings
        if cal.hasBPReference {
            engine?.setBloodPressureCalibration(systolic: cal.bpReferenceSystolic, diastolic: cal.bpReferenceDiastolic)
        }
        engine?.runStartup()
        lastSyncAt = Date()
        // Show the progress bar immediately; the engine's own `.syncProgress` stages refine the
        // label and the `"done"` stage (or the stall timeout) clears it.
        updateSync(stage: "Syncing…")
    }

    /// Live "Save" from the Measurement settings screen: persist nothing here (the view owns the model
    /// write), just push the latest config to the connected ring so it takes effect immediately. When
    /// disconnected this is a no-op — the config is applied on the next connect handshake.
    func applyMeasurementSettings() {
        guard client.state == .connected, let device = DeviceRepository.current(context: context) else { return }
        let config = MeasurementConfigRepository.configOrDefault(deviceId: device.id, context: context)
        engine?.applyMeasurementSettings(config.asSettings)
    }

    /// Live "Save" from the Profile screen: push the latest profile to the connected ring. No-op when
    /// disconnected — the profile is applied on the next connect handshake.
    func applyUserProfile() {
        guard client.state == .connected, let profile = ProfileRepository.profile(context: context) else { return }
        engine?.applyUserProfile(profileValues(from: profile))
    }

    /// Live "Save" from the BP calibration screen: push the reference cuff values to the connected
    /// ring (0x33). No-op when disconnected — applied on the next connect handshake.
    func applyBloodPressureCalibration() {
        guard client.state == .connected else { return }
        let cal = CalibrationStore.shared.settings
        guard cal.hasBPReference else { return }
        engine?.applyBloodPressureCalibration(systolic: cal.bpReferenceSystolic, diastolic: cal.bpReferenceDiastolic)
    }

    private func profileValues(from profile: UserProfile) -> UserProfileValues {
        UserProfileValues(
            metric: profile.units == .metric,
            sex: profile.sex,
            age: profile.age,
            heightCm: profile.heightCm,
            weightKg: profile.weightKg
        )
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
        // NOTE: do *not* clear `latestHRValue` — it's the live value the workout UI shows, so a new
        // measurement keeps the last reading on screen until a fresh one replaces it (no blanking to —).
        hrNoReadingReported = false
        measurementReceivedReading = false
        // Spot reading: the engine picks the right command (jring live stream / Colmi manual 0x69
        // continuous stream). Always stop the stream when we're done so the ring doesn't keep measuring.
        engine?.measureHeartRateSpot()
        // Phase 1 — warm up: the manual stream emits bpm 0 for ~25s before a real reading. Poll the full
        // window for the first reading *of this measurement* (not a stale prior value). Warm-up zeros are
        // dropped by the decoder, so `hrNoReadingReported` only trips on a genuine error (worn wrong).
        _ = await pollForValue(
            window: hrMeasureSeconds,
            value: { self.measurementReceivedReading ? self.latestHRValue : nil },
            abort: { self.hrNoReadingReported }
        )
        // Phase 2 — settle: keep reading briefly so the reported value is stable, not a first jump.
        var result = measurementReceivedReading ? latestHRValue : nil
        if result != nil {
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
            if hrState == .measuring { measurementReceivedReading = true }
        case .heartRateComplete:
            // The ring reported a genuine error/no-reading (worn incorrectly). Only fast-fail if this
            // measurement hasn't already produced a real reading.
            if hrState == .measuring, !measurementReceivedReading { hrNoReadingReported = true }
        case let .spo2Result(value, _):
            latestSpO2Value = value
        case let .spo2Progress(percent, _):
            if let percent { latestSpO2Value = percent }
        case .deviceStateChanged(.connected, _):
            lastSyncAt = Date()
        case let .deviceStateChanged(state, _):
            // Any non-connected transition (disconnect / failure) ends an in-flight sync.
            if state != .connected { endSync() }
        case let .syncProgress(stage):
            updateSync(stage: stage)
        default:
            break
        }
    }

    // MARK: - Sync progress

    /// Apply a `.syncProgress` stage. The `"done"` sentinel (emitted on history-sync finish) ends
    /// the sync; any other stage keeps the bar up and re-arms the stall timeout.
    private func updateSync(stage: String) {
        guard stage != "done" else { endSync(); return }
        syncStage = stage
        armSyncTimeout()
    }

    private func endSync() {
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        syncStage = nil
    }

    /// Re-arm a one-shot timeout so the bar can't linger if a final `.syncProgress("done")` never
    /// arrives (e.g. the ring drops mid-sync without a clean disconnect event).
    private func armSyncTimeout() {
        syncTimeoutTask?.cancel()
        syncTimeoutTask = Task { [weak self] in
            let seconds = self?.syncStallTimeout ?? 20
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.endSync()
        }
    }
}
