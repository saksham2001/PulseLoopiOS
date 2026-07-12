import Foundation

/// YCBT sync engine. Connect is a parameterized handshake (clock → device interrogation → locale →
/// all-day monitors → user profile → live-status stream), followed by the history sync.
///
/// History is **not** driven from here. It is a protocol state machine in `YCBTHistoryTransfer` (owned
/// by the driver, the only thing that sees frames): request → header → data frames → terminal block →
/// mandatory ACK → next type. The engine only seeds the queue. What ends a dump is the ring's terminal
/// block, never a timer over decoded events — which is why `handle(_:)` is a no-op.
///
/// Live HR, SpO₂ **and** HRV share one proprietary stream toggled by `03 2f` with a mode byte.
/// Protocol reference: `docs/YCBT-Protocol.md`.
@MainActor
final class YCBTSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let encoder = YCBTEncoder()
    private let transfer: YCBTHistoryTransfer

    /// Every type `YCBTHealthRecords` can decode, in the SDK's own ascending-key sync order.
    ///
    /// Sport comes before all: sport records are additive buckets that *assign* a past day's step total
    /// (sum of buckets), while the All record's cumulative counter only ever ratchets it up — so asking
    /// in this order lets the counter have the last word if the ring's buckets under-report.
    ///
    /// A ring that doesn't implement a type answers with a no-data header or a `0xFC` (unsupported key)
    /// error; `YCBTHistoryTransfer` skips both and — for `0xFC` — stops asking for the rest of the
    /// session. Querying the full catalog is therefore free, and which types actually return data is
    /// exactly the capability evidence the on-device checkpoint is looking for.
    private static let historyTypes: [YCBTHistoryType] = [
        .sport, .sleep, .heart, .blood, .all, .spo2, .temperature, .comprehensive, .bodyData,
    ]

    /// The post-workout backfill subset: only the logs a workout can have added to. Sleep, body data and
    /// the metabolic panel cannot have changed in the last 40 minutes, and they are the slow transfers —
    /// so a workout finishing doesn't drag the whole nine-type catalog across the link.
    private static let vitalsTypes: [YCBTHistoryType] = [.heart, .all, .spo2]

    /// Pushed in by `RingSyncCoordinator` before `runStartup`, so the handshake carries the user's real
    /// configuration. Defaults keep a freshly-paired ring logging until the store is read.
    private var measurementSettings = MeasurementSettings.allOnDefault
    private var userProfile = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil)

    init(writer: RingCommandWriter?, transfer: YCBTHistoryTransfer) {
        self.writer = writer
        self.transfer = transfer
    }

    // MARK: Startup

    func runStartup() {
        for command in encoder.startupSequence(measurement: measurementSettings, profile: userProfile) {
            writer?.enqueue(Data(command))
        }
        // The transfer machine writes the first `05 <type>` query itself and advances off the ring's
        // terminal blocks. No `.activitySyncReset` is published: history steps arrive as
        // `.activityUpdate` (a per-day max ratchet) and history measurements upsert by (kind, timestamp)
        // in `EventPersistenceSubscriber`, so a re-sync is already idempotent — and the reset case is a
        // documented no-op in the bus.
        transfer.start(types: Self.historyTypes)
    }

    /// History is protocol-driven now — nothing here advances it.
    func handle(_ event: RingDecodedEvent) {}

    // MARK: History passes
    //
    // Both re-enter `YCBTHistoryTransfer.start`, which is a no-op while a transfer is already in flight —
    // so a periodic pass, a post-workout backfill and a pull-to-refresh can never cut each other short.

    /// Re-run the full queue without re-sending the connect handshake. Driven by `RingSyncCoordinator`'s
    /// 30-minute periodic pass (SmartHealth's own cadence) while connected.
    func syncHistory() {
        transfer.start(types: Self.historyTypes)
    }

    /// Post-workout backfill: pull just the vitals logs so samples the ring recorded while the phone was
    /// away or suspended land in the session that just finished (`ActivityRecorderService.linkSample`
    /// windows them in).
    func syncVitalsHistory() {
        transfer.start(types: Self.vitalsTypes)
    }

    // MARK: All-day measurement config (the five `01 xx {enable, interval}` monitors)

    /// Store without sending — `runStartup` emits the monitors as part of the connect handshake.
    func setMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
    }

    /// Store *and* push immediately — the live "Save" path while connected.
    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        for command in encoder.monitorCommands(settings) {
            writer?.enqueue(Data(command))
        }
    }

    // MARK: User profile (`01 03`)

    func setUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
    }

    func applyUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
        writer?.enqueue(Data(encoder.userInfo(profile)))
    }

    // MARK: Clock / battery

    /// The ring's stored records are stamped from its own RTC in local wall-clock, so a timezone change
    /// must be pushed or every subsequent record decodes to the wrong instant.
    func resyncTime() {
        writer?.enqueue(Data(encoder.setTime()))
    }

    /// Battery is in-band: it rides the `02 00` GetDeviceInfo reply (payload[5]).
    func requestBattery() {
        writer?.enqueue(Data(encoder.deviceInfoRequest()))
    }

    // MARK: Live actions (proprietary 06-stream on be940003, mode-selected by 03 2f)
    //
    // The `03 2f` payload is [enable, mode]; the mode byte picks the sensor/LED (HR 0x00 → 06 01,
    // BP 0x01 → 06 03, SpO₂ 0x02 → 06 02, HRV 0x0a → 06 03). Each metric starts *and stops* its own mode
    // — the stop is not mode-agnostic (see `YCBTEncoder`). Only one mode runs at a time, so start-then-stop
    // per measurement is correct.

    func startHeartRate() {
        writer?.enqueue(Data(encoder.heartRateStart()))
    }

    func stopHeartRate() {
        writer?.enqueue(Data(encoder.heartRateStop()))
    }

    func startSpO2() {
        writer?.enqueue(Data(encoder.spo2Start()))
    }

    func stopSpO2() {
        writer?.enqueue(Data(encoder.spo2Stop()))
    }

    func startHRV() {
        writer?.enqueue(Data(encoder.hrvStart()))
    }

    func stopHRV() {
        writer?.enqueue(Data(encoder.hrvStop()))
    }

    /// On-demand blood pressure (`03 2f {01,01}`). The reading streams back on `06 03` as
    /// `[SBP][DBP][hr]…` — the same frame the HRV mode uses, at fixed offsets — and the ring also pushes a
    /// `04 13` status/result frame as it goes. `RingSyncCoordinator.measureBloodPressure` polls for the
    /// pair and stops the sweep.
    func startBloodPressure() {
        writer?.enqueue(Data(encoder.bloodPressureStart()))
    }

    func stopBloodPressure() {
        writer?.enqueue(Data(encoder.bloodPressureStop()))
    }

    func findDevice() {
        writer?.enqueue(Data(encoder.findDevice()))
    }

    func setGoal(steps: Int) {
        // `SettingGoal 01 02` exists in the SDK but its payload shape is unverified for this ring;
        // PulseLoop persists the goal app-side regardless.
    }
}
