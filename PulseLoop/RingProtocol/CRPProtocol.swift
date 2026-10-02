import Foundation
@preconcurrency import CoreBluetooth

/// CRP ("crrepa" / CRPsmart) ring protocol — the family behind the Moyoung "Da Rings" app
/// (`com.moyoung.ring`), which is the OFFICIAL app for the CRP-firmware Colmi R11 and its siblings.
/// See `decompiled-moyoung-official/` at the repo root; this file is a faithful port of that app's
/// on-the-wire behaviour (per AGENTS.md "match the vendor app"), carried over from the Android app's
/// `CRPProtocol.kt`.
///
/// Why this family exists separately from `ColmiCoordinator`: the "R11 / SMART_RING" name is sold
/// under (at least) two different firmware stacks. One exposes the Colmi/QRing Nordic-UART profile
/// (`6e40fff0`/`de5bf728`) that `ColmiDriver` speaks; the other — this one — exposes a proprietary
/// `fdda` profile and speaks the CRP framing below. A CRP ring driven by the Colmi/jring driver
/// finds none of its characteristics and hangs the connect forever (issue #29, zaggash's ring).
///
/// **iOS reachability.** Unlike the Android port — whose BLE stack re-routes a driver post-connect
/// once the `fdda` service is discovered — iOS resolves an ambiguous `SMART_RING`/Colmi firmware by
/// the user's carousel pick at pairing (`preferredFamily`), exactly as it separates the QRing vs
/// SmartHealth Colmi firmwares. So the CRP driver is reached by explicitly picking the
/// "Colmi R11 (Da Rings app)" card (`WearableModel.colmiR11CRP`, family `.crp`), not by a
/// post-connect swap iOS's `RingBLEClient` has no mechanism for.
///
/// ## GATT topology (decompiled `k1/a.java`, `BleWriteCharacteristicProxy.getWriteCharacteristic`)
/// Service `fdda` with characteristics `fdd1`..`fdd6`:
///   - **write**   → `fdd2` (default for all normal commands; `fdd5`/`fdd6` are OTA/recording only)
///   - **notify**  → `fdd1` (current-steps push), `fdd3` (framed command replies), `fdd6` (recording)
/// Plus the standard services: `180f`/`2a19` battery, `180d`/`2a37` heart-rate, `180a` device info.
///
/// ## Frame format (decompiled `b1/q.java`)
/// `FD DA 10 <len> <group> <cmd> <payload…>` where `len = payload.count + 6` (header included).
/// Responses use the identical header; the group is byte[4], the command byte[5], payload byte[6+].
/// A logical frame may span several notifications and is reassembled by total length — the 9th bit of
/// the length rides bit0 of byte[2] (`0x10`), so length = `((byte[2] & 1) << 8) | byte[3]` (>255 ok).
enum CRPUUIDs {
    // Proprietary CRP service + characteristics.
    static let service = "0000fdda-0000-1000-8000-00805f9b34fb"
    static let stepsNotify = "0000fdd1-0000-1000-8000-00805f9b34fb"        // current-steps push
    static let write = "0000fdd2-0000-1000-8000-00805f9b34fb"             // command write target
    static let cmdNotify = "0000fdd3-0000-1000-8000-00805f9b34fb"         // framed command replies
    static let recordingNotify = "0000fdd6-0000-1000-8000-00805f9b34fb"   // OTA/recording (ignored in v1)

    // Standard GATT services reused by the ring.
    static let heartRateService = "0000180d-0000-1000-8000-00805f9b34fb"
    static let heartRateMeasure = "00002a37-0000-1000-8000-00805f9b34fb"
    static let batteryService = "0000180f-0000-1000-8000-00805f9b34fb"
    static let batteryLevel = "00002a19-0000-1000-8000-00805f9b34fb"

    // CBUUID forms — used for BLE topology and inbound routing. A SIG-base 128-bit UUID compares
    // equal to the 16-bit form CoreBluetooth delivers (the jring's `000056ff…` service relies on the
    // same normalization), so declaring the full form here still matches the ring's advertised chars.
    static let serviceCBUUID = CBUUID(string: service)
    static let stepsNotifyCBUUID = CBUUID(string: stepsNotify)
    static let writeCBUUID = CBUUID(string: write)
    static let cmdNotifyCBUUID = CBUUID(string: cmdNotify)
    static let recordingNotifyCBUUID = CBUUID(string: recordingNotify)
    static let heartRateServiceCBUUID = CBUUID(string: heartRateService)
    static let heartRateMeasureCBUUID = CBUUID(string: heartRateMeasure)
    static let batteryServiceCBUUID = CBUUID(string: batteryService)
    static let batteryLevelCBUUID = CBUUID(string: batteryLevel)
}

/// CRP command groups + subcommands (verified from the decompiled `b1` package builders).
/// Only the v1 subset is enumerated; the vendor SDK spans groups 1–10 with dozens of subcommands.
///
/// **NOTE on disable:** HR/HRV/SpO2/Stress disable by sending enable with interval=0. Temp toggles
/// on its own cmd (13) with `[1]`/`[0]`. (Per `d1/b.java` `enableTimingTemp`/`disableTimingTemp`,
/// both of which call `b1/i0.c(Bool)`.)
///
/// **Resolve every opcode through its `d1/b.java` caller, never by position in the builder class.**
/// jadx alphabetises method names, so `b1/r`'s `a`/`b`/`c` order carries no meaning. Pairing methods
/// with opcodes positionally is what mislabelled the whole of group 7 as device info (see
/// `groupGomore`) and `3/1` as restart; both are corrected below.
enum CRPCommands {
    // Group 1 — device config / measurement control.
    static let groupDevice = 1
    static let cmdSetUserInfo = 0     // b1/k.a: [height, weight, age, gender, strideLen]
    static let cmdSetTime = 1         // b1/e.b: [epochSecondsLE(4), tzByte]
    static let cmdMeasureHR = 9        // b1/t.d:  q.c(1,9,  [enable]) — start(1)/stop(0) continuous HR
    static let cmdMeasureHRV = 10      // b1/u.d:  q.c(1,10, [enable])
    static let cmdMeasureSpO2 = 11     // b1/h.d:  q.c(1,11, [enable])
    static let cmdMeasureStress = 14   // b1/h0.d: q.c(1,14, [enable])
    static let cmdMeasureTemp = 32     // b1/i0.d: q.c(1,32, [enable]) — the SPOT toggle, not all-day

    // Group 1 — the ring answers a spot measure on the SAME cmd it was started with, so the
    // result opcodes are aliases of the measure opcodes (vendor `g1/a.java` lines 664–712).
    // These are deliberately NOT the `cmdEnableTiming*` values: a reply on 6/7/8/39/13 is the
    // all-day config being acknowledged, not a reading.
    static let cmdResultHR = cmdMeasureHR          // g1/a: onHeartRate(e1/f.b → payload[0])
    static let cmdResultHRV = cmdMeasureHRV        // g1/a: onHrv(byte2int(payload[0]))
    static let cmdResultSpO2 = cmdMeasureSpO2      // g1/a: onBloodOxygen(e1/d.b → payload[0])
    static let cmdResultStress = cmdMeasureStress  // g1/a: onStressChange(byte2int(payload[0]))
    static let cmdResultTemp = cmdMeasureTemp      // g1/a: onMeasureComplete(e1/m.a → (p[1]<<8|p[0])/10)

    // Group 1 — timing/enable controls (decompiled b1 package).
    // Disable: HR/HRV/SpO2/Stress use enable with interval=0. Temp uses `[0]` on its own cmd.
    static let cmdEnableTimingHR = 6        // b1/t.c: q.c(1,6, [interval])
    static let cmdEnableTimingHRV = 7       // b1/u.c: q.c(1,7, [interval])
    static let cmdEnableTimingSpO2 = 8      // b1/h.c: q.c(1,8, [interval])
    static let cmdEnableTimingStress = 39   // b1/h0.c: q.c(1,39, [interval])
    static let cmdEnableTimingTemp = 13     // b1/i0.c: q.c(1,13, [enable]) — all-day temp on/off

    // Group 7 is the vendor's **Gomore** group (the licensed activity-analytics module), NOT device
    // info — every builder in `b1/r` resolves to a Gomore call in `d1/b.java`:
    //   q.b(7,0)=querySupportGomore  q.b(7,1)=querySavedGomoreKey  q.b(7,2)=queryGomoreEUID
    //   q.c(7,3,str)=sendGomoreKey   q.b(7,13)=queryGomoreVersion
    // The earlier constants here paired `b1/r`'s methods with opcodes positionally (a→0, b→1, c→13)
    // and mislabelled all three as device info; `queryFirmwareVersion` was really
    // `querySavedGomoreKey`, which is why zaggash's R11 answered none of the 23 sends (issue #29).
    // Real device queries live on group 3 — see `groupPower`. Kept only so a capture containing
    // these frames is still identifiable; nothing sends them.
    static let groupGomore = 7
    static let cmdQuerySupportGomore = 0     // b1/r.e: q.b(7,0)  → d1/b.querySupportGomore
    static let cmdQuerySavedGomoreKey = 1    // b1/r.d: q.b(7,1)  → d1/b.querySavedGomoreKey
    static let cmdQueryGomoreVersion = 13    // b1/r.c: q.b(7,13) → d1/b.queryGomoreVersion

    // Group 2 — stored day history. The all-day "timing" vital timelines and sleep live HERE, not
    // on group 7: the earlier group-7 opcodes were the device-info group and the ring answered every
    // one of them empty (Android issue #29, fixed in `ea9855c`). Confirmed against zaggash's R11
    // capture and the vendor `b1/{t,u,h,h0,e0}` builders.
    static let groupHistory = 2
    static let cmdQueryHistorySleep = 14    // b1/e0.c: q.c(2,14, [CRPHistoryDay])
    static let cmdQueryTimingHR = 15        // b1/t.b:  q.c(2,15, [day, frameIndex])
    static let cmdQueryTimingHRV = 16       // b1/u.b:  q.c(2,16, [day, frameIndex])
    static let cmdQueryTimingSpO2 = 17      // b1/h.b:  q.c(2,17, [day, frameIndex])
    static let cmdQueryTimingStress = 47    // b1/h0.b: q.c(2,47, [day, frameIndex])
    /// Temperature history. **Not 48** — `q.b(2,48)` is the vendor's `querySleepState` (`b1/e0.d`,
    /// `d1/b.java` line 650); the real temperature history is `i0.b(day, frameIndex)` =
    /// `q.c(2,22, [day, idx])`, the same `[day, frameIndex]` shape as the other timing histories. We
    /// queried 48 for months and the ring never answered — see zaggash's 2026-07-25 capture, 23 sends
    /// and 0 replies. Its sample layout is still unconfirmed by a non-empty capture, so the reply
    /// stays an ack for now.
    static let cmdQueryHistoryTemp = 22     // b1/i0.b: q.c(2,22, [day, frameIndex])
    static let historyDayToday = 0          // CRPHistoryDay.TODAY; YESTERDAY = 1

    // Group 2 — read-back queries. The ring can be *asked* what it supports and what is currently
    // enabled, so the app doesn't have to guess (vendor `d1/b.java` querySupport*/queryTiming*State).
    /// `b1/h.e`: q.b(2,37). Reply payload[0] is a `CRPBloodOxygenType`: 0 = NOT_SUPPORT,
    /// 1 = SLEEP_OXYGEN, 2 = TIMING_OXYGEN (`g1/a.V0` → `onSupportBloodOxygenType`). This is how a
    /// ring reports its own SpO2 hardware instead of us inferring it from a marketing page.
    static let cmdQuerySupportSpO2Type = 37
    /// The all-day monitor state queries. Each reply carries the configured interval in minutes
    /// (`g1/a.{p1,r1,n1,t1}` → `onTimingInterval`); 0 means the monitor is off.
    static let cmdQueryTimingHRState = 6       // b1/t.e:  q.b(2,6)
    static let cmdQueryTimingHRVState = 7      // b1/u.e:  q.b(2,7)
    static let cmdQueryTimingSpO2State = 8     // b1/h.f:  q.b(2,8)
    static let cmdQueryTimingTempState = 21    // b1/i0.a: q.b(2,21) → onTimingState(type, state)
    static let cmdQueryTimingStressState = 45  // b1/h0.e: q.b(2,45)

    // Group 3 — device control, identity queries, and device-state pushes. (Named `groupPower` from
    // when only the two power opcodes were known; the group is broader than the name.) Opcodes read
    // off the `b1/l` builders via their `d1/b.java` callers.
    static let groupPower = 3
    static let cmdFactoryReset = 0    // b1/l.v: q.b(3,0)  → d1/b.reset
    static let cmdShutDown = 1        // b1/l.y: q.b(3,1)  → d1/b.shutDown (was mislabelled `cmdRestart`)
    // Firmware identity — the pair the vendor's own "Firmware information" screen shows
    // (`FirmwareInformationActivity`): version is a bare UTF-8 string, hash a hex code.
    static let cmdQueryFirmwareVersion = 3  // b1/l.k: q.b(3,3) → d1/b.queryFirmwareVersion
    static let cmdQueryFirmwareHash = 4     // b1/l.j: q.b(3,4) → d1/b.queryFirmwareHash
    static let cmdQueryRealtimeBattery = 6  // b1/l.f: q.b(3,6) → d1/b.queryRealTimeBattery
    static let cmdRestart = 14        // b1/l.w: q.b(3,14) → d1/b.restart
    /// Autonomous push: `g1/a.java` decodes it as `onWearStateChange(payload[0] > 0)` — on-finger /
    /// skin-contact detection. `[00]` = not worn, which is why an optical spot measure returns
    /// nothing (Android issue #29 mis-diagnosis).
    static let cmdWearState = 7

    // Group 9 — device actions.
    static let groupAction = 9
    static let cmdFindDevice = 2      // b1/c0.c: [enable]
}

/// Builds and parses CRP wire frames. Pure and side-effect free so the framing is unit-testable
/// without a BLE stack (see `CRPProtocolTests`).
enum CRPProtocol {
    private static let header0: UInt8 = 0xFD
    private static let header1: UInt8 = 0xDA
    private static let header2: UInt8 = 0x10
    static let headerSize = 6

    /// Build a fully-framed CRP packet: `FD DA 10 <len> <group> <cmd> <payload>`.
    static func frame(group: Int, cmd: Int, payload: [UInt8] = []) -> Data {
        let total = payload.count + headerSize
        precondition(total <= 0x1FF, "CRP frames cannot exceed the protocol's 511-byte length field")
        var out = [UInt8](repeating: 0, count: total)
        out[0] = header0
        out[1] = header1
        out[2] = header2 | UInt8((total >> 8) & 0x01)
        out[3] = UInt8(truncatingIfNeeded: total)
        out[4] = UInt8(truncatingIfNeeded: group)
        out[5] = UInt8(truncatingIfNeeded: cmd)
        for (i, byte) in payload.enumerated() { out[headerSize + i] = byte }
        return Data(out)
    }

    /// True when `data` begins a CRP frame (`FD DA …`).
    static func isFrameStart(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == header0 && data[data.startIndex + 1] == header1
    }

    /// Total declared length of a frame whose header is `data`. Mirrors the vendor's
    /// `H(byte[2], byte[3])`: the length's 9th bit rides bit0 of byte[2] (`0x10`), so long
    /// history frames (>255 bytes) decode correctly. Returns 0 if `data` is too short.
    static func frameLength(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        let b = [UInt8](data)
        return ((Int(b[2]) & 0x01) << 8) | (Int(b[3]) & 0xFF)
    }

    // MARK: - Command builders (v1 subset)

    /// Set the device clock. Vendor quirk (`b1/e.b`): the wall-clock components are encoded as if
    /// the zone were GMT+8, with a fixed tz byte of 8 — the ring then displays the correct local
    /// wall clock regardless of the phone's real timezone. Replicated verbatim so history stamps
    /// agree with what the vendor app would have written.
    static func setTime(date: Date = Date(), timeZone: TimeZone = .current) -> Data {
        let offset = timeZone.secondsFromGMT(for: date)
        let wallClockSeconds = date.timeIntervalSince1970 + Double(offset)
        let epoch = UInt32(truncatingIfNeeded: Int(wallClockSeconds) - 8 * 3600)
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: epoch),
            UInt8(truncatingIfNeeded: epoch >> 8),
            UInt8(truncatingIfNeeded: epoch >> 16),
            UInt8(truncatingIfNeeded: epoch >> 24),
            8, // timezone byte (GMT+8), matching the vendor
        ]
        return frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdSetTime, payload: payload)
    }

    /// Push user anthropometrics so on-device step/calorie algorithms have real inputs.
    /// Layout from `b1/k.a`: [height(cm), weight(kg), age(yr), gender, strideLen(cm)].
    static func setUserInfo(heightCm: Int, weightKg: Int, ageYears: Int, gender: Int, strideCm: Int) -> Data {
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: heightCm), UInt8(truncatingIfNeeded: weightKg),
            UInt8(truncatingIfNeeded: ageYears), UInt8(truncatingIfNeeded: gender),
            UInt8(truncatingIfNeeded: strideCm),
        ]
        return frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdSetUserInfo, payload: payload)
    }

    // MARK: - Spot (manual) measurement toggles
    // start(true)/stop(false) an on-demand reading; the ring reports back on the same cmd byte,
    // decoded by `CRPDecoder.decodeVitalResult`. Mirrors the vendor's startMeasureX/stopMeasureX
    // (`d1/b.java` → `b1/t.d`, `u.d`, `h.d`, `h0.d`, `i0.d`).

    static func measureHeartRate(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureHR, payload: [enable ? 1 : 0])
    }

    static func measureHRV(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureHRV, payload: [enable ? 1 : 0])
    }

    static func measureSpO2(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureSpO2, payload: [enable ? 1 : 0])
    }

    static func measureStress(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureStress, payload: [enable ? 1 : 0])
    }

    static func measureTemp(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureTemp, payload: [enable ? 1 : 0])
    }

    static func findDevice(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupAction, cmd: CRPCommands.cmdFindDevice, payload: [enable ? 1 : 0])
    }

    static func factoryReset() -> Data {
        frame(group: CRPCommands.groupPower, cmd: CRPCommands.cmdFactoryReset)
    }

    // MARK: - Timing/enable commands (group 1)
    // HR/HRV/SpO2/Stress disable by sending enable with interval=0 (per d1/b.java disable* methods).
    // Temp toggles on cmd 13 with `[1]`/`[0]` — `d1/b.enableTimingTemp`/`disableTimingTemp` both call
    // `b1/i0.c(Bool)`. Cmd 32 (`b1/i0.d`) is the *spot* temp toggle, a different thing entirely.
    static func enableTimingHeartRate(intervalMinutes: Int) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingHR, payload: [UInt8(truncatingIfNeeded: intervalMinutes)])
    }

    static func disableTimingHeartRate() -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingHR, payload: [0])
    }

    static func enableTimingHRV(intervalMinutes: Int) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingHRV, payload: [UInt8(truncatingIfNeeded: intervalMinutes)])
    }

    static func disableTimingHRV() -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingHRV, payload: [0])
    }

    static func enableTimingSpO2(intervalMinutes: Int) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingSpO2, payload: [UInt8(truncatingIfNeeded: intervalMinutes)])
    }

    static func disableTimingSpO2() -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingSpO2, payload: [0])
    }

    static func enableTimingStress(intervalMinutes: Int) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingStress, payload: [UInt8(truncatingIfNeeded: intervalMinutes)])
    }

    static func disableTimingStress() -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingStress, payload: [0])
    }

    static func enableTimingTemp() -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingTemp, payload: [1])
    }

    static func disableTimingTemp() -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdEnableTimingTemp, payload: [0])
    }

    // MARK: - History query commands (group 2)
    // Each all-day "timing" vital is pulled a frame at a time: `[day, frameIndex]`. The reply echoes
    // both back (see `CRPDecoder.decodeTimingHistory`), and `CRPSyncEngine` walks frameIndex up to the
    // vital's terminal frame — the vendor's sequential `insertBleMessage(<query>.b(day, index + 1))`.

    static func queryTimingHeartRateHistory(day: Int = CRPCommands.historyDayToday, frameIndex: Int = 0) -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingHR,
              payload: [UInt8(truncatingIfNeeded: day), UInt8(truncatingIfNeeded: frameIndex)])
    }

    static func queryTimingHrvHistory(day: Int = CRPCommands.historyDayToday, frameIndex: Int = 0) -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingHRV,
              payload: [UInt8(truncatingIfNeeded: day), UInt8(truncatingIfNeeded: frameIndex)])
    }

    static func queryTimingSpO2History(day: Int = CRPCommands.historyDayToday, frameIndex: Int = 0) -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingSpO2,
              payload: [UInt8(truncatingIfNeeded: day), UInt8(truncatingIfNeeded: frameIndex)])
    }

    static func queryTimingStressHistory(day: Int = CRPCommands.historyDayToday, frameIndex: Int = 0) -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingStress,
              payload: [UInt8(truncatingIfNeeded: day), UInt8(truncatingIfNeeded: frameIndex)])
    }

    static func queryHistorySleep(daysAgo: Int = CRPCommands.historyDayToday) -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryHistorySleep,
              payload: [UInt8(truncatingIfNeeded: daysAgo)])
    }

    static func queryHistoryTemp(day: Int = CRPCommands.historyDayToday, frameIndex: Int = 0) -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryHistoryTemp,
              payload: [UInt8(truncatingIfNeeded: day), UInt8(truncatingIfNeeded: frameIndex)])
    }

    // MARK: - Read-back queries: let the ring tell us what it supports and what is enabled

    /// Ask whether this unit has SpO2 hardware at all. See `CRPCommands.cmdQuerySupportSpO2Type`.
    static func querySupportSpO2Type() -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQuerySupportSpO2Type)
    }

    static func queryTimingHeartRateState() -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingHRState)
    }

    static func queryTimingHrvState() -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingHRVState)
    }

    static func queryTimingSpO2State() -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingSpO2State)
    }

    static func queryTimingStressState() -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingStressState)
    }

    static func queryTimingTempState() -> Data {
        frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingTempState)
    }

    // MARK: - Device identity queries (group 3)
    // `queryDeviceInfo`/`queryDeviceSN` are gone: they framed group-7 Gomore opcodes, which the ring
    // never answers. Firmware version is the one the vendor's Firmware-information screen reads.

    static func queryFirmwareVersion() -> Data {
        frame(group: CRPCommands.groupPower, cmd: CRPCommands.cmdQueryFirmwareVersion)
    }
}
