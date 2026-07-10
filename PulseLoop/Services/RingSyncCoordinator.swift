import Foundation
import SwiftData

/// The slice of `RingSyncCoordinator` the coach-notification path depends on: is the ring reachable,
/// is a sync in flight, and the ability to start one and await its completion. A protocol seam so the
/// notification service can be driven with a fake gate in tests (the coordinator itself is never
/// constructed in the unit suite — it owns live BLE/SwiftData wiring).
@MainActor
protocol RingSyncGating: AnyObject {
    var isRingConnected: Bool { get }
    var isSyncInFlight: Bool { get }
    func beginSync()
    func connectAndSync() async
    func awaitSyncCompletion(timeout: TimeInterval) async -> Bool
}

/// High-level orchestration of ring command flows. Subscribes to `PulseEventBus` to track the
/// latest measurement values and completion signals, and exposes app-facing actions
/// (`syncNow`, `measureHR`, `measureSpO2`, `querySleep`, `setGoal`). It only *orchestrates*
/// command writes — persistence is handled by `EventPersistenceSubscriber`.
@MainActor
@Observable
final class RingSyncCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    enum MeasureState: Equatable {
        case idle
        case measuring
        case done(Int)
        case failed
    }

    private(set) var hrState: MeasureState = .idle
    private(set) var spo2State: MeasureState = .idle
    private(set) var hrvState: MeasureState = .idle
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

    /// Callers suspended in `awaitSyncCompletion`, resumed together by `endSync()`. Keyed by a
    /// per-call id so a cancellation / per-call timeout resumes exactly one waiter.
    private var syncWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Ids whose caller was already cancelled before its continuation could be stored (the
    /// `onCancel` handler fired first). We resume such waiters as soon as they register so a
    /// cancelled BGTask can't leak a suspended continuation.
    private var cancelledSyncWaiters: Set<UUID> = []

    /// Latest live values, mirrored for UI (e.g. the live workout screen) without a query.
    private(set) var latestHRValue: Int?
    private(set) var latestSpO2Value: Int?
    private(set) var latestHRVValue: Int?
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
    /// HRV needs a stretch of beats to stabilize, so give it a longer on-finger window.
    private let hrvMeasureSeconds: UInt64 = 45

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
        // Refresh the jring GATT battery on every manual sync (jring only pushes battery on connect);
        // Colmi's battery re-request is part of its `runStartup` handshake. No-op when the GATT
        // characteristic is absent.
        client.readBattery()
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
        // Record the intent even while disconnected: the reconnect handler re-issues the stream
        // command for any connection made while a workout wants live HR.
        workoutHRActive = true
        guard client.state == .connected else { return }
        engine?.startHeartRate()
    }

    /// Stop the workout's live HR stream and restore the ring's normal background cadence.
    func stopWorkoutHeartRate() {
        guard workoutHRActive else { return }
        engine?.stopHeartRate()
        workoutHRActive = false
    }

    /// Re-issue the live HR stream command if a workout stream should be running — used by the
    /// stream-health check when samples stall and after ring reconnects (a fresh connection builds a
    /// fresh engine whose stream flag starts off).
    func restartWorkoutHeartRateIfActive() {
        guard workoutHRActive, client.state == .connected else { return }
        engine?.startHeartRate()
    }

    /// Post-workout reconcile: pull the ring's own HR/SpO2 logs so samples recorded while the phone
    /// was away or suspended land in the just-finished session (via `linkSample`'s finished-session
    /// window) and the summary can refresh. No-op while disconnected — the next connect's full
    /// startup sync covers the same data.
    func syncWorkoutVitals() {
        guard client.state == .connected else { return }
        engine?.syncVitalsHistory()
        updateSync(stage: "Updating workout…")
    }

    /// Tighten the ring's all-day HR log for the duration of a workout so it can backfill any stream
    /// gaps (disconnect, app suspension). The cadence follows the user's "HR every" Activity-Tracking
    /// setting — the ring firmware clamps to 5-min steps with a 5-min floor, so sub-5-min settings all
    /// land at the ring's densest 5-min log. The user's normal interval is restored by
    /// `applyMeasurementSettings()` at finish.
    func applyWorkoutMeasurementInterval(hrIntervalSeconds: Int) {
        guard client.state == .connected, let device = DeviceRepository.current(context: context) else { return }
        var settings = MeasurementConfigRepository.configOrDefault(deviceId: device.id, context: context).asSettings
        settings.hrEnabled = true
        // Round the user's seconds up to whole minutes; the encoder floors at 5 min.
        settings.hrIntervalMinutes = max(1, Int((Double(hrIntervalSeconds) / 60).rounded(.up)))
        engine?.applyMeasurementSettings(settings)
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
        // A spot read's stop also tears down the realtime stream (Colmi stops both 0x69 and 0x1e);
        // if a workout stream is supposed to be running, bring it straight back.
        restartWorkoutHeartRateIfActive()
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
        // On rings whose live metrics share one stream (TK5: every metric rides `03 2f`, and its stop
        // is mode-agnostic), stopping SpO2 also tears down a running workout HR stream. Bring it back.
        restartWorkoutHeartRateIfActive()
        spo2State = result.map { .done($0) } ?? .failed
        return result
    }

    /// Spot HRV reading. The engine starts the device's dedicated HRV mode (TK5: `03 2f 010a`), we
    /// wait for the first live HRV sample, then stop. Capability-gated to `.manualHrv`, so only rings
    /// whose live protocol has an HRV mode reach this.
    @discardableResult
    func measureHRV() async -> Int? {
        guard hrvState != .measuring else { return nil }
        guard client.state == .connected else { hrvState = .failed; return nil }
        hrvState = .measuring
        latestHRVValue = nil
        engine?.startHRV()
        let result = await pollForValue(
            window: hrvMeasureSeconds,
            value: { self.latestHRVValue },
            abort: { false }
        )
        engine?.stopHRV()
        // Same shared-stream teardown as SpO2 above: restore the workout's live HR if one was running.
        restartWorkoutHeartRateIfActive()
        hrvState = result.map { .done($0) } ?? .failed
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
        case let .hrvSample(value, _):
            latestHRVValue = value
        case .deviceStateChanged(.connected, _):
            lastSyncAt = Date()
            // Ring came back mid-workout: the new connection's engine doesn't know a stream was
            // running, so re-issue the live HR command.
            restartWorkoutHeartRateIfActive()
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
        // The sync just ended (done / disconnect / stall timeout) — wake anyone waiting on it.
        for id in Array(syncWaiters.keys) { resumeSyncWaiter(id) }
    }

    // MARK: - Sync-completion waiters

    /// Suspend until the in-flight sync ends (done / disconnect / stall timeout) or `timeout` elapses.
    /// Returns immediately when no sync is in flight; the returned `Bool` is whether the sync is no
    /// longer running. Cancellation-safe: a cancelled caller (e.g. a BGTask expiring mid-wait) resumes
    /// promptly instead of leaking a suspended continuation.
    func awaitSyncCompletion(timeout: TimeInterval) async -> Bool {
        guard isSyncing else { return true }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.resumeSyncWaiter(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // If the enclosing task was already cancelled, `onCancel` ran before we got here and
                // recorded the id — resume right away rather than storing a continuation nobody wakes.
                if cancelledSyncWaiters.remove(id) != nil {
                    continuation.resume()
                } else {
                    syncWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSyncWaiter(id) }
        }
        timer.cancel()
        return !isSyncing
    }

    /// Resume (and remove) the waiter for `id`, if it's currently registered. A no-op otherwise (the
    /// sync already ended, or the timer/cancel already resumed it) — so double-signalling is harmless.
    private func resumeSyncWaiter(_ id: UUID) {
        syncWaiters.removeValue(forKey: id)?.resume()
    }

    /// Cancellation path: resume the waiter if it's registered, else remember the id so the pending
    /// `withCheckedContinuation` resumes it the moment it stores (handles the onCancel-before-store
    /// race). Only this path seeds `cancelledSyncWaiters`, so it can't accumulate stale ids.
    private func cancelSyncWaiter(_ id: UUID) {
        if let continuation = syncWaiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledSyncWaiters.insert(id)
        }
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

// MARK: - RingSyncGating

/// The coach-notification path drives sync through this narrow seam so it can be faked in tests.
extension RingSyncCoordinator: RingSyncGating {
    var isRingConnected: Bool { isConnected }
    var isSyncInFlight: Bool { isSyncing }
    func beginSync() { syncNow() }
    func connectAndSync() async { await pullToRefresh() }
}
