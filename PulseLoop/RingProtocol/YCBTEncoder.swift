import Foundation

/// Builds *logical* YCBT commands — `[type, cmd, payload…]` without the length field or CRC, which
/// `YCBTDriver.frame(_:)` appends.
///
/// The connect handshake is **parameterized**, not a captured byte replay: it mirrors the order the
/// SmartHealth app actually runs (`HomeFragment.getCompile` → `syncSettingData`), with every payload
/// built from the SDK's own definitions and the user's real settings. The Setting-group builders live
/// in `YCBTSettingsEncoder`, shared with the other YCBT families.
///
/// Wire spec, including the exact bytes of every frame here: `docs/YCBT-Protocol.md` §2–3.
struct YCBTEncoder {
    private let settings = YCBTSettingsEncoder()

    /// Set the ring clock (`01 00`), including the Mon=0 weekday byte the old encoder hard-coded to 0.
    func setTime(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        settings.setTime(date, calendar: calendar)
    }

    /// The two commands that go out the *instant* both indication channels are live, ahead of everything
    /// `startupSequence` queues — `RingBLEClient` prepends them via
    /// `WearableDriver.immediatePostSubscriptionCommands()`.
    ///
    /// They lead for different reasons. `02 03` GetDeviceName is the cheapest possible round-trip that
    /// proves the ring is answering on `be940001` at all, so a topology that came up half-subscribed
    /// fails here rather than silently swallowing the whole handshake. `01 00` SetTime leads because
    /// every record the ring stores is stamped from its own RTC in local wall-clock: a clock set *after*
    /// the history walk has begun mis-stamps everything read before it.
    func postSubscriptionHandshake(_ date: Date = Date(), calendar: Calendar = .current) -> [[UInt8]] {
        [deviceNameRequest(), setTime(date, calendar: calendar)]
    }

    /// Read the ring's stored name (`02 03`).
    func deviceNameRequest() -> [UInt8] {
        logical(YCBTGroup.get, YCBTCommand.getDeviceName, [0x47, 0x50])
    }

    /// The connect handshake, in the SmartHealth app's own order: device interrogation → locale →
    /// all-day monitors → user profile → live-status stream. The clock and the name request run ahead of
    /// this, in `postSubscriptionHandshake`.
    ///
    /// **Never add these to it** — each was once here, and each was a different kind of wrong:
    ///   • **No `05 xx`.** The Health group is the *history* protocol: `YCBTHistoryTransfer` owns those
    ///     queries and a stray one here would race it. Worse, `05 40…4E` are the Health **Delete**
    ///     opcodes — they erase the ring's stored log. The transfer sends them itself, and only for a type
    ///     it has just fetched *and* whose records `commitDeliveredHistory` has proved are on disk; a
    ///     handshake has fetched nothing, so a delete from here could only ever destroy unsynced data.
    ///     The commands that actually make the ring *record* between syncs are the five
    ///     `01 xx {enable, interval}` monitors below.
    ///   • **No `04 xx`.** Group 4 is DevControl, the *device→app* push channel. The app's only
    ///     legitimate `04` write is an ACK for a push it received (`YCBTDriver.acknowledgePush`) — the
    ///     `04 0e 00` seen in a capture was SmartHealth ACKing a `MeasurementResult`, not a handshake
    ///     step, and replaying it unprompted does nothing.
    ///
    /// - Parameters:
    ///   - capabilities: what this ring is currently believed to have. Filters the monitor writes so a
    ///     ring is never asked to run a sensor it doesn't declare.
    ///   - queryChipScheme: `false` suppresses the informational `02 1b`. The R10M closes an otherwise
    ///     healthy link with HCI `0x13` on that query; the TK5 and SmartHealth-Colmi answer it fine.
    ///   - supportsBloodPressureMonitor: `false` suppresses the all-day BP monitor `01 1c` outright,
    ///     regardless of the `.bloodPressure` capability — the R10M has the sensor but not the monitor.
    func startupSequence(
        date: Date = Date(),
        measurement: MeasurementSettings = .allOnDefault,
        profile: UserProfileValues = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil),
        languageCode: UInt8 = 0,
        is24Hour: Bool = true,
        capabilities: Set<WearableCapability> = Set(WearableCapability.allCases),
        queryChipScheme: Bool = true,
        supportsBloodPressureMonitor: Bool = true
    ) -> [[UInt8]] {
        var seq: [[UInt8]] = []
        // Device interrogation. The 2-byte tags are cosmetic (the firmware ignores the payload of a Get)
        // but we keep the app's exact bytes: they cost nothing and keep a byte-diff against a capture clean.
        seq.append(logical(YCBTGroup.get, YCBTCommand.getDeviceInfo, [0x47, 0x43]))
        seq.append(logical(YCBTGroup.get, YCBTCommand.getSupportFunction, [0x47, 0x46]))
        if queryChipScheme {
            seq.append(logical(YCBTGroup.get, YCBTCommand.getChipScheme, []))
        }
        seq.append(logical(YCBTGroup.get, YCBTCommand.getUserConfig, [0x43, 0x46]))
        seq.append(settings.language(languageCode))
        seq.append(settings.units(metric: profile.metric, is24Hour: is24Hour))
        seq.append(contentsOf: monitorCommands(
            measurement,
            capabilities: capabilities,
            supportsBloodPressureMonitor: supportsBloodPressureMonitor
        ))
        seq.append(settings.userInfo(profile))
        seq.append(enableLiveStatus())
        return seq
    }

    /// Re-push the all-day monitors without the rest of the handshake (the live "Save" path).
    ///
    /// Filtered by capability on the way out: each `01 xx {enable, interval}` write names one sensor, and
    /// a ring that lacks it answers `0xFC`. Sending it anyway is not merely noise — it puts a rejection
    /// in the middle of the handshake for something the user can't fix, and on the R10M the all-day BP
    /// monitor is unimplemented even though the BP *sensor* is present (hence the separate flag).
    ///
    /// A capability we can't map to a monitor byte drops the command rather than passing it through: the
    /// default `capabilities` is the full set, so an unfiltered caller still gets all five.
    func monitorCommands(
        _ measurement: MeasurementSettings,
        capabilities: Set<WearableCapability> = Set(WearableCapability.allCases),
        supportsBloodPressureMonitor: Bool = true
    ) -> [[UInt8]] {
        settings.monitorCommands(measurement).filter { command in
            guard command.count >= 2 else { return false }
            switch command[1] {
            case YCBTSettingKey.heartMonitor: return capabilities.contains(.heartRate)
            case YCBTSettingKey.bloodPressureMonitor:
                return supportsBloodPressureMonitor && capabilities.contains(.bloodPressure)
            case YCBTSettingKey.temperatureMonitor: return capabilities.contains(.temperature)
            case YCBTSettingKey.bloodOxygenMonitor: return capabilities.contains(.spo2)
            case YCBTSettingKey.hrvMonitor: return capabilities.contains(.hrv)
            default: return false
            }
        }
    }

    /// Push the user's real height/weight/sex/age (`01 03`).
    func userInfo(_ profile: UserProfileValues) -> [UInt8] {
        settings.userInfo(profile)
    }

    /// Read device info (`02 00`) — battery and firmware come back in the reply.
    func deviceInfoRequest() -> [UInt8] {
        logical(YCBTGroup.get, YCBTCommand.getDeviceInfo, [0x47, 0x43])
    }

    /// Enable the ring's **live status auto-push** (`03 09 01 00 02`). Once sent, the ring streams
    /// `06 00` status frames (current step count / distance / calories) on be940003 continuously while
    /// connected — verified in the captures, where the first `06 00` appears immediately after this
    /// command and then repeats for the rest of the session. Without it the app only sees the one-time
    /// history dump, so today's live step count never updates. (`03 09 00 00 02` disables it.)
    func enableLiveStatus() -> [UInt8] {
        logical(YCBTGroup.appControl, YCBTCommand.liveStatusPush, [0x01, 0x00, 0x02])
    }

    // MARK: - Health history

    /// Ask for one history type: `05 <queryKey>`, empty payload. The reply is a header → data frames →
    /// terminal block, all driven by `YCBTHistoryTransfer`.
    func healthHistoryRequest(_ type: YCBTHistoryType) -> [UInt8] {
        YCBTHealthCommand.historyRequest(type)
    }

    /// The mandatory end-of-transfer ACK: `05 80 {00}` accepted / `{04}` CRC failure. The ring does not
    /// release the next type until it arrives.
    func historyBlockAck(status: UInt8) -> [UInt8] {
        YCBTHealthCommand.historyBlockAck(status: status)
    }

    /// Erase one type's stored log: `05 <deleteKey> {02}`. Exposed for the byte pins only — the sole
    /// sender is `YCBTHistoryTransfer`'s post-commit erase phase. `nil` for a type with no delete opcode.
    func healthHistoryDelete(_ type: YCBTHistoryType) -> [UInt8]? {
        YCBTHealthCommand.historyDelete(type)
    }

    // MARK: - Live actions

    /// Live measurement start/stop via `03 2f` with a `[enable:1][mode:1]` payload. The **mode byte
    /// selects the sensor**: 0x00 heart rate (green LED) → `06 01` stream, 0x01 blood pressure → `06 03`,
    /// 0x02 SpO₂ (red/IR LED) → `06 02`, 0x0a HRV → `06 03`. Using the wrong mode lights the wrong LED
    /// and yields no reading, so each metric must use its own start.
    ///
    /// **The stop echoes its own mode** — it is not mode-agnostic. Every SmartHealth measure screen calls
    /// `appStartMeasurement(enable, type)` with its own type in *both* directions
    /// (`BaseMeasureActivity.playStopMeasure`), so the `03 2f 00 00` stop seen in a capture was simply
    /// the HR screen's stop with mode 0, not a wildcard. Stopping an SpO₂ sweep with mode 0 tells the
    /// ring to stop *heart rate*, leaving the SpO₂ sweep running.
    func heartRateStart() -> [UInt8] { liveMeasurement(enable: true, mode: YCBTMeasurementMode.heartRate) }
    func heartRateStop() -> [UInt8] { liveMeasurement(enable: false, mode: YCBTMeasurementMode.heartRate) }
    func spo2Start() -> [UInt8] { liveMeasurement(enable: true, mode: YCBTMeasurementMode.spo2) }
    func spo2Stop() -> [UInt8] { liveMeasurement(enable: false, mode: YCBTMeasurementMode.spo2) }
    func hrvStart() -> [UInt8] { liveMeasurement(enable: true, mode: YCBTMeasurementMode.hrv) }
    func hrvStop() -> [UInt8] { liveMeasurement(enable: false, mode: YCBTMeasurementMode.hrv) }
    func bloodPressureStart() -> [UInt8] { liveMeasurement(enable: true, mode: YCBTMeasurementMode.bloodPressure) }
    func bloodPressureStop() -> [UInt8] { liveMeasurement(enable: false, mode: YCBTMeasurementMode.bloodPressure) }

    /// Find device — make the ring buzz (`03 00`, `CMD.KEY_AppControl.FindDevice == 0`), with the exact
    /// three payload bytes SmartHealth's own "find ring" button sends (`appFindDevice(1, 5, 2)`).
    ///
    /// **UNVERIFIED:** the SDK never names those three arguments, so replaying the app's literal values
    /// is the only way to be sure of the ring's response — hence they are not parameterized. If the ring
    /// doesn't buzz on the hardware checkpoint, this is the first line to look at.
    func findDevice() -> [UInt8] {
        logical(YCBTGroup.appControl, YCBTCommand.findDevice, [0x01, 0x05, 0x02])
    }

    // MARK: - Helpers

    private func liveMeasurement(enable: Bool, mode: UInt8) -> [UInt8] {
        logical(YCBTGroup.appControl, YCBTCommand.liveMeasurement, [enable ? 0x01 : 0x00, mode])
    }

    private func logical(_ group: UInt8, _ cmd: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [group, cmd] + payload
    }
}
