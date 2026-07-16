import Foundation

/// LuckRing sync engine. Connect is the MixInfo binding bundle followed by device-info / battery /
/// settings-sync requests and the history catalog pass; the ring's real-time streams are toggled by the
/// per-metric `K6_DATA_TYPE_REAL_*` sends.
///
/// History is **not** driven from `handle(_:)`. The pager (`LuckRingHistorySync`, owned by the driver — the
/// only thing that sees frames) advances itself off the ring's data frames, so `handle` is a no-op.
///
/// Every logical frame is split into 20-byte packets here (the driver's `frame(_:)` is identity) and each
/// packet is enqueued individually onto `RingBLEClient`'s serialized write queue.
@MainActor
final class LuckRingSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private var encoder = LuckRingEncoder()
    private let packetizer = LuckRingPacketizer()
    private let historySync: LuckRingHistorySync

    /// Pushed in by `RingSyncCoordinator` before `runStartup`, so the binding bundle carries the user's
    /// real profile / goal. Defaults keep a freshly-paired ring sane until the store is read.
    private var userProfile = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil)
    private var goalSteps = 10_000
    /// Auto-monitoring config pushed as opcode 128 on startup. Defaults to the jring-style 30-minute
    /// cadence *enabled* — the K6 firmware default is monitoring **off**, which would leave every
    /// history stream permanently empty on a ring the vendor app never configured.
    private var measurementSettings = MeasurementSettings.jringDefault

    /// Whether this app has ever completed a LuckRing bind. The pair token's leading `1` triggers the
    /// ring's pairing animation and must be sent only once, so it is latched in UserDefaults — see the
    /// engine notes in `LuckRingEncoder.startupBundle`. (Not keyed per-peripheral: the engine has no
    /// peripheral id, and one bind flag is the conservative behaviour for the common single-ring case.)
    private static let pairFinishedKey = "luckring.pairFinished"

    init(writer: RingCommandWriter?, historySync: LuckRingHistorySync) {
        self.writer = writer
        self.historySync = historySync
    }

    /// Split a logical frame into 20-byte packets and enqueue each (the driver's `frame(_:)` is identity).
    private func send(_ frame: LuckRingFrame) {
        for packet in packetizer.packets(for: frame) {
            writer?.enqueue(packet)
        }
    }

    // MARK: Startup

    func runStartup() {
        let firstPair = !UserDefaults.standard.bool(forKey: Self.pairFinishedKey)
        send(encoder.startupBundle(profile: userProfile, goalSteps: goalSteps, firstPair: firstPair))
        UserDefaults.standard.set(true, forKey: Self.pairFinishedKey)

        send(encoder.autoMonitoring(measurementSettings))

        send(encoder.request(LuckRingDataType.devInfo))
        send(encoder.request(LuckRingDataType.battery))
        send(encoder.request(LuckRingDataType.devSync))

        historySync.start(types: LuckRingHistorySync.catalog)
    }

    /// History is pager-driven — nothing here advances it.
    func handle(_ event: RingDecodedEvent) {}

    // MARK: History passes (both re-enter `start`, a no-op while a pass is already in flight)

    func syncHistory() {
        historySync.start(types: LuckRingHistorySync.catalog)
    }

    func syncVitalsHistory() {
        historySync.start(types: LuckRingHistorySync.vitalsTypes)
    }

    // MARK: Live actions (per-metric `K6_DATA_TYPE_REAL_*` toggles)

    func startHeartRate() { send(encoder.realHeartRate(on: true)) }
    func stopHeartRate() { send(encoder.realHeartRate(on: false)) }
    func startSpO2() { send(encoder.realSpO2(on: true)) }
    func stopSpO2() { send(encoder.realSpO2(on: false)) }
    func startHRV() { send(encoder.realHRV(on: true)) }
    func stopHRV() { send(encoder.realHRV(on: false)) }
    func startBloodPressure() { send(encoder.realBloodPressure(on: true)) }
    func stopBloodPressure() { send(encoder.realBloodPressure(on: false)) }
    // `measureHeartRateSpot` falls back to `startHeartRate` (the default) — the ring has no separate
    // manual-HR command; a spot reading is the first sample off the same live stream.

    func findDevice() { send(encoder.findDevice()) }

    func setGoal(steps: Int) {
        goalSteps = steps
        send(encoder.setGoal(steps: steps))
    }

    // MARK: Clock / battery / profile

    /// The ring stamps records from its own RTC, so a timezone or wall-clock change must be re-pushed.
    func resyncTime() { send(encoder.setTime()) }

    /// Battery is in-band — request dataType 3.
    func requestBattery() { send(encoder.request(LuckRingDataType.battery)) }

    func setUserProfile(_ profile: UserProfileValues) { userProfile = profile }

    func applyUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
        send(encoder.userInfo(profile))
    }

    // MARK: Teardown

    /// Release the ring on Forget so it stops streaming and re-advertises for other apps.
    func unbind() { send(encoder.unbind()) }

    // MARK: Measurement settings (opcode 128 — the ring's own background-logging switch)

    /// Seed before `runStartup` (the coordinator pushes the stored per-device config here first).
    func setMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
    }

    /// A live settings change from the UI — push it to the ring immediately.
    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        send(encoder.autoMonitoring(settings))
    }
}
