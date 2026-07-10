import Foundation

/// TK5 ring protocol primitives: UUIDs, opcodes, CRC16 framing, and byte/epoch helpers.
/// Reverse-engineered from an Android btsnoop HCI capture of the **SmartHealth** app
/// (`com.zhuoting.healthyucheng`) talking to a `TK5 24AA` ring — see
/// `docs/TK5-Protocol.md` for the capture analysis. Fields decoded directly from that
/// capture are trusted; anything inferred is tagged `// UNVERIFIED (capture-inferred)`.
///
/// This is intentionally separate from `RingProtocol.swift` (jring) and `ColmiProtocol.swift`:
/// the TK5 shares nothing at the wire level — its own `be94…` service, a length-prefixed
/// CRC16/CCITT-FALSE frame, and a split command/stream channel. Decoded output is normalized
/// into the shared `RingDecodedEvent` so the rest of the app stays device-agnostic.
///
/// **Wire format** (both the command channel `be940001` and the async stream `be940003`):
///   `[type:1][cmd:1][len:2 LE][payload:N][crc16:2 LE]`
///   where `len` is the *total* frame length (header + payload + crc) and the CRC is
///   **CRC16/CCITT-FALSE** (poly 0x1021, init 0xFFFF, no reflection) over every byte before it.
///
/// **A note on the AE00 login:** the capture also shows a separate encrypted `fedcba`/"pass"
/// handshake on the `AE00` service. It runs on its own service with its own framing and is NOT
/// reproduced here (the AES key isn't recoverable from a single capture). Basic connect, time
/// sync, and device info returned in plaintext *before* that handshake in the capture; whether the
/// ring gates live-stream / history behind it can only be confirmed on-device. See the driver docs.
enum TK5UUIDs {
    /// Primary protocol service.
    static let service = "be940000-7333-be46-b7ae-689e71722bd5"
    /// Command channel — the app writes here AND receives command replies here (write + indicate).
    static let command = "be940001-7333-be46-b7ae-689e71722bd5"
    /// Async stream — live HR / steps / SpO₂ and downloaded history records (indicate).
    static let stream = "be940003-7333-be46-b7ae-689e71722bd5"

    /// Standard BLE Heart Rate service + measurement char. Present on the ring but **deliberately not
    /// subscribed** (see `TK5Driver`): it emits a cached resting HR even off-finger (~87 bpm), which
    /// would mask real on-demand readings. Kept here only to document the GATT layout.
    static let heartRateService = "180D"
    static let heartRateMeasurement = "2A37"
}

/// Frame `type` byte — the high-level channel/category the `cmd` belongs to. Recovered from the
/// captured command grouping; used only to route decoding.
enum TK5FrameType {
    static let config: UInt8 = 0x01     // time / user config
    static let device: UInt8 = 0x02     // device info, status, history-dump control
    static let action: UInt8 = 0x03     // live-stream start/stop, packet size
    static let bond: UInt8 = 0x04       // pairing/bond nudge
    static let register: UInt8 = 0x05   // calibration/preference register reads
    static let stream: UInt8 = 0x06     // async: live status / HR / SpO₂ (be940003)
}

/// `cmd` bytes seen in the capture, grouped by `type`. Only the ones we act on are named; the
/// startup handshake replays the rest verbatim (see `TK5Encoder.startupSequence`).
enum TK5Command {
    // type 0x01 (config)
    static let setTime: UInt8 = 0x00

    // type 0x02 (device)
    static let status: UInt8 = 0x00         // 30-byte status incl. battery
    static let deviceInfo: UInt8 = 0x01     // 66-byte device/firmware block
    static let historyStart: UInt8 = 0x24   // begin history dump (payload 0xf0 = header marker)
    static let historyPage: UInt8 = 0x26    // request next history page
    static let historyAck: UInt8 = 0x28     // acknowledge / finish history dump

    // type 0x06 (async stream on be940003)
    static let liveStatus: UInt8 = 0x00     // steps + distance/calories, repeated
    static let liveHeartRate: UInt8 = 0x01  // 1-byte bpm
    static let liveSpo2: UInt8 = 0x02       // 1-byte SpO₂ %
    static let liveExtended: UInt8 = 0x03   // extended live status

    // type 0x05 (async stream: history records on be940003)
    static let historyRecordShort: UInt8 = 0x15   // packed 6-byte HR records (ts + hr)
    static let historyRecordLong: UInt8 = 0x18    // packed 20-byte combined-vitals records
    static let sleepRecord: UInt8 = 0x13          // multi-frame sleep timeline (header + stage segments)
}

/// Frame parsing + building for the TK5's length-prefixed CRC16 protocol.
struct TK5Frame {
    let type: UInt8
    let cmd: UInt8
    let payload: [UInt8]

    /// Parse and CRC-validate one inbound frame. Returns nil on a short frame or CRC mismatch.
    init?(validating data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return nil }
        let declared = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard declared == bytes.count else { return nil }
        let crcGiven = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        guard TK5Frame.crc16(bytes[0..<(bytes.count - 2)]) == crcGiven else { return nil }
        self.type = bytes[0]
        self.cmd = bytes[1]
        self.payload = Array(bytes[4..<(bytes.count - 2)])
    }

    /// Build a framed packet from a logical command `[type, cmd, payload…]`: insert the total-length
    /// field after the two header bytes and append the little-endian CRC16.
    static func frame(_ logical: [UInt8]) -> Data {
        guard logical.count >= 2 else { return Data(logical) }
        let total = logical.count + 4   // + 2-byte length field + 2-byte CRC
        var out: [UInt8] = [logical[0], logical[1], UInt8(total & 0xff), UInt8((total >> 8) & 0xff)]
        out.append(contentsOf: logical[2...])
        let crc = crc16(out[0..<out.count])
        out.append(UInt8(crc & 0xff))
        out.append(UInt8((crc >> 8) & 0xff))
        return Data(out)
    }

    /// CRC16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no input/output reflection, no final xor).
    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }
}

/// Little-endian + epoch helpers. TK5 timestamps are **seconds since 2000-01-01 UTC**, not the Unix
/// epoch (confirmed against the capture's wall-clock time).
enum TK5Bytes {
    /// Seconds between 1970-01-01 and 2000-01-01 (the TK5 epoch offset).
    static let epochOffset: TimeInterval = 946_684_800

    static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 2 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 4 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    /// Convert a ring timestamp (2000-epoch seconds) to a `Date`. The ring has no timezone concept —
    /// its clock is set from local wall-clock fields (see `TK5Encoder.setTime`) and ticks in local
    /// time, so decoding must un-apply the device's UTC offset to recover the true absolute instant.
    /// Without this, `Calendar.current` re-applies that same offset when a caller later extracts
    /// local components (e.g. `Calendar.wakingDay(forSleepStart:)`'s hour check), doubling it instead
    /// of cancelling it. Uses the *current* offset as an approximation of the offset in effect when
    /// the timestamp was recorded — correct for same-session syncs, only wrong across a DST
    /// transition that happens between recording and decoding.
    static func date(_ ringSeconds: Int, timeZone: TimeZone = .current) -> Date {
        let offset = TimeInterval(timeZone.secondsFromGMT())
        return Date(timeIntervalSince1970: TimeInterval(ringSeconds) + epochOffset - offset)
    }

    /// Convert a `Date` to ring seconds (2000-epoch), the inverse of `date(_:timeZone:)`.
    static func ringSeconds(_ date: Date, timeZone: TimeZone = .current) -> Int {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: date))
        return Int(date.timeIntervalSince1970 - epochOffset + offset)
    }
}
