import Foundation
import SwiftData
import UIKit

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

/// Which spot measurements are in flight, and which of them the ring has **refused**.
///
/// A ring can decline a measurement rather than merely fail to produce one: the owner's Colmi R99
/// answers the HRV start (`03 2f` mode `0x0a`) with status `0x01`, because it has no HRV sensor. That
/// refusal used to decode to a generic ack, so the app polled a ring that had already said no for the
/// full 45-second window before reporting a generic failure. `RingSyncCoordinator` now aborts on it.
///
/// The rule this type exists to hold — **a refusal may only ever abort the measurement it names** — is
/// the part that must not be got wrong, so it lives in a value type that can be tested without a live
/// BLE link rather than in loose flags on the coordinator:
///
/// - A measurement not in flight has no window left to cut short, so a rejection that arrives late (after
///   the window closed, or from a stop) finds nothing to cancel.
/// - A rejection naming a different mode is dropped: it cannot fail an unrelated measurement.
/// - A **workout HR stream never begins one** — it is not a spot measurement, has no window to cut
///   short, and must keep streaming through anything that happens to a spot reading.
///
/// **Several measurements can be in flight at once**, and that is not hypothetical: while a workout is
/// recording, `WorkoutSensorPollingService` fires `measureHR()`/`measureSpO2()` on its own timer, and
/// nothing serializes that against the Measurement modal, the BP calibration screen, or the coach's action
/// tools — each `measure*` only guards its *own* re-entry. So ownership is explicit: `begin` hands back a
/// `Token`, and only that token can read its own verdict or retire it. One shared slot failed all three
/// ways — the second `begin` overwrote the first's mode (so the first's refusal no longer matched it and
/// it spun its whole window), the first `end` disarmed the second, and, worst, the abort closures read one
/// shared `isRejected` without asking *whose* refusal it was, so a refused BP start also aborted a workout
/// HR poll the ring had never said a word about.
///
/// The mode byte is YCBT's (`YCBTMeasurementMode`). It is the only protocol here that answers a start
/// with a verdict, so on jring and QRing-Colmi this is inert bookkeeping nothing ever reads.
struct SpotMeasurementGate {
    /// A handle to one in-flight spot measurement. Identity is `id`, **not** the mode, so two flows that
    /// somehow ran the same mode at once still could not end or abort each other.
    struct Token: Hashable {
        fileprivate let id = UUID()
        let mode: UInt8
    }

    /// The measurements currently mid-poll, and whether the ring has refused each.
    private var inFlight: [Token: Bool] = [:]

    /// Arm the gate for one measurement and hand back its handle.
    mutating func begin(mode: UInt8) -> Token {
        let token = Token(mode: mode)
        inFlight[token] = false
        return token
    }

    /// Disarm `token` — and only `token`. Called on every exit path (success, timeout, rejection); the
    /// measurement that finishes first must not disarm one still running.
    mutating func end(_ token: Token) {
        inFlight.removeValue(forKey: token)
    }

    /// Has the ring refused **this** measurement? What each `pollForValue` abort closure asks, so a
    /// refusal can only ever end the measurement it actually named.
    func isRejected(_ token: Token) -> Bool {
        inFlight[token] ?? false
    }

    /// The ring refused `mode`. Honoured only by the in-flight measurement(s) actually running it.
    mutating func noteRejected(mode: UInt8) {
        for token in inFlight.keys where token.mode == mode {
            inFlight[token] = true
        }
    }

    /// The modes currently mid-poll. Read by tests; the coordinator drives everything through tokens.
    var modesInFlight: Set<UInt8> { Set(inFlight.keys.map(\.mode)) }
}

/// The bpm samples of one spot HR measurement, and the rule for whether they add up to a reading.
///
/// Two things make a raw bpm untrustworthy, and this owns both:
///
///  * **The cached echo.** The ring replies with its last stored bpm the instant the manual-HR command
///    is sent — before the sensor has read anything. Everything inside `warmup` is therefore dropped;
///    without that, a measurement "succeeds" in two seconds on a number from hours ago.
///  * **Scatter.** Finger motion and poor contact make the PPG estimate jump around instead of holding
///    within a few beats. A majority of the window must agree (`band`, `majority`) or we report nothing:
///    a heart rate the user has no reason to doubt, but shouldn't trust, is worse than an honest retry.
private struct HRSampleWindow {
    /// Discard window for the cached echo described above.
    private let warmup: TimeInterval = 5
    /// A gap this long between collected samples means we've stopped getting real data (ring slipped).
    private let contactGap: TimeInterval = 3
    private let minSamples = 6
    private let band = 8            // bpm neighbourhood around the median
    private let majority = 0.6      // this much of the window must sit inside that band

    private var startedAt: Date?
    private var samples: [Int] = []
    private var lastSampleAt: Date?

    /// True once a *real* (post-warm-up) reading has landed — which is what distinguishes a fresh
    /// measurement from the stale `latestHRValue` still on screen from the last one.
    var receivedReading: Bool { !samples.isEmpty }

    mutating func begin(at now: Date = Date()) {
        startedAt = now
        samples = []
        lastSampleAt = nil
    }

    /// Collect a sample, unless it's still inside the warm-up echo.
    mutating func collect(_ bpm: Int, at now: Date = Date()) {
        guard let startedAt, now.timeIntervalSince(startedAt) >= warmup else { return }
        samples.append(bpm)
        lastSampleAt = now
    }

    /// Contact lost: readings had begun, and then stopped arriving. Never true during the warm-up,
    /// since nothing has been collected yet.
    func contactLost(at now: Date = Date()) -> Bool {
        guard let lastSampleAt else { return false }
        return now.timeIntervalSince(lastSampleAt) > contactGap
    }

    /// The settled reading: the median of the samples that agree with each other — or nil if they
    /// never did.
    var stableValue: Int? {
        guard samples.count >= minSamples else { return nil }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let cluster = sorted.filter { abs($0 - median) <= band }   // stays sorted
        guard Double(cluster.count) >= Double(samples.count) * majority else { return nil }
        return cluster[cluster.count / 2]
    }
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

    /// A blood-pressure reading is a pair, so it can't ride `MeasureState.done(Int)` alone.
    struct BloodPressureReading: Equatable, Sendable {
        let systolic: Int
        let diastolic: Int
    }

    /// Everything a single combined sweep produced. Fields the ring didn't compute stay `nil` — on the
    /// jring, stress/HRV/blood sugar come back as zero and are simply not shown.
    struct VitalsReading: Equatable, Sendable {
        // Optional `var`s already default to `nil` in the synthesized memberwise init.
        var heartRate: Int?
        var bloodPressure: BloodPressureReading?
        var spo2: Int?
        var fatigue: Int?
        var stress: Int?
        var hrv: Int?
        var bloodSugarMgdl: Double?

        var isEmpty: Bool {
            heartRate == nil && bloodPressure == nil && spo2 == nil
                && fatigue == nil && stress == nil && hrv == nil && bloodSugarMgdl == nil
        }
    }

    private(set) var hrState: MeasureState = .idle
    private(set) var spo2State: MeasureState = .idle
    private(set) var hrvState: MeasureState = .idle
    /// `.done` carries the systolic value; read `latestBloodPressureValue` for the full pair.
    private(set) var bpState: MeasureState = .idle
    /// Combined sweep (all vitals at once). `.done` carries HR; the caller keeps the full reading.
    private(set) var vitalsState: MeasureState = .idle
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
    private(set) var latestBloodPressureValue: BloodPressureReading?
    private(set) var latestFatigueValue: Int?
    private(set) var latestStressValue: Int?
    private(set) var latestBloodSugarValue: Double?
    private(set) var workoutHRActive = false
    /// Set when the ring reports a completed HR measurement with no usable reading (not worn), so a
    /// spot measurement can fail fast instead of waiting out the full window.
    private var hrNoReadingReported = false
    /// The samples of the HR measurement in flight, and the rule for whether they settled — see
    /// `HRSampleWindow`, which owns the warm-up echo and the consistency gate.
    private var hrWindow = HRSampleWindow()
    /// True once the current measurement has produced a real (post-warm-up) bpm. Drives the live value
    /// in the measurement sheet, and keeps a stale `latestHRValue` from passing for a fresh reading.
    var measurementReceivedReading: Bool { hrWindow.receivedReading }

    /// The spot measurements in flight, and which of them the ring has refused — see
    /// `SpotMeasurementGate`, which owns the rule that a refusal can only ever abort the measurement it
    /// actually names, and holds several concurrent measurements apart by token.
    private var spot = SpotMeasurementGate()

    /// Ring connection state, surfaced for the workout polling layer + UI.
    var connectionState: RingConnectionState { client.state }
    var isConnected: Bool { client.state == .connected }

    // MARK: Spot-measurement windows
    //
    // How long to keep polling for an on-demand reading before calling it a failure. These are not
    // arbitrary: the numbers below are set against what the owner's Colmi R99 actually took, measured
    // from the `03 2f` start frame to the reply that carried the value —
    //
    //   HR   ~19 s (window 30) · SpO₂ **38 s** (window was 40) · BP ~12 s (window 45)
    //
    // — plus enough headroom that a slow session is not a failed one. A window is a ceiling, never a
    // wait: every measurement returns the instant its value lands (and now, on a ring that refuses the
    // measurement outright, the instant it says so — see `SpotMeasurementGate`).
    //
    // **HR is the one exception**, and deliberately so: it samples its window to the end rather than
    // returning on the first value, because the first value is a lie (see `hrWarmupSeconds`). It is
    // therefore the only measurement whose duration is known up front — which is why it is the only one
    // the UI can honestly count down. The rest finish when they finish.

    /// A Colmi manual HR reading can need 15–30s of on-finger warm-up (observed: ~19 s). Not `private`:
    /// this is the one real fixed window, and `MeasurementSheet` derives its countdown from it rather
    /// than copying the literal (a copy would silently desync the ring's fill from the measurement).
    let hrMeasureSeconds: UInt64 = 30
    /// **Raised from 40 s.** The R99's successful SpO₂ sweep took 38 s — inside a 40 s window by two
    /// seconds — and an earlier attempt in the same session ran past 41 s with no result. At 40 s the
    /// outcome was a coin toss: the user watched the ring's red LED work and got an error anyway. 60 s
    /// puts a comfortable margin around the one real timing we have; the cost of the extra 20 s is paid
    /// only by a measurement that was going to fail regardless.
    private let spo2MeasureSeconds: UInt64 = 60
    /// HRV needs a stretch of beats to stabilize, so give it a longer on-finger window. (A ring without
    /// an HRV sensor no longer waits it out — it now refuses the `03 2f` start and we fail immediately.)
    private let hrvMeasureSeconds: UInt64 = 45
    /// BP rides the same PPG warm-up as SpO2 and the ring's estimator settles slowly (observed: ~12 s).
    private let bpMeasureSeconds: UInt64 = 45
    /// The combined sweep computes every metric, so give it the longest window (observed: the ring
    /// streams empty packets for ~20s before the populated burst).
    private let vitalsMeasureSeconds: UInt64 = 60

    private let client: RingBLEClient
    private let context: ModelContext

    /// The active connection's protocol engine. Command construction is delegated here so this
    /// coordinator stays device-agnostic — it owns timing/warm-up windows and UI state, the engine
    /// owns the protocol bytes and (for response-driven devices) the history machine.
    private var engine: RingSyncEngine? { client.syncEngine }

    private var streamTask: Task<Void, Never>?
    private var clockChangeTask: Task<Void, Never>?
    private var periodicSyncTask: Task<Void, Never>?

    /// SmartHealth re-reads its ring's stored history every 30 minutes while connected; PulseLoop matches
    /// that cadence. The ring has no cursor — it always dumps everything it holds for a type — so a
    /// tighter interval would just re-transfer the same records for nothing.
    private let periodicSyncInterval: TimeInterval = 30 * 60

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
        observeClockChanges()
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

    /// Start HR streaming, sample the whole window, stop, and return the median of the samples that
    /// agree with each other — or nil if they never settled. Samples are persisted as they arrive by
    /// `EventPersistenceSubscriber`.
    ///
    /// Unlike every other spot measurement, this one does **not** return on the first value: the ring
    /// echoes its last *cached* bpm the instant the manual-HR command fires, so returning early reports
    /// a stale number — a reading from hours ago, after a convincing two seconds of "measuring".
    @discardableResult
    func measureHR() async -> Int? {
        guard hrState != .measuring else { return nil }
        guard client.state == .connected else { hrState = .failed; return nil }
        hrState = .measuring
        // NOTE: do *not* clear `latestHRValue` — it's the live value the workout UI shows, so a new
        // measurement keeps the last reading on screen until a fresh one replaces it (no blanking to —).
        hrNoReadingReported = false
        hrWindow.begin()
        // Spot reading: the engine picks the right command (jring live stream / Colmi manual 0x69
        // continuous stream). Always stop the stream when we're done so the ring doesn't keep measuring.
        let token = spot.begin(mode: YCBTMeasurementMode.heartRate)
        engine?.measureHeartRateSpot()

        // Sample the full window in 0.5s steps: `handle(_:)` discards everything inside the warm-up and
        // collects the rest into `hrSamples`. We break out early only where continuing is pointless —
        // and each of those is an abort, not a short-but-usable reading, so none of them report a value.
        var aborted = false
        let steps = Int(hrMeasureSeconds) * 2   // 0.5s granularity
        for _ in 0..<steps {
            if Task.isCancelled { aborted = true; break }
            // The ring reported "worn incorrectly", or refused the measurement outright.
            if hrNoReadingReported || spot.isRejected(token) { aborted = true; break }
            // Ring removed / BLE dropped mid-measure → fail rather than average a truncated window.
            if client.state != .connected { aborted = true; break }
            // Contact lost after readings began (ring slipped / hand moved).
            if hrWindow.contactLost() { aborted = true; break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        spot.end(token)
        engine?.stopHeartRate()
        // A spot read's stop also tears down the realtime stream (Colmi stops both 0x69 and 0x1e);
        // if a workout stream is supposed to be running, bring it straight back.
        restartWorkoutHeartRateIfActive()

        let result = aborted ? nil : hrWindow.stableValue
        hrState = result.map { .done($0) } ?? .failed
        return result
    }

    /// Poll a value getter every 0.5s up to `window` seconds; returns as soon as it's non-nil, or when
    /// `abort` becomes true, else nil at timeout.
    private func pollForValue(window: UInt64, value: () -> Int?, abort: () -> Bool) async -> Int? {
        let steps = Int(window) * 2   // 0.5s granularity
        for _ in 0..<steps {
            if Task.isCancelled { return nil }
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
        let token = spot.begin(mode: YCBTMeasurementMode.spo2)
        engine?.startSpO2()
        let result = await pollForValue(
            window: spo2MeasureSeconds,
            value: { self.latestSpO2Value },
            abort: { self.spot.isRejected(token) }
        )
        spot.end(token)
        engine?.stopSpO2()
        // On rings whose live metrics share one stream (TK5: every metric rides `03 2f`, and its stop
        // is mode-agnostic), stopping SpO2 also tears down a running workout HR stream. Bring it back.
        restartWorkoutHeartRateIfActive()
        spo2State = result.map { .done($0) } ?? .failed
        return result
    }

    /// Spot HRV reading. The engine starts the device's dedicated HRV mode (TK5: `03 2f 010a`), we
    /// wait for the first live HRV sample, then stop. Capability-gated to `.manualHrv`, so only rings
    /// whose live protocol has an HRV mode reach this — which, since the R99, means a ring whose own
    /// bitmap claimed one. A ring that lies about it (or a firmware that changes its mind) is caught by
    /// the abort below: the `03 2f` refusal ends the measurement in the time one reply takes to arrive.
    @discardableResult
    func measureHRV() async -> Int? {
        guard hrvState != .measuring else { return nil }
        guard client.state == .connected else { hrvState = .failed; return nil }
        hrvState = .measuring
        latestHRVValue = nil
        let token = spot.begin(mode: YCBTMeasurementMode.hrv)
        engine?.startHRV()
        let result = await pollForValue(
            window: hrvMeasureSeconds,
            value: { self.latestHRVValue },
            abort: { self.spot.isRejected(token) }
        )
        spot.end(token)
        engine?.stopHRV()
        // Same shared-stream teardown as SpO2 above: restore the workout's live HR if one was running.
        restartWorkoutHeartRateIfActive()
        hrvState = result.map { .done($0) } ?? .failed
        return result
    }

    /// Spot blood-pressure reading. The engine starts the ring's BP mode (jring: `0x23 01`); the
    /// systolic/diastolic pair arrives together in the ring's combined-sensor packet, so we poll on
    /// the systolic value and read the pair. Capability-gated to `.manualBloodPressure`.
    @discardableResult
    func measureBloodPressure() async -> BloodPressureReading? {
        guard bpState != .measuring else { return nil }
        guard client.state == .connected else { bpState = .failed; return nil }
        bpState = .measuring
        latestBloodPressureValue = nil
        let token = spot.begin(mode: YCBTMeasurementMode.bloodPressure)
        engine?.startBloodPressure()
        _ = await pollForValue(
            window: bpMeasureSeconds,
            value: { self.latestBloodPressureValue?.systolic },
            abort: { self.spot.isRejected(token) }
        )
        spot.end(token)
        let result = latestBloodPressureValue
        engine?.stopBloodPressure()
        // Same shared-stream teardown as SpO2/HRV above: restore the workout's live HR if one ran.
        restartWorkoutHeartRateIfActive()
        bpState = result.map { .done($0.systolic) } ?? .failed
        return result
    }

    /// One PPG sweep that returns every vital the ring computes. The `0x24` packet carries HR, blood
    /// pressure, SpO₂ and fatigue together, so we start the sweep, wait for the first metric to land,
    /// then let the rest of the packet's fan-out settle before snapshotting.
    ///
    /// Capability-gated to `.combinedVitalsMeasurement`.
    @discardableResult
    func measureVitals() async -> VitalsReading? {
        guard vitalsState != .measuring else { return nil }
        guard client.state == .connected else { vitalsState = .failed; return nil }
        vitalsState = .measuring
        latestHRValue = nil
        latestSpO2Value = nil
        latestBloodPressureValue = nil
        latestFatigueValue = nil
        latestStressValue = nil
        latestHRVValue = nil
        latestBloodSugarValue = nil

        engine?.startCombinedVitals()
        // The ring streams empty packets while the PPG warms up, then a burst of populated ones. Wait
        // for the first metric of that burst rather than a specific one — which arrives first depends
        // on how the decoder fans the packet out.
        _ = await pollForValue(
            window: vitalsMeasureSeconds,
            value: { self.latestSpO2Value ?? self.latestBloodPressureValue?.systolic ?? self.latestHRValue },
            abort: { false }
        )
        // The remaining fields of the same packet are published right behind the first; give them a
        // moment to land so a reading isn't reported as partial.
        try? await Task.sleep(nanoseconds: 600_000_000)
        engine?.stopCombinedVitals()
        restartWorkoutHeartRateIfActive()

        let reading = VitalsReading(
            heartRate: latestHRValue,
            bloodPressure: latestBloodPressureValue,
            spo2: latestSpO2Value,
            fatigue: latestFatigueValue,
            stress: latestStressValue,
            hrv: latestHRVValue,
            bloodSugarMgdl: latestBloodSugarValue
        )
        guard !reading.isEmpty else { vitalsState = .failed; return nil }
        vitalsState = .done(reading.heartRate ?? reading.spo2 ?? 0)
        return reading
    }

    // MARK: - Event handling

    private func handle(_ event: PulseEvent) {
        switch event {
        case let .heartRateSample(bpm, _):
            latestHRValue = bpm
            // `collect` drops anything still inside the warm-up echo — the stale cached bpm the ring
            // fires back the instant the command lands, which is what used to end a measurement in ~2s.
            if hrState == .measuring { hrWindow.collect(bpm) }
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
        case let .bloodPressureSample(systolic, diastolic, _):
            latestBloodPressureValue = BloodPressureReading(systolic: systolic, diastolic: diastolic)
        case let .fatigueSample(value, _):
            latestFatigueValue = value
        case let .stressSample(value, _):
            latestStressValue = value
        case let .bloodSugarSample(mgdl, _):
            latestBloodSugarValue = mgdl
        case .deviceStateChanged(.connected, _):
            lastSyncAt = Date()
            // Ring came back mid-workout: the new connection's engine doesn't know a stream was
            // running, so re-issue the live HR command.
            restartWorkoutHeartRateIfActive()
            startPeriodicSync()
        case let .deviceStateChanged(state, _):
            // Any non-connected transition (disconnect / failure) ends an in-flight sync.
            if state != .connected {
                endSync()
                stopPeriodicSync()
            }
        case let .syncProgress(stage):
            updateSync(stage: stage)
        case let .rawPacket(direction, _, decoded):
            // `.measurementRejected` has no `PulseEvent` of its own — it is a verdict on a command, not
            // data — so the raw-packet feed (which carries every decoded frame) is where a measurement
            // hears the ring say no.
            guard direction == .incoming, case let .measurementRejected(mode) = decoded else { break }
            spot.noteRejected(mode: mode)
        default:
            break
        }
    }

    // MARK: - Sync progress

    /// Apply a `.syncProgress` stage. The `"done"` sentinel (emitted on history-sync finish) ends
    /// the sync; any other stage keeps the bar up and re-arms the stall timeout.
    ///
    /// A stage — any stage — is the one signal that the ring is *actually* handing data over, which is
    /// what "Synced Xm ago" claims. Stamping it here (rather than at the periodic tick, where
    /// `syncHistory()` is a no-op on jring/Colmi) keeps the label honest for the families whose history
    /// only comes down with the connect handshake.
    private func updateSync(stage: String) {
        lastSyncAt = Date()
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

// MARK: - Long-lived background tasks

/// The coordinator's two open-ended tasks, kept out of the (already large) class body: both are armed
/// once per connection, both are `[weak self]` so a deallocated coordinator ends them, and neither owns
/// state beyond the `Task` handle it parks back on the coordinator.
private extension RingSyncCoordinator {
    /// The jring's RTC runs on local wall-clock time — its sleep detection and day-indexed history
    /// queries key off it. When the phone crosses a timezone or a DST boundary, push the new clock so
    /// the ring doesn't keep bucketing days at the old offset. Rings whose firmware ignores its own
    /// RTC get a default no-op `resyncTime()`.
    func observeClockChanges() {
        guard clockChangeTask == nil else { return }
        let names: [Notification.Name] = [
            .NSSystemTimeZoneDidChange,                      // user switched timezone
            UIApplication.significantTimeChangeNotification, // DST rollover / midnight / clock set
        ]
        clockChangeTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for name in names {
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: name) {
                            guard let self else { return }
                            await MainActor.run {
                                guard self.client.state == .connected else { return }
                                self.engine?.resyncTime()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Top up the app's copy of the ring's log every 30 minutes **while connected**.
    ///
    /// This is emphatically *not* background sync: iOS gives us no BLE time while the ring is
    /// disconnected, so a ring worn away from the phone still only hands over its log on the next
    /// connect, and the docs must keep saying so. This only closes the "app has been open for hours and
    /// the data is still from the connect handshake" gap.
    ///
    /// Suppressed while a transfer is already running (`isSyncing`) or a workout is streaming live HR — a
    /// history dump would compete with the stream for the link, and `syncWorkoutVitals()` already covers
    /// that window at finish. `YCBTHistoryTransfer.start` refuses a re-entrant transfer anyway, so this is
    /// the polite half of a belt-and-braces pair. Rings whose history only comes down with the handshake
    /// (jring/Colmi) get a no-op `syncHistory()`, so the timer costs them nothing.
    ///
    /// Armed from `.deviceStateChanged(.connected,)`, which is re-published on every `02 00` reply and not
    /// just on the first connect — hence the idempotence guard.
    func startPeriodicSync() {
        guard periodicSyncTask == nil else { return }
        let interval = UInt64(periodicSyncInterval * 1_000_000_000)
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                guard self.isConnected, !self.isSyncing, !self.workoutHRActive else { continue }
                // The engine's own `.syncProgress` stages drive the progress bar (and its `"done"` stage
                // clears it), so a ring with no new records shows nothing. They also stamp `lastSyncAt`
                // — the tick itself must not, or a family whose `syncHistory()` is a no-op (jring/Colmi)
                // would show "Synced just now" every 30 minutes without a byte on the wire.
                self.engine?.syncHistory()
            }
        }
    }

    func stopPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
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
