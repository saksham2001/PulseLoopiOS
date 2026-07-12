import Foundation
@preconcurrency import CoreBluetooth

/// Yucheng **YCBT** protocol primitives — GATT topology, framing, byte/epoch helpers, opcodes, and the
/// health-record type table. This is the wire language the TK5 speaks and, byte-identically, the
/// SmartHealth-flavoured Colmi rings. Everything here is deliberately device-agnostic: what varies
/// between families is their advertised identity and which capability bits they claim, both of which
/// live in their coordinator, so a second family reuses this file verbatim.
///
/// Ground truth is the decompiled vendor SDK (`com.yucheng.ycbtsdk`, v4.0.10): `CMD.java` (opcodes),
/// `Constants.java` (16-bit dataTypes), `DataUnpack.java` (record parsing) and
/// `YCBTClientImpl.java` (framing, queue, history assembly). Written up in `docs/YCBT-Protocol.md`,
/// which is the reference to read before touching any byte offset here.
///
/// **Wire format** (both the command channel `be940001` and the async stream `be940003`):
///   `[type:1][cmd:1][len:2 LE][payload:N][crc16:2 LE]`
///   where `len` is the *total* frame length (header + payload + crc) and the CRC is
///   **CRC16/CCITT-FALSE** (poly 0x1021, init 0xFFFF, no reflection) over every byte before it.
///   A command's 16-bit `dataType` in the SDK is exactly `(type << 8) | cmd`.
///
/// This is intentionally separate from `RingProtocol.swift` (jring) and `ColmiProtocol.swift` (the
/// QRing-flavoured Colmi rings): YCBT shares nothing at the wire level with either — its own `be94…`
/// service, a length-prefixed CRC16/CCITT-FALSE frame, and a split command/stream channel. Decoded
/// output is normalized into the shared `RingDecodedEvent` so the rest of the app stays
/// device-agnostic.

/// The GATT topology every YCBT ring exposes.
///
/// **A note on the AE00 service:** the `fedcba`/"pass" handshake there is not a login for the health
/// protocol — it is **JieLi RCSP**, the chipset vendor's own challenge-response auth, and it
/// authorizes the JieLi feature set only (OTA, watch-face upload, log extraction). The YC health
/// commands on `be940001` are plaintext, CRC-framed, and carry no auth: an independent code path in
/// the SDK. PulseLoop does no firmware updates and no watch faces, so it deliberately implements none
/// of it (the AES key is native to `libjl_rcsp.so` and isn't in the decompile anyway).
/// See `docs/YCBT-Protocol.md` §9 — including the one residual risk, that a *firmware* could still
/// refuse YC commands pre-auth even though the SDK's two paths are independent.
enum YCBTUUIDs {
    /// Primary protocol service.
    static let service = "be940000-7333-be46-b7ae-689e71722bd5"
    /// Command channel — the app writes here AND receives command replies here (write + indicate).
    static let command = "be940001-7333-be46-b7ae-689e71722bd5"
    /// Async stream — live HR / steps / SpO₂ and downloaded history records (indicate).
    static let stream = "be940003-7333-be46-b7ae-689e71722bd5"

    /// Standard BLE Heart Rate service + measurement char. Present on the ring but **deliberately not
    /// subscribed** (see `YCBTDriver`): on the TK5 it emits a cached resting HR even off-finger
    /// (~87 bpm), which would mask real on-demand readings. Kept here only to document the GATT layout.
    static let heartRateService = "180D"
    static let heartRateMeasurement = "2A37"
}

/// Frame parsing + building for the YCBT length-prefixed CRC16 protocol.
struct YCBTFrame {
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
        guard YCBTFrame.crc16(bytes[0..<(bytes.count - 2)]) == crcGiven else { return nil }
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

/// Little-endian + epoch helpers. YCBT timestamps are **seconds since 2000-01-01 UTC**, not the Unix
/// epoch (confirmed against the capture's wall-clock time).
enum YCBTBytes {
    /// Seconds between 1970-01-01 and 2000-01-01 (the YCBT epoch offset).
    static let epochOffset: TimeInterval = 946_684_800

    static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 2 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    /// 3-byte little-endian. Sleep segment durations are u24 (`DataUnpack` reads bytes 5,6,7 of an
    /// 8-byte segment), so a u16 read truncates any segment longer than 18h12m.
    static func u24(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 3 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16)
    }

    static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 4 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    /// Convert a ring timestamp (2000-epoch seconds) to a `Date`. The ring has no timezone concept —
    /// its clock is set from local wall-clock fields (see `YCBTEncoder.setTime`) and ticks in local
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

/// Frame `type` byte — the command group. `Constants.DATATYPE` splits every opcode this way.
enum YCBTGroup {
    static let setting: UInt8 = 0x01      // clock, user info, units, monitor enables
    static let get: UInt8 = 0x02          // device info, support bitmap, name, user config
    static let appControl: UInt8 = 0x03   // live-measurement start/stop, live-status push
    static let devControl: UInt8 = 0x04   // device→app pushes (find phone, SOS, measurement done)
    static let health: UInt8 = 0x05       // history: queries, data frames, terminal block
    static let real: UInt8 = 0x06         // device→app realtime stream
}

/// The `cmd` bytes we act on, by group (`YCBTGroup`). The Setting-group keys live in `YCBTSettingKey`
/// and the Health-group history keys in `YCBTHistoryType`.
///
/// The Get-group names here were previously **swapped**: `0x00` was called `status` and `0x01`
/// `deviceInfo`. `CMD.KEY_Get` says otherwise — `DeviceInfo = 0` (the reply `unpackDeviceInfoData`
/// parses, carrying battery + firmware) and `SupportFunction = 1` (the capability bitmap).
enum YCBTCommand {
    // Group 0x02 (Get)
    static let getDeviceInfo: UInt8 = 0x00       // battery @payload[5], state @[4], firmware "[3].[2]"
    static let getSupportFunction: UInt8 = 0x01  // capability bitmap (see YCBTSupportFunction)
    static let getDeviceName: UInt8 = 0x03
    static let getUserConfig: UInt8 = 0x07
    static let getChipScheme: UInt8 = 0x1b       // JieLi vs Nordic — gates the (unimplemented) AE00 auth

    // Group 0x03 (AppControl)
    static let findDevice: UInt8 = 0x00          // make the ring buzz (`CMD.KEY_AppControl.FindDevice`)
    static let liveMeasurement: UInt8 = 0x2f     // [enable, mode] — mode picks the sensor/LED
    static let liveStatusPush: UInt8 = 0x09      // enable the ring's continuous 06 00 status stream

    // Group 0x06 (Real — async stream on be940003)
    static let liveStatus: UInt8 = 0x00          // steps + distance/calories, repeated
    static let liveHeartRate: UInt8 = 0x01       // 1-byte bpm
    static let liveSpo2: UInt8 = 0x02            // 1-byte SpO₂ %
    static let liveVitals: UInt8 = 0x03          // SBP/DBP/hr/hrv/spo2/temp — the BP *and* HRV live feed
    static let liveWearingStatus: UInt8 = 0x13   // [ts:u32][worn]
    static let liveBattery: UInt8 = 0x15         // [chargingStatus][percent]
}

/// One health-history record type: the query key we write, the ack key its data frames carry back, and
/// the fixed record stride the reassembled buffer is sliced at. This table is the single source of
/// truth for both `YCBTHistoryTransfer` (which types to ask for, which frames belong to which type)
/// and `YCBTHealthRecords` (how to cut the buffer) — the two must never disagree.
///
/// Keys are `CMD.KEY_Health` (query) and its paired `…Ack` constant; strides are the loop increments in
/// `DataUnpack.unpackHealthData`.
struct YCBTHistoryType: Equatable, Hashable, Sendable {
    /// `05 <queryKey>` with an empty payload asks the ring for every stored record of this type.
    let queryKey: UInt8
    /// The `cmd` the ring's data frames carry (a *different* key from the query — e.g. heart queries
    /// with `0x06` and streams back on `0x15`).
    let ackKey: UInt8
    /// Fixed record size in the reassembled buffer. `nil` ⇒ variable-length (sleep sessions carry
    /// their own length field), so the decoder walks it rather than slicing at a stride.
    let recordStride: Int?
    /// Human label for the sync-progress UI ("Syncing sleep…").
    let label: String

    static let sport = YCBTHistoryType(queryKey: 0x02, ackKey: 0x11, recordStride: 14, label: "activity")
    static let sleep = YCBTHistoryType(queryKey: 0x04, ackKey: 0x13, recordStride: nil, label: "sleep")
    static let heart = YCBTHistoryType(queryKey: 0x06, ackKey: 0x15, recordStride: 6, label: "heart rate")
    static let blood = YCBTHistoryType(queryKey: 0x08, ackKey: 0x17, recordStride: 8, label: "blood pressure")
    static let all = YCBTHistoryType(queryKey: 0x09, ackKey: 0x18, recordStride: 20, label: "vitals")
    static let spo2 = YCBTHistoryType(queryKey: 0x1a, ackKey: 0x22, recordStride: 6, label: "blood oxygen")
    static let temperature = YCBTHistoryType(queryKey: 0x1e, ackKey: 0x26, recordStride: 7, label: "temperature")
    static let comprehensive = YCBTHistoryType(queryKey: 0x2f, ackKey: 0x30, recordStride: 44, label: "metabolic")
    static let bodyData = YCBTHistoryType(queryKey: 0x33, ackKey: 0x34, recordStride: 28, label: "body data")

    /// Every type the SDK's `DataSyncUtils` can request, in its own ascending-key sync order — and every
    /// type `YCBTHealthRecords` decodes. Both YCBT families query the whole catalog, whatever their
    /// capability set says: a type the ring doesn't implement answers with a no-data header or a `0xFC`
    /// (unsupported key), which `YCBTHistoryTransfer` skips — permanently, for `0xFC`. Asking is
    /// therefore cheaper than keeping a second, capability-derived list that could disagree with the
    /// ring's own answer.
    ///
    /// Deliberately absent, with no decoder: sport-mode workout records (`0x2D`), fall (`0x29`),
    /// health-monitoring (`0x2B`), sedentary (`0x37`), ambient light (`0x20`), temp+humidity (`0x1C`),
    /// location (`0x35`) and power-on/off (`0x76`) — none map onto a PulseLoop metric today.
    static let catalog: [YCBTHistoryType] = [
        .sport, .sleep, .heart, .blood, .all, .spo2, .temperature, .comprehensive, .bodyData,
    ]
}

/// The measurement-mode byte — one table shared by the two commands that must agree on it: the
/// **`03 2f` start/stop** payload we write (`{enable, mode}`) and the **`04 13` status/result push** the
/// ring answers with (`[type][state]…`). They are the same numbering, verified case by case against
/// SmartHealth's own measure screens (each `BaseMeasureActivity` subclass returns its mode from
/// `getType()`, which is passed straight to `appStartMeasurement`) and against the 1043 switch in
/// `DataUnpack.unpackParseData`.
///
/// Only the modes a YCBT ring can actually run are listed; PulseLoop drives a subset of them.
enum YCBTMeasurementMode {
    static let heartRate: UInt8 = 0x00
    static let bloodPressure: UInt8 = 0x01
    static let spo2: UInt8 = 0x02
    static let respiratoryRate: UInt8 = 0x03
    static let temperature: UInt8 = 0x04
    static let bloodSugar: UInt8 = 0x05
    static let uricAcid: UInt8 = 0x06
    static let bloodKetone: UInt8 = 0x07
    static let bloodFat: UInt8 = 0x09
    static let hrv: UInt8 = 0x0a
    static let stress: UInt8 = 0x0c

    /// The ring's **verdict** on a `03 2f` start, and the reason `.measurementRejected` exists.
    ///
    /// The reply is a single status byte — `0x00` = accepted, non-zero = "I will not run that" — and it
    /// **does not echo the mode**, so the SDK just hands its caller `bArr[last]` as an opaque `code`
    /// (`YCBTClientImpl.packetAppControlHandle`, which falls through to `onDataResponse(code, …)`).
    /// Whoever decodes it therefore has to remember which mode it asked for; `YCBTDriver` does.
    ///
    /// Hardware: the owner's R99 answered `0x00` for HR / SpO₂ / BP and **`0x01` for HRV (mode 0x0a)** —
    /// a ring saying, in one byte, that a sensor its bitmap already disclaimed is not there. Treating
    /// that as an ordinary ack is what made the app poll for 45 s before giving a generic failure.
    static func isAccepted(status: UInt8) -> Bool { status == 0x00 }
}

/// Group 4 (**DevControl**) — the ring→app push channel: measurement progress/results, SOS, find-phone,
/// sedentary reminders. The app never *initiates* a `04 xx`; the only `04` frame it writes is the ACK
/// below.
enum YCBTDevControl {
    static let findPhone: UInt8 = 0x00           // 1024 — ring pressed "find my phone"
    static let sos: UInt8 = 0x05                 // 1029
    static let measurementResult: UInt8 = 0x0e   // 1038 — [measureType][result]
    static let measurementStatus: UInt8 = 0x13   // 1043 — [type][state] + the value for that type
    static let sedentaryReminder: UInt8 = 0x16   // 1046
    static let sosCall: UInt8 = 0x17             // 1047 — full SOS + GPS record

    /// `04 <key> {00}` — the mandatory push ACK. **The ring retransmits a push until it arrives**, so
    /// `YCBTClientImpl.packetDevControlHandle` sends it (`sendData2Device(dataType, {0})`) *before* it
    /// even parses the payload. We do the same.
    static func ack(key: UInt8) -> [UInt8] {
        [YCBTGroup.devControl, key, 0x00]
    }

    /// `result` byte of a `04 0e` MeasurementResult push, per `BaseMeasureActivity.onDataResponse`:
    /// 1 = success, 2 = failed, anything else = cancelled. The push carries **no measured value** —
    /// SmartHealth reacts to a success by re-reading history, which is where the reading actually lands.
    static let resultSuccess: UInt8 = 0x01
}

/// The Health group's two control keys and the ACK status bytes.
enum YCBTHealth {
    /// `05 80` — inbound it terminates a transfer (`[totalPackets:u16][totalBytes:u16][crc16:u16]`);
    /// outbound it is the mandatory block ACK.
    static let terminalBlock: UInt8 = 0x80
    /// Reassembled buffer matched the terminal frame's CRC16.
    static let ackAccepted: UInt8 = 0x00
    /// CRC mismatch — the ring may re-send.
    static let ackCrcFailure: UInt8 = 0x04
    /// A header frame carries `[recordCount:u16][totalPackets:u32][totalBytes:u32]`; the SDK treats a
    /// payload of 9 bytes or fewer as "this type has no stored data".
    static let headerPayloadLength = 10
    /// The terminal block's payload length.
    static let terminalPayloadLength = 6
}

/// Logical (unframed) Health-group commands. Shared so the transfer machine and a family's encoder
/// can never drift apart on the exact bytes; the driver's `frame(_:)` adds length + CRC.
enum YCBTHealthCommand {
    /// Ask for one history type: `05 <queryKey>` with an **empty** payload. There is no cursor or time
    /// range — the ring always dumps everything it has stored for that type.
    static func historyRequest(_ type: YCBTHistoryType) -> [UInt8] {
        [YCBTGroup.health, type.queryKey]
    }

    /// The mandatory end-of-transfer ACK: `05 80 {status}`. Without it the ring will not release the
    /// next type (`YCBTClientImpl.packetHealthHandle` sends `1408 = 0x0580` before it even parses).
    static func historyBlockAck(status: UInt8) -> [UInt8] {
        [YCBTGroup.health, YCBTHealth.terminalBlock, status]
    }
}

/// Device-side rejection of a command. The SDK's `isError` treats **any** 1-byte response payload in
/// `0xFB…0xFF` as an error status rather than data — for *every* group, which is why this is
/// frame-level rather than a Health-group concern: the DevControl push path checks it too (an error
/// frame is a rejection, not a push, and must not be ACKed).
enum YCBTFrameError: UInt8, Sendable {
    case unsupportedCommand = 0xfb   // the group byte isn't implemented
    case unsupportedKey = 0xfc       // the cmd byte isn't implemented on this firmware
    case length = 0xfd
    case data = 0xfe
    case crc = 0xff

    /// Detect an error frame. Must be checked *before* interpreting a payload as a header/record/push,
    /// because a 1-byte error payload is otherwise indistinguishable from a short header.
    static func detect(in payload: [UInt8]) -> YCBTFrameError? {
        guard payload.count == 1 else { return nil }
        return YCBTFrameError(rawValue: payload[0])
    }

    /// True when the ring is telling us it will *never* answer this type on this firmware, so the
    /// transfer machine can stop asking for the rest of the session.
    var isPermanent: Bool {
        self == .unsupportedCommand || self == .unsupportedKey
    }
}

/// Reassembles GATT notifications into whole logical frames.
///
/// A logical frame longer than `MTU-3` is split across notifications (and, symmetrically, several
/// short frames can land in a single notification). Validation keys off the declared total length at
/// bytes [2..3], exactly as `YCBTClientImpl`'s receive parser does: it buffers until `len` bytes are
/// in hand. Without this, every multi-notification history frame is dropped as garbage — which is one
/// half of why TK5 history never landed.
///
/// Garbage (a truncated tail after a disconnect, a stray notification) is resynced by dropping one
/// byte at a time until a plausible header appears, so one bad byte can't poison the rest of a session.
@MainActor
final class YCBTFrameAssembler {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Header + CRC with an empty payload — the shortest frame that can exist.
    private let minFrameLength = 6
    /// No YCBT frame comes close to this; a larger declared length means we're mid-garbage and should
    /// resync rather than wait forever for bytes that will never arrive.
    private let maxFrameLength = 1024

    /// Partial frames, per characteristic: the command channel and the async stream interleave, and a
    /// fragment from one must never be concatenated onto the other.
    private var pending: [CBUUID: [UInt8]] = [:]

    /// Drop every partial frame. A fresh driver is built per connection, so this exists for reconnects
    /// that reuse one (and for tests).
    func reset() {
        pending.removeAll()
    }

    /// Feed one notification; returns the complete logical frames it completed (0, 1, or several).
    func append(_ data: Data, from characteristic: CBUUID) -> [Data] {
        var buffer = pending[characteristic] ?? []
        buffer.append(contentsOf: data)

        var frames: [Data] = []
        while buffer.count >= 4 {
            let declared = Int(buffer[2]) | (Int(buffer[3]) << 8)
            guard isPlausibleGroup(buffer[0]), declared >= minFrameLength, declared <= maxFrameLength else {
                buffer.removeFirst()   // resync: this can't be a frame start
                continue
            }
            guard buffer.count >= declared else { break }   // still waiting on the rest of this frame
            frames.append(Data(buffer[0..<declared]))
            buffer.removeFirst(declared)
        }

        pending[characteristic] = buffer
        return frames
    }

    /// Only the six groups the ring ever sends us can legitimately start a frame; anything else is a
    /// misaligned byte.
    private func isPlausibleGroup(_ byte: UInt8) -> Bool {
        (YCBTGroup.setting...YCBTGroup.real).contains(byte)
    }
}

/// Parser for the `02 01` **SupportFunction** reply: a variable-length bit array (bit 7 of each byte
/// first) in which the firmware declares what it actually implements. Mirrors
/// `DataUnpack.saveDeviceSupportFunctionData`.
///
/// This is what lets one driver serve a whole *family* of rings whose SKUs disagree: a family declares
/// a capability as `bitmapGatedCapabilities` and the connected unit's own bitmap decides whether it is
/// really there (see `WearableCoordinator.refinedCapabilities`). Getting a bit wrong is not a cosmetic
/// error — it either hides a metric the ring has, or renders a card / "Measure" button the ring will
/// never fill — so the table below maps **only** bits whose meaning is pinned by an actual caller in
/// the vendor app, and omits everything else.
enum YCBTSupportFunction {
    /// One capability bit: its byte, its bit index (7 = MSB, matching the SDK's `(b >> n) & 1`), and the
    /// **payload length the SDK demands before it will read that byte at all**.
    ///
    /// `minLength` is not a bounds check — it reproduces `saveDeviceSupportFunctionData`'s own nested
    /// `if (bArr.length >= N)` blocks (and its caller's `>= 14` in `YCBTClientImpl`), which admit one
    /// whole firmware-generation block at a time. The distinction is real: a 16-byte bitmap *has* a
    /// physical byte 15, but the vendor SDK — the thing every YCBT firmware was built and tested
    /// against — refuses to read it below 18 bytes, so a ring may well leave garbage there. Every gate
    /// is ≥ `byte + 1`, so this one check also length-guards the access.
    private struct Bit {
        let byte: Int
        let bit: Int
        let minLength: Int
        let capability: WearableCapability
    }

    /// Bit → capability, each named with the `Constants.FunctionConstant` the SDK stores it under.
    ///
    /// Evidence for the metric bits is the vendor app's *own* "should I show this card?" switch,
    /// `HomeFragmentModelUtil.checkedFunction`, which pins each flag to a named metric screen —
    /// 心率→HEARTRATE, 睡眠→SLEEP, 血压→BLOOD (so `ISHASBLOOD` is blood *pressure*), 血氧→BLOODOXYGEN,
    /// HRV→HRV, 温度→TEMP, 血糖→BLOODSUGAR, 压力→PRESSURE (so `IS_HAS_PRESSURE` is *stress*, not BP).
    /// `DataSyncUtils` corroborates by gating each history query on the same flag, and adds STEPCOUNT.
    private static let bits: [Bit] = [
        Bit(byte: 0, bit: 7, minLength: 14, capability: .steps),           // ISHASSTEPCOUNT
        Bit(byte: 0, bit: 6, minLength: 14, capability: .sleep),           // ISHASSLEEP
        Bit(byte: 0, bit: 3, minLength: 14, capability: .heartRate),       // ISHASHEARTRATE
        Bit(byte: 0, bit: 0, minLength: 14, capability: .bloodPressure),   // ISHASBLOOD
        Bit(byte: 1, bit: 3, minLength: 14, capability: .spo2),            // ISHASBLOODOXYGEN
        Bit(byte: 1, bit: 1, minLength: 14, capability: .hrv),             // ISHASHRV
        Bit(byte: 8, bit: 0, minLength: 14, capability: .temperature),     // ISHASTEMP
        Bit(byte: 17, bit: 3, minLength: 18, capability: .bloodSugar),     // ISHASBLOODSUGAR
        Bit(byte: 22, bit: 6, minLength: 23, capability: .stress),         // IS_HAS_PRESSURE

        // **Fatigue rides the stress bit** — the one entry where two capabilities share a bit, because
        // the *ring* gives them one switch. There is no `ISHASFATIGUE` anywhere in the SDK (no `FATIGUE`,
        // no `TIRED`, no 疲劳), and the vendor app has no fatigue home card for `checkedFunction` to gate.
        // What it has instead is `DataSyncUtils.syncData`, which gates the **whole body-data history
        // query** — `Health_History_Body_Data`, our `05 33` — on `IS_HAS_PRESSURE` and nothing else:
        //
        //     if (YCBTClient.isSupportFunction(FunctionConstant.IS_HAS_PRESSURE)) {
        //         arrayList.add(DATATYPE.Health_History_Body_Data);
        //     }
        //
        // Stress (`pressureInteger`) and fatigue (`bodyInteger`) are two fields of that one record
        // (`DataUnpack.unpackBodyData`), so a ring with the bit clear is never even *asked* for the
        // record — the vendor app can no more show a fatigue score on it than a stress one. Deriving both
        // from byte 22 bit 6 reproduces exactly that, and is what lets `.fatigue` be gated at all: an
        // ungated `.fatigue` is an unconditional promise (the R99 answered `05 33` with `0xFC`), and a
        // gate no bit can satisfy is a dead one (`PairingMatchingTests`).
        Bit(byte: 22, bit: 6, minLength: 23, capability: .fatigue),        // IS_HAS_PRESSURE (same record)

        // Find-my-ring. `DeviceSupportFunctionUtil.isHasFindDevice` reads it, and `MeAntiLostActivity`
        // hides the whole screen without it.
        Bit(byte: 6, bit: 4, minLength: 14, capability: .findDevice),      // ISHASFINDDEVICE

        // Spot-measurement support — a *separate* question from whether the ring logs the metric, which
        // is why these are their own bits: a ring can trend SpO₂ all day and still refuse to measure it
        // on demand. Each one gates exactly the start button on its measure screen in the vendor app
        // (`llStartButton.setVisibility(GONE)` when absent), which is the same promise PulseLoop's
        // `manual…` capabilities make to `VitalsView`, so they map 1:1.
        Bit(byte: 15, bit: 1, minLength: 18, capability: .manualHeartRate),      // ISHATESTHEART      → HeartRateActivity
        Bit(byte: 15, bit: 2, minLength: 18, capability: .manualBloodPressure),  // ISHASTESTBLOOD     → BloodPressureActivity
        Bit(byte: 15, bit: 3, minLength: 18, capability: .manualSpo2),           // ISHASTESTSPO2      → BloodOxygenActivity
        Bit(byte: 23, bit: 0, minLength: 24, capability: .manualHrv),            // IS_HAS_HRV_MEASUREMENT → HRVActivity
    ]

    // Bits deliberately NOT mapped, and why — a bit we can't *name* is a capability we'd be inventing:
    //
    // • ISHASREALDATA (0.5) — the obvious candidate for `.realtimeHeartRate`/`.realtimeSteps`, but no
    //   caller anywhere in the app or SDK reads it (only a dead `DeviceSupportFunctionUtil` getter), so
    //   neither its meaning nor its scope is pinned — and it could not distinguish the two anyway.
    // • ISHASFACTORYSETTING (6.3) — confidently named, but PulseLoop implements no YCBT factory-reset or
    //   power-off command, so a derived `.factoryReset`/`.powerOff` could never be honoured.
    // • IS_HAS_BATTERY_INFO_UPLOAD (22.5) — declares the unsolicited `06 15` push, not whether battery is
    //   readable. Battery is in-band on `02 00` for every YCBT ring, so `.battery` stays a baseline.
    // • `.remSleep`, `.spo2History` — no bit names them, and no *caller* gates them separately either.
    //   They are sub-features of bits that don't distinguish them: REM is a stage tag inside the `05 04`
    //   timeline `ISHASSLEEP` already grants, and the all-day `05 1A` log is one of the SpO₂ sources
    //   `ISHASBLOODOXYGEN` grants. A family's baseline is therefore the only source for them — and,
    //   unlike `.fatigue` above, there is nothing to defer to: no bit's *behaviour* implies them.
    // • `.measurementInterval` — IS_HAS_INDEPENDENT_AUTOMATIC_TIME_MEASUREMENT (20.5) is the nearest, but
    //   "independent" is unpinned by any caller: it may mean "has per-metric intervals" or "has an
    //   interval at all", and those gate different screens.
    // • ECG / dial / notification / per-sport bits — PulseLoop has no capability for any of them.

    /// The capabilities this unit claims. A payload too short to clear even the SDK's own `>= 14` gate
    /// yields the empty set — every bit's `minLength` is at least that — which under the additive-only
    /// refinement means "no opinion", i.e. the family's baseline stands. That is the safe direction: a
    /// truncated or garbage reply must never be read as the ring *denying* a capability.
    static func capabilities(from payload: [UInt8]) -> Set<WearableCapability> {
        var out: Set<WearableCapability> = []
        for bit in bits where isSet(payload, bit) {
            out.insert(bit.capability)
        }
        return out
    }

    /// Raw bit array (MSB first within each byte) for the debug feed / diagnostics — the bitmap has far
    /// more bits than we map, and an unrecognised device is easier to triage from the raw view.
    static func rawBits(from payload: [UInt8]) -> [Bool] {
        payload.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 == 1 } }
    }

    private static func isSet(_ payload: [UInt8], _ bit: Bit) -> Bool {
        guard payload.count >= bit.minLength, bit.byte < payload.count else { return false }
        return (payload[bit.byte] >> UInt8(bit.bit)) & 1 == 1
    }
}

/// The `02 1b` **chipScheme** reply (`DataUnpack.unpackGetChipScheme`): one byte naming the chipset/OTA
/// family. Diagnostic only — PulseLoop does no firmware updates — but it is the frame that says whether
/// the ring's OTA path is JieLi RCSP, which is the auth we deliberately don't implement (see `YCBTUUIDs`).
enum YCBTChipScheme {
    /// `bArr[0] & 0xFF`, except that a value ≥ 240 is an error status (`YCBTFrameError`'s `0xFB…0xFF`
    /// band), which the SDK folds to 0 = "unknown/other" rather than treating as a scheme id.
    static func value(from payload: [UInt8]) -> Int {
        guard let first = payload.first, first < 240 else { return 0 }
        return Int(first)
    }

    /// `InnerUtils.isJieLiChipScheme`: 3, 4 and 5 are the JieLi families (the ones that would need the
    /// AE00 RCSP handshake for OTA/watch-faces).
    static func isJieLi(_ value: Int) -> Bool {
        (3...5).contains(value)
    }
}
