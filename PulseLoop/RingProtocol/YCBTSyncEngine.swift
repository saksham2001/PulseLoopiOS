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
    private let profile: YCBTFamilyProfile

    /// What this ring is believed to have — the family baseline until its `02 01` bitmap lands. Drives
    /// which history types are worth asking for and which all-day monitors are worth writing.
    private var historyCapabilities: Set<WearableCapability>

    /// Set for the startup walk only, cleared when it finishes. See `handle(_:)`.
    private var requestActivityAfterStartupHistory = false

    /// Every type `YCBTHealthRecords` can decode, in the SDK's own ascending-key sync order.
    ///
    /// Sport comes before all: sport records are additive buckets that *assign* a past day's step total
    /// (sum of buckets), while the All record's cumulative counter only ever ratchets it up — so asking
    /// in this order lets the counter have the last word if the ring's buckets under-report.
    ///
    /// A ring that doesn't implement a type answers with a no-data header or a `0xFC` (unsupported key)
    /// error; `YCBTHistoryTransfer` skips both and — for `0xFC` — stops asking for the rest of the
    /// session. Some firmware answers nothing at all instead (the R99 on `05 1a`): that costs one
    /// watchdog, after which the transfer stops asking until the link drops. Querying the full catalog is
    /// therefore cheap, and which types actually return data is exactly the capability evidence the
    /// on-device checkpoint is looking for.
    ///
    /// `05 1a` (SpO₂) and `05 1e` (temperature) are queried although SmartHealth never asks for them
    /// (`DataSyncUtils.syncData`): the SDK defines and decodes both logs, and asking is the only way to
    /// learn whether a given ring keeps them. No `02 01` bit names either *log* — the nearest are the
    /// sensor bits `ISHASBLOODOXYGEN` / `ISHASTEMP` — so `05 1e` is gated on the temperature sensor, and
    /// `05 1a` only on the family's `.spo2History` claim; see `supportedHistoryTypes`.
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

    init(writer: RingCommandWriter?, transfer: YCBTHistoryTransfer, profile: YCBTFamilyProfile) {
        self.writer = writer
        self.transfer = transfer
        self.profile = profile
        self.historyCapabilities = profile.baselineCapabilities
        // A walk the watchdog ends, or one `append` restarts from idle, produces its `.historySyncFinished`
        // outside `handle`'s return path. Route it back in so the completion hook below fires either way.
        transfer.onOutOfBandEvents = { [weak self] events in
            events.forEach { self?.handle($0) }
        }
    }

    // MARK: Startup

    func runStartup() {
        for command in startupCommands() {
            writer?.enqueue(Data(command))
        }
        // The transfer machine writes the first `05 <type>` query itself and advances off the ring's
        // terminal blocks. No `.activitySyncReset` is published: history steps arrive as
        // `.activityUpdate` (a per-day max ratchet) and history measurements upsert by (kind, timestamp)
        // in `EventPersistenceSubscriber`, so a re-sync is already idempotent — and the reset case is a
        // documented no-op in the bus.
        requestActivityAfterStartupHistory = true
        transfer.start(types: supportedHistoryTypes(Self.historyTypes))
    }

    private func startupCommands() -> [[UInt8]] {
        encoder.startupSequence(
            measurement: measurementSettings,
            profile: userProfile,
            capabilities: historyCapabilities,
            queryChipScheme: profile.queryChipSchemeAtStartup,
            supportsBloodPressureMonitor: profile.supportsBloodPressureMonitor
        )
    }

    /// Two events need acting on; everything else the transfer machine handles itself.
    func handle(_ event: RingDecodedEvent) {
        switch event {
        case let .supportFunctions(derived):
            applySupportFunctions(derived)
        case .historySyncFinished:
            // Some R10M firmware ACKs the `03 09` live-status subscription sent during the handshake but
            // doesn't actually start publishing until after its history dump is done — so today's step
            // count sits at whatever the last session left until the user pulls to refresh. Asking once
            // more, after the walk, costs one frame and fixes a reconnect that otherwise looks frozen.
            guard requestActivityAfterStartupHistory else { return }
            requestActivityAfterStartupHistory = false
            writer?.enqueue(Data(encoder.enableLiveStatus()))
        default:
            return
        }
    }

    /// The ring's own capability bitmap, which arrives mid-handshake — after the startup sequence has
    /// already been queued from the baseline. Two things it can unlock:
    ///
    /// 1. **All-day monitors.** Only the *newly* permitted ones are pushed; re-sending a monitor already
    ///    in the startup sequence would just re-write the same setting.
    /// 2. **History types.** `append` rather than `start`, so the in-flight block is not disturbed.
    private func applySupportFunctions(_ derived: Set<WearableCapability>) {
        let refined = profile.refined(bitmapDerived: derived)
        guard refined != historyCapabilities else { return }
        let added = refined.subtracting(historyCapabilities)
        historyCapabilities = refined

        let alreadySent = encoder.monitorCommands(
            measurementSettings,
            capabilities: refined.subtracting(added),
            supportsBloodPressureMonitor: profile.supportsBloodPressureMonitor
        )
        for command in encoder.monitorCommands(
            measurementSettings,
            capabilities: refined,
            supportsBloodPressureMonitor: profile.supportsBloodPressureMonitor
        ) where !alreadySent.contains(command) {
            writer?.enqueue(Data(command))
        }

        var newTypes = supportedHistoryTypes(Self.historyTypes)
        // The `05 09` combined record carries BP, HRV, temperature and blood sugar as *optional fields* of
        // a record we always fetch — so unlike the others, a late unlock of one of these doesn't add a new
        // query, it means the one we already ran was decoded with those fields dropped. Re-run it once.
        // Re-queuing also withdraws the type's pending erase (`YCBTHistoryTransfer.append`): the copy we
        // saved is the incomplete one, so the ring's must survive until the re-run is on disk.
        if added.contains(where: { [.bloodPressure, .hrv, .temperature, .bloodSugar].contains($0) }) {
            newTypes.append(.all)
        }
        transfer.append(types: newTypes)
    }

    /// Ask only for logs this ring is believed to keep.
    ///
    /// A ring that doesn't implement a type answers with a no-data header or a `0xFC`, both of which
    /// `YCBTHistoryTransfer` handles — so this is not about correctness, it is about not spending ten
    /// seconds of watchdog per absent type on every sync. `.all` is never gated: the combined record is
    /// the fallback source for half these metrics, and no bit names it.
    private func supportedHistoryTypes(_ types: [YCBTHistoryType]) -> [YCBTHistoryType] {
        types.filter { type in
            switch type {
            case .sport: return historyCapabilities.contains(.steps)
            case .sleep: return historyCapabilities.contains(.sleep)
            case .heart: return historyCapabilities.contains(.heartRate)
            case .blood: return historyCapabilities.contains(.bloodPressure)
            case .all: return true
            // Not `.spo2` — this is the dedicated `05 1a` all-day log, which a ring can lack while still
            // reporting SpO₂ in the combined record. The R10M is exactly that ring.
            case .spo2: return historyCapabilities.contains(.spo2History)
            case .temperature: return historyCapabilities.contains(.temperature)
            case .comprehensive: return historyCapabilities.contains(.bloodSugar)
            case .bodyData:
                return historyCapabilities.contains(.hrv)
                    || historyCapabilities.contains(.stress)
                    || historyCapabilities.contains(.fatigue)
            // `YCBTHistoryType` is a struct of static members, not an enum, so the compiler can't check
            // this for exhaustiveness — every member of `YCBTHistoryType.catalog` is named above, and a
            // new one has to declare its gate here before it will ever be requested.
            default: return false
            }
        }
    }

    // MARK: History passes
    //
    // Both re-enter `YCBTHistoryTransfer.start`, which is a no-op while a transfer is already in flight —
    // so a periodic pass, a post-workout backfill and a pull-to-refresh can never cut each other short.

    /// Re-run the full queue without re-sending the connect handshake. Driven by `RingSyncCoordinator`'s
    /// 30-minute periodic pass (SmartHealth's own cadence) while connected.
    func syncHistory() {
        // Re-assert the live-status subscription first. Pull-to-refresh is the gesture a user makes
        // *because* today's steps look stale, and on a ring whose `03 09` went quiet the history walk
        // alone won't move them — the cumulative counter comes from the `06 00` stream, not the logs.
        writer?.enqueue(Data(encoder.enableLiveStatus()))
        transfer.start(types: supportedHistoryTypes(Self.historyTypes))
    }

    /// Post-workout backfill: pull just the vitals logs so samples the ring recorded while the phone was
    /// away or suspended land in the session that just finished (`ActivityRecorderService.linkSample`
    /// windows them in).
    func syncVitalsHistory() {
        transfer.start(types: supportedHistoryTypes(Self.vitalsTypes))
    }

    // MARK: All-day measurement config (the five `01 xx {enable, interval}` monitors)

    /// Store without sending — `runStartup` emits the monitors as part of the connect handshake.
    func setMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
    }

    /// Store *and* push immediately — the live "Save" path while connected.
    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        for command in encoder.monitorCommands(
            settings,
            capabilities: historyCapabilities,
            supportsBloodPressureMonitor: profile.supportsBloodPressureMonitor
        ) {
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
