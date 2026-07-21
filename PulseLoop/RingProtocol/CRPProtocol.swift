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
enum CRPCommands {
    // Group 1 — device config / measurement control.
    static let groupDevice = 1
    static let cmdSetUserInfo = 0     // b1/k.a: [height, weight, age, gender, strideLen]
    static let cmdSetTime = 1         // b1/e.b: [epochSecondsLE(4), tzByte]
    static let cmdMeasureHR = 9       // b1/t.d: [enable] — start(1)/stop(0) continuous HR
    static let cmdMeasureSpO2 = 11    // b1/h.d: [enable] — start(1)/stop(0) SpO2

    // Group 3 — power control.
    static let groupPower = 3
    static let cmdFactoryReset = 0    // b1/l.v: q.b(3,0)
    static let cmdRestart = 1         // b1/l.w: q.b(3,1)

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
        var out = [UInt8](repeating: 0, count: total)
        out[0] = header0
        out[1] = header1
        out[2] = header2
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
    /// `H(byte[2], byte[3])`: the length's 9th bit rides bit0 of byte[2] (`0x10`), so long history
    /// frames (>255 bytes) decode correctly. Returns 0 if `data` is too short.
    static func frameLength(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        let b = [UInt8](data)
        return ((Int(b[2]) & 0x01) << 8) | (Int(b[3]) & 0xFF)
    }

    // MARK: - Command builders (v1 subset)

    /// Set the device clock. Vendor quirk (`b1/e.b`): the wall-clock components are encoded as if the
    /// zone were GMT+8, with a fixed tz byte of 8 — the ring then displays the correct local wall clock
    /// regardless of the phone's real timezone. Replicated verbatim so history stamps agree with what
    /// the vendor app would have written.
    ///
    /// The Android source builds this from `LocalDateTime.now().toEpochSecond(ZoneOffset.ofHours(8))`:
    /// the phone's local wall clock re-interpreted as a GMT+8 instant. The equivalent here takes the
    /// real epoch, adds the phone's own UTC offset to get the wall-clock-as-seconds, then subtracts 8h.
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

    static func measureHeartRate(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureHR, payload: [enable ? 1 : 0])
    }

    static func measureSpO2(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupDevice, cmd: CRPCommands.cmdMeasureSpO2, payload: [enable ? 1 : 0])
    }

    static func findDevice(_ enable: Bool) -> Data {
        frame(group: CRPCommands.groupAction, cmd: CRPCommands.cmdFindDevice, payload: [enable ? 1 : 0])
    }

    static func factoryReset() -> Data {
        frame(group: CRPCommands.groupPower, cmd: CRPCommands.cmdFactoryReset)
    }
}
