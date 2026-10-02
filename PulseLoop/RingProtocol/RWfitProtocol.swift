import Foundation

/// Shared vocabulary for the RWfit family (`com.rw.revivalfit` vendor app). Every byte layout in the
/// `RWfit*` files is reconstructed from that app's decompiled source; each constant cites the file it
/// was read from (paths relative to `rwfit-official/sources/`).
///
/// One GATT, two wire framings:
/// - **Legacy `0x7E`** ("Realtek"): XOR checksum, per-frame serials, mandatory `0xFE`/`0xFF` ACK
///   handshake (`x5/d.java`).
/// - **JieLi `0xAB`**: CRC-16/ARC, `{CMD, Key, KeyFlag}` triple addressing, flag-0x11 ACKs
///   (`x5/c.java`, decode inline in `r5/b.java`).
///
/// Service markers are hints; the driver confirms framing using a CRC/checksum-verified response.
/// Modern protocol reference (startup, menu, live values and history consumption):
/// https://github.com/RWFitSDK/RW_weixi_miniprogram_sdk/blob/8613daec2c08a41fa6c0bf5476af4f125e1532e5/RW_SDK_DEMO/sdk/rw-ble-sdk.min.js
enum RWfitUUIDs {
    /// Primary data service, both framings (`y5/a.java f19994a`).
    static let service = "0000a00a-0000-1000-8000-00805f9b34fb"
    /// Command write characteristic (`f19995b`). Accepts write with or without response; the vendor
    /// app uses the characteristic default, so `RingBLEClient`'s property-driven pick is correct.
    static let write = "0000b002-0000-1000-8000-00805f9b34fb"
    /// Notify characteristic — responses and device-initiated pushes (`f19996c`).
    static let notify = "0000b003-0000-1000-8000-00805f9b34fb"

    // Framing discriminators — never subscribed, only *seen* at service discovery.
    /// JieLi platform service (`y5/a.java e`). Presence ⇒ JieLi framing.
    static let jieli = "0000ae00-0000-1000-8000-00805f9b34fb"
    /// Telink OTA service (`f20000h`). Presence ⇒ JieLi framing (`r5/b.java:703-727`).
    static let telinkOTA = "00010203-0405-0607-0809-0a0b0c0d1912"
    /// PixArt OTA service (`f19998f`). Presence ⇒ JieLi framing.
    static let pixartOTA = "0000ff00-0000-1000-8000-00805f9b34fb"
}

/// The two wire framings served by `RWfitDriver`, confirmed by validated inbound frames.
enum RWfitFraming: String, Sendable {
    case legacy
    case jieli
}

/// Legacy (`0x7E`) command ids actually used by PulseLoop. Full table in `x5/b.java a()`.
enum RWfitLegacyCommand {
    static let deviceInfo: UInt8 = 0x00
    static let battery: UInt8 = 0x01
    static let bindStatus: UInt8 = 0x02
    /// Supported-features bitmap (SupportMenuBean, `x5/b.java:1872`) — capability discovery.
    static let features: UInt8 = 0x03
    static let bind: UInt8 = 0x20
    static let setTime: UInt8 = 0x21
    /// `[lang, measureUnit, tempUnit, timeFont]` (`p.java P()`).
    static let units: UInt8 = 0x24
    /// `[gender, age, heightBE u16, weight×10 BE u16, goalBE u16, nickname UTF-16LE…]` (`p.java x()`).
    static let profile: UInt8 = 0x2e
    /// Unbind on Forget — empty payload (`h0.java:319`, `u1.java:520`).
    static let unbind: UInt8 = 0x44
    /// Health-sync manifest: which history types the ring holds (`x5/b.java v0()`).
    static let syncManifest: UInt8 = 0xa0
    static let stepsHistory: UInt8 = 0xa1
    static let sleepHistory: UInt8 = 0xa2
    static let heartRateHistory: UInt8 = 0xa3
    static let bloodPressureHistory: UInt8 = 0xa4
    static let spo2History: UInt8 = 0xa5
    static let temperatureHistory: UInt8 = 0xa6
    static let breatheHistory: UInt8 = 0xa7
    /// Device→app ACK of our command: payload `[serHi, serLo, cmd, status]` (`x5/d.java i()`).
    static let deviceAck: UInt8 = 0xfe
    /// App→device ACK of a device frame: same payload, sent as its own framed command
    /// (`x5/d.java b()` — `j((byte) -1, …)`).
    static let appAck: UInt8 = 0xff
}

/// A JieLi `{CMD, Key, KeyFlag}` command triple — the first three payload bytes of every `0xAB`
/// frame, in both directions (`x5/a.java`, `y5/c.java`). `KeyFlag` convention: `0x00` set,
/// `0x10` get/sync, `0x20`/`0x30` variants (bind-with-id / unbind).
struct RWfitJLTriple: Equatable, Sendable {
    let cmd: UInt8
    let key: UInt8
    let keyFlag: UInt8

    var bytes: [UInt8] { [cmd, key, keyFlag] }

    // The triples PulseLoop speaks (`y5/c.java`, senders in `p.java` / `blesdk/service/y.java`).
    static let setTime = RWfitJLTriple(cmd: 0x02, key: 0x01, keyFlag: 0x00)
    static let battery = RWfitJLTriple(cmd: 0x02, key: 0x03, keyFlag: 0x10)
    static let deviceInfo = RWfitJLTriple(cmd: 0x02, key: 0x04, keyFlag: 0x10)
    static let profile = RWfitJLTriple(cmd: 0x02, key: 0x06, keyFlag: 0x00)
    static let goal = RWfitJLTriple(cmd: 0x02, key: 0x07, keyFlag: 0x00)
    static let units = RWfitJLTriple(cmd: 0x02, key: 0x11, keyFlag: 0x00)
    static let bindStatus = RWfitJLTriple(cmd: 0x03, key: 0x01, keyFlag: 0x00)
    static let bind = RWfitJLTriple(cmd: 0x03, key: 0x01, keyFlag: 0x20)
    static let unbind = RWfitJLTriple(cmd: 0x03, key: 0x01, keyFlag: 0x30)
    /// `06 09 00 <type> 05 <enable>` — unified realtime-measurement toggle (`u0.java n()`).
    static let realtimeMeasure = RWfitJLTriple(cmd: 0x06, key: 0x09, keyFlag: 0x00)

    /// History sync request for one data type: `05 <type> 10` (`blesdk/service/y.java`).
    static func historySync(type: UInt8) -> RWfitJLTriple {
        RWfitJLTriple(cmd: 0x05, key: type, keyFlag: 0x10)
    }
}

/// JieLi `05`-group data-type bytes — used both in history-sync triples and as the `<type>` byte of
/// the realtime-measure command (`y5/c.java`, `u0/k/n/g/r` presenters).
enum RWfitJLDataType {
    static let steps: UInt8 = 0x02
    static let heartRate: UInt8 = 0x03
    static let bloodPressure: UInt8 = 0x04
    static let sleep: UInt8 = 0x05
    static let temperature: UInt8 = 0x08
    static let spo2: UInt8 = 0x09
    static let hrv: UInt8 = 0x0a
    static let stress: UInt8 = 0x0d
    static let bloodSugar: UInt8 = 0x10
}

/// One history stream, unified across the two framings so the pager and progress labels don't care
/// which wire it rides.
enum RWfitHistoryType: CaseIterable, Sendable {
    case todaySteps, steps, sleep, heartRate, bloodPressure, spo2, temperature, breathe, hrv, stress, bloodSugar

    /// Legacy request command, or nil where the legacy protocol has no such stream
    /// (`blesdk/service/l.java` — HRV/stress/blood-sugar are JieLi-only).
    var legacyCommand: UInt8? {
        switch self {
        case .steps: return RWfitLegacyCommand.stepsHistory
        case .sleep: return RWfitLegacyCommand.sleepHistory
        case .heartRate: return RWfitLegacyCommand.heartRateHistory
        case .bloodPressure: return RWfitLegacyCommand.bloodPressureHistory
        case .spo2: return RWfitLegacyCommand.spo2History
        case .temperature: return RWfitLegacyCommand.temperatureHistory
        case .breathe: return RWfitLegacyCommand.breatheHistory
        case .todaySteps, .hrv, .stress, .bloodSugar: return nil
        }
    }

    /// JieLi `05`-group type byte, or nil where the JieLi protocol has no such stream
    /// (breathe is legacy-only).
    var jlType: UInt8? {
        switch self {
        case .todaySteps: return 0x1a
        case .steps: return RWfitJLDataType.steps
        case .sleep: return RWfitJLDataType.sleep
        case .heartRate: return RWfitJLDataType.heartRate
        case .bloodPressure: return RWfitJLDataType.bloodPressure
        case .spo2: return RWfitJLDataType.spo2
        case .temperature: return RWfitJLDataType.temperature
        case .hrv: return RWfitJLDataType.hrv
        case .stress: return RWfitJLDataType.stress
        case .bloodSugar: return RWfitJLDataType.bloodSugar
        case .breathe: return nil
        }
    }

    var label: String {
        switch self {
        case .todaySteps: return "today’s activity"
        case .steps: return "activity"
        case .sleep: return "sleep"
        case .heartRate: return "heart rate"
        case .bloodPressure: return "blood pressure"
        case .spo2: return "blood oxygen"
        case .temperature: return "temperature"
        case .breathe: return "respiration"
        case .hrv: return "HRV"
        case .stress: return "stress"
        case .bloodSugar: return "blood sugar"
        }
    }

    /// The stream an inbound legacy history frame belongs to — for the pager's settle bookkeeping.
    init?(legacyCommand: UInt8) {
        guard let match = Self.allCases.first(where: { $0.legacyCommand == legacyCommand }) else {
            return nil
        }
        self = match
    }

    /// The stream an inbound JieLi `05`-group frame belongs to.
    init?(jlType: UInt8) {
        guard let match = Self.allCases.first(where: { $0.jlType == jlType }) else { return nil }
        self = match
    }
}

/// The SDK's 0263 menu uses bit zero at absolute payload offsets (including the triple).
struct RWfitFunctionMenu {
    let historyTypes: Set<RWfitHistoryType>
    let capabilities: Set<WearableCapability>
    let requiresPassword: Bool

    init?(payload: [UInt8]) {
        guard payload.count >= 0x5f else { return nil }
        requiresPassword = payload[0x2c] & 1 != 0
        var streams: Set<RWfitHistoryType> = []
        var caps: Set<WearableCapability> = []
        if payload[0x53] & 1 != 0 {
            let offsets: [(Int, RWfitHistoryType)] = [
                (0x54, .steps), (0x55, .heartRate), (0x56, .bloodPressure), (0x57, .sleep),
                (0x59, .spo2), (0x5a, .hrv), (0x5b, .stress), (0x5c, .bloodSugar), (0x5e, .temperature),
            ]
            for (offset, type) in offsets where payload[offset] & 1 != 0 { streams.insert(type) }
        }
        if streams.contains(.steps) {
            streams.insert(.todaySteps)
            caps.insert(.steps)
        }
        if streams.contains(.sleep) { caps.formUnion([.sleep, .remSleep]) }
        if streams.contains(.heartRate) { caps.formUnion([.heartRate, .manualHeartRate, .realtimeHeartRate]) }
        if streams.contains(.spo2) { caps.formUnion([.spo2, .manualSpo2]) }
        if streams.contains(.bloodPressure) { caps.formUnion([.bloodPressure, .manualBloodPressure]) }
        if streams.contains(.hrv) { caps.formUnion([.hrv, .manualHrv]) }
        if streams.contains(.stress) { caps.insert(.stress) }
        if streams.contains(.bloodSugar) { caps.insert(.bloodSugar) }
        if streams.contains(.temperature) { caps.insert(.temperature) }
        historyTypes = streams
        capabilities = caps
    }
}

/// The timezone offset the ring's RTC runs on — the RWfit twin of `JringClock`.
///
/// Both framings stamp history records with **local wall-clock** epochs: the app sets the clock from
/// local calendar components (`p.java u()/v()`), and every vendor history parser subtracts a timezone
/// offset on the way in. The legacy epoch is Unix; the JieLi epoch counts from 2000-01-01 UTC
/// (`x5/b.java`, the `+ 946684800` in every JL parser).
///
/// **Deliberate divergence from the vendor:** its legacy parsers subtract
/// `rawOffset + (zone-HAS-dst ? 1h : 0)` — an hour off for half the year in any DST zone — and its JL
/// parsers use the offset *now*, wrong for records that crossed a DST boundary. We latch
/// `secondsFromGMT(for: now)` when the clock is pushed (the same offset the ring will stamp with from
/// that moment), matching the `JringClock` contract: encoder and decoder always move together.
final class RWfitClock {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Seconds between the JieLi epoch (2000-01-01 00:00:00 UTC) and the Unix epoch.
    static let jieliEpochOffset: TimeInterval = 946_684_800

    /// Seconds east of UTC, DST included, as latched at the last clock push.
    private(set) var offsetSeconds: TimeInterval

    init(timeZone: TimeZone = .current, now: Date = Date()) {
        offsetSeconds = TimeInterval(timeZone.secondsFromGMT(for: now))
    }

    /// Latch the offset that is about to go out in a set-time command.
    func capture(timeZone: TimeZone = .current, now: Date = Date()) {
        offsetSeconds = TimeInterval(timeZone.secondsFromGMT(for: now))
    }

    /// Convert a legacy-framing record epoch (local wall-clock Unix seconds) into a true `Date`.
    func date(fromLegacyEpoch raw: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(raw) - offsetSeconds)
    }

    /// Convert a JieLi-framing record epoch (local wall-clock seconds since 2000-01-01) into a `Date`.
    func date(fromJieliEpoch raw: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(raw) + Self.jieliEpochOffset - offsetSeconds)
    }

    /// The local calendar components a set-time command should carry right now.
    func nowComponents(timeZone: TimeZone = .current, now: Date = Date()) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    }
}

/// Big-endian byte readers shared by the RWfit codecs and decoder. Every multi-byte field in both
/// framings is big-endian (`y5/b.java a()/d()/f()/j()`); the one little-endian exception (the JieLi
/// device-info screen size) is read explicitly at its use site.
enum RWfitBytes {
    static func u16BE(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard bytes.count >= offset + 2 else { return 0 }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    static func u24BE(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard bytes.count >= offset + 3 else { return 0 }
        return Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
    }

    static func u32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard bytes.count >= offset + 4 else { return 0 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    static func packU16BE(_ value: Int) -> [UInt8] {
        let clamped = UInt16(clamping: value)
        return [UInt8(clamped >> 8), UInt8(clamped & 0xff)]
    }

    static func packU32BE(_ value: Int) -> [UInt8] {
        let clamped = UInt32(clamping: value)
        return [
            UInt8((clamped >> 24) & 0xff), UInt8((clamped >> 16) & 0xff),
            UInt8((clamped >> 8) & 0xff), UInt8(clamped & 0xff),
        ]
    }

    /// XOR of all payload bytes — the legacy framing's checksum (`y5/b.java o()`).
    static func xorChecksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0, ^)
    }

    /// CRC-16/ARC over the payload — the JieLi framing's checksum (`y5/d.java a()`, table at
    /// `f20005a`): reflected poly `0xA001`, init `0x0000`, no final XOR. Table-free bitwise form —
    /// identical output to the vendor's table (which is the standard ARC table).
    static func crc16ARC(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1
            }
        }
        return crc
    }
}
