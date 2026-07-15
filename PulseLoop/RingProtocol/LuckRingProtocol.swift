import Foundation
@preconcurrency import CoreBluetooth

/// LuckRing / TK18 ("K6 Protocol B") protocol primitives — GATT topology, the fixed 20-byte packet
/// framing, opcodes, the MixInfo TLV, and the little-endian byte helpers. This is the wire language the
/// whole 0xFF64 LuckRing family speaks (PID families 618/818/118/518/S2, sold under simsonlab and other
/// brands); what makes a *TK18* a TK18 is only its advertised identity + capability set, which live in
/// `LuckRingCoordinator`.
///
/// Ground truth is the decompiled vendor SDK (`ce.com.cenewbluesdk`, internal family "K6"):
/// `CEBC.java` (opcodes), `queue/b.java` (framing + the app-ACK rule), `K6SendDataManager.java`
/// (`sendAynInfoDetail()` — the connect bundle), `entity/k6/K6_*.java` (struct byte layouts) and
/// `.../BlueProcessBean/ProcessDATA_TYPE_*.java` (record parsers). Written up in
/// `tasks/luckring-protocol.md`, which is the reference to read before touching any byte offset here.
///
/// **Framing.** Every write/notify is a fixed **20-byte** packet. The head packet is
///   `[0]=0 [1]=devType [2]=#continuation-pages [3]=rolling-seq [4]=cmdType [5]=dataType`
///   `[6..7]=CRC16 (always 0x0000 — disabled in vendor code) [8..9]=payloadLen LE [10..19]=payload[0..9]`
/// and each continuation is `[0]=1-based page index [1..19]=next 19 payload bytes`. All integers are
/// little-endian. There is no crypto and no CRC to compute; binding is the MixInfo bundle (dataType 110).
enum LuckRingUUIDs {
    /// Primary protocol service.
    static let service = "0000f618-0000-1000-8000-00805f9b34fb"
    /// Notify characteristic (CCCD) — the ring streams every reply / data frame here.
    static let notify = "0000b001-0000-1000-8000-00805f9b34fb"
    /// Write characteristic — the app writes every 20-byte packet here.
    static let write = "0000b002-0000-1000-8000-00805f9b34fb"

    /// Standard BLE Heart Rate service. Present on the ring but **deliberately not subscribed** — mirror
    /// the YCBT rationale: the proprietary `07` stream reflects real finger contact, the standard `180D`
    /// characteristic can emit a stale cached value. Kept here only to document the GATT layout.
    static let heartRateService = "180D"

    /// The head packet's `devType` byte. TK18 is a **618-family** unit (`CEBC.PID_TYPE.PID_618 == 1`); the
    /// ring never validates an inbound head's devType (`queue/b.java` just stores `bArr[1]`), and every ACK
    /// we send echoes the value the ring itself used, so this is only the seed for the first outbound
    /// packets before any frame has been received.
    static let deviceType: UInt8 = 1
}

/// The `cmdType` byte (`CEBC.K6.CMD_TYPE_*`). The app ACKs a device-initiated **SEND**; it never ACKs an
/// ACK or a SEND_NO_ACK (which by definition expects none), so ACKing only `.send` can neither stall the
/// ring nor spam the wire.
enum LuckRingCmdType: UInt8, Sendable {
    case send = 1
    case sendNoAck = 2
    case request = 3
    case ack = 4
}

/// The `dataType` opcodes (`CEBC.K6.DATA_TYPE_*`). Only the ones PulseLoop drives or decodes are named;
/// the rest of the vendor table (alarms, watch faces, contacts, OTA, …) has no product surface here.
enum LuckRingDataType {
    static let devInfo: UInt8 = 2          // 6B → firmware "customer.hardware.code.picture.font"
    static let battery: UInt8 = 3          // [percent][charging]
    static let realSport: UInt8 = 4        // live step buckets
    static let historySport: UInt8 = 5     // stored step buckets
    static let sleep: UInt8 = 6            // paged sleep timeline
    static let realHeart: UInt8 = 7        // live HR (envelope + 5B records)
    static let historyHeart: UInt8 = 8     // stored HR
    static let devSync: UInt8 = 9          // settings sync — reply is a MixInfo TLV
    static let mixSport: UInt8 = 10        // workout records (skipped in v1)
    static let findDevice: UInt8 = 11      // buzz the ring
    static let functionControl: UInt8 = 22 // capability bitmap (obfuscated — not mapped)
    static let exerciseHeart: UInt8 = 17   // workout HR (envelope + 5B records)
    static let realBP: UInt8 = 18          // live blood pressure
    static let realO2: UInt8 = 20          // live SpO₂
    static let realHR: UInt8 = 24          // real-HR toggle (write side)
    static let historyO2: UInt8 = 40       // stored SpO₂
    static let historyBP: UInt8 = 41       // stored blood pressure
    static let historyHRV: UInt8 = 42      // stored HRV
    static let realHRV: UInt8 = 45         // live HRV toggle + stream
    static let realTemp: UInt8 = 46        // live temperature toggle + stream
    static let historyTemp: UInt8 = 47     // stored temperature
    static let stress: UInt8 = 52          // body-recovery / stress (live)
    static let stressHistory: UInt8 = 53   // body-recovery / stress (stored)
    static let userInfo: UInt8 = 102       // 9B profile
    static let language: UInt8 = 103
    static let time: UInt8 = 104           // 9B clock
    static let dataSwitch: UInt8 = 109     // 1 enables the real-time pushes
    static let mixInfo: UInt8 = 110        // the binding / startup TLV bundle
    static let goals: UInt8 = 111          // 16B goals
    static let reset: UInt8 = 118
    static let pairFinish: UInt8 = 120     // ring → app: pairing complete
    static let heartAutoSwitch: UInt8 = 128 // 8B auto-monitoring config (autoHR/interval/autoO2)
    static let callAlarm: UInt8 = 124
    static let unbind: UInt8 = 159
}

/// Little-endian helpers. Every K6 integer is LE (`ByteUtil.int2bytes2` / `intToByte4` / `byte4ToInt`).
enum LuckRingBytes {
    static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 2 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    static func u24(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 3 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16)
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard b.count >= i + 4 else { return 0 }
        return UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }
}

/// A *logical* K6 frame — one command or one reassembled data frame, independent of how many 20-byte
/// packets carry it. `cmdType`/`dataType`/`payload` are the meaning; `seq`/`devType` are the framing
/// identifiers an ACK must echo back (`queue/b.java` copies `bArr[3]`/`bArr[1]` into its reply).
struct LuckRingFrame: Equatable, Sendable {
    var cmdType: LuckRingCmdType
    var dataType: UInt8
    var payload: [UInt8]
    var seq: UInt8 = 0
    var devType: UInt8 = LuckRingUUIDs.deviceType
}

/// Splits a logical frame into exact 20-byte packets, and builds the mandatory app-ACK.
///
/// Page math mirrors `queue/b.java`'s `a(length)`: the head carries the first 10 payload bytes, each
/// continuation the next 19, so `pages = ceil((len-10)/19)` (0 when `len ≤ 10`). Every packet is
/// zero-padded to 20 bytes; `[6..7]` is always `0x0000` because the vendor sends `figureCrc16()==0`.
struct LuckRingPacketizer {
    /// The fixed BLE packet size (`queue/b.java`'s `h`).
    static let packetSize = 20
    private static let headPayload = 10
    private static let continuationPayload = 19

    /// The number of continuation pages a payload of `length` bytes needs.
    static func continuationPages(payloadLength length: Int) -> Int {
        guard length > headPayload else { return 0 }
        let remainder = length - headPayload
        return remainder / continuationPayload + (remainder % continuationPayload > 0 ? 1 : 0)
    }

    func packets(for frame: LuckRingFrame) -> [Data] {
        let payload = frame.payload
        let pages = Self.continuationPages(payloadLength: payload.count)

        var head = [UInt8](repeating: 0, count: Self.packetSize)
        head[0] = 0
        head[1] = frame.devType
        head[2] = UInt8(min(pages, 255))
        head[3] = frame.seq
        head[4] = frame.cmdType.rawValue
        head[5] = frame.dataType
        // [6..7] CRC16 disabled (0x0000); [8..9] payload length LE.
        head[8] = UInt8(payload.count & 0xff)
        head[9] = UInt8((payload.count >> 8) & 0xff)
        for i in 0..<min(Self.headPayload, payload.count) {
            head[Self.headPayload + i] = payload[i]
        }
        var out = [Data(head)]

        if pages > 0 {
            for page in 1...pages {
                var packet = [UInt8](repeating: 0, count: Self.packetSize)
                packet[0] = UInt8(min(page, 255))
                let start = Self.headPayload + (page - 1) * Self.continuationPayload
                for i in 0..<Self.continuationPayload where start + i < payload.count {
                    packet[1 + i] = payload[start + i]
                }
                out.append(Data(packet))
            }
        }
        return out
    }

    /// The app-ACK for a device-initiated SEND: `[4]=ack, [5]=dataType, len=1, payload[0]=1`. Echoes the
    /// ring's own `seq`/`devType` so the ring can pair the ACK to the frame it just sent, and stops it
    /// retransmitting. (`queue/b.java` writes `bArr[10]=1` because CRC is disabled and always "matches".)
    func ack(dataType: UInt8, seq: UInt8, devType: UInt8) -> Data {
        var packet = [UInt8](repeating: 0, count: Self.packetSize)
        packet[1] = devType
        packet[3] = seq
        packet[4] = LuckRingCmdType.ack.rawValue
        packet[5] = dataType
        packet[8] = 1                 // payload length = 1
        packet[10] = 1                // status 1 = accepted (CRC disabled ⇒ always accepted)
        return Data(packet)
    }
}

/// Reassembles 20-byte notify packets into whole logical frames.
///
/// A head packet (`[0]==0`) starts a frame and declares its payload length at `[8..9]` and its
/// continuation count at `[2]`; a device ACK head (`[4]==4`) is self-contained. Continuations
/// (`[0]!=0`) must arrive in strict 1-based order. A fresh head mid-assembly abandons the partial one
/// (`queue/b.java` overwrites its single buffer), and a continuation with no head is dropped — so one
/// truncated frame after a disconnect can't poison the next.
@MainActor
final class LuckRingFrameAssembler {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private struct Partial {
        let cmdType: LuckRingCmdType
        let dataType: UInt8
        let seq: UInt8
        let devType: UInt8
        let totalPages: Int
        let declaredLength: Int
        var payload: [UInt8]
        var receivedPages: Int
    }

    private var partial: Partial?

    /// Drop any half-assembled frame. A fresh driver is built per connection, so this is for reconnects
    /// that reuse one (and for tests).
    func reset() { partial = nil }

    /// Feed one 20-byte notify packet; returns the frame it completed, or nil while still assembling.
    func append(_ data: Data) -> LuckRingFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= LuckRingPacketizer.packetSize else { return nil }

        if bytes[0] == 0 {
            return handleHead(bytes)
        }
        return handleContinuation(bytes)
    }

    private func handleHead(_ bytes: [UInt8]) -> LuckRingFrame? {
        let devType = bytes[1]
        let seq = bytes[3]
        let rawCmd = bytes[4] & 0x0f
        let dataType = bytes[5]
        let cmdType = LuckRingCmdType(rawValue: rawCmd) ?? .send

        // A device ACK is a complete, single-packet frame — its status byte is at [10].
        if cmdType == .ack {
            partial = nil
            return LuckRingFrame(cmdType: .ack, dataType: dataType, payload: [bytes[10]], seq: seq, devType: devType)
        }

        let declaredLen = LuckRingBytes.u16(bytes, 8)
        let totalPages = Int(bytes[2])
        let firstChunk = Array(bytes[10..<min(20, 10 + max(0, declaredLen))])

        if totalPages == 0 {
            partial = nil
            return LuckRingFrame(cmdType: cmdType, dataType: dataType,
                                 payload: Array(firstChunk.prefix(declaredLen)), seq: seq, devType: devType)
        }

        // Multi-packet: seed the buffer with the head's first 10 payload bytes and wait for continuations.
        partial = Partial(cmdType: cmdType, dataType: dataType, seq: seq, devType: devType,
                          totalPages: totalPages, declaredLength: declaredLen,
                          payload: firstChunk, receivedPages: 0)
        return nil
    }

    private func handleContinuation(_ bytes: [UInt8]) -> LuckRingFrame? {
        guard var current = partial else { return nil }   // continuation with no head — drop it
        let pageIndex = Int(bytes[0])
        guard pageIndex == current.receivedPages + 1 else {
            // A jumped/duplicated page can't be recovered into this frame; abandon it.
            partial = nil
            return nil
        }
        current.payload.append(contentsOf: bytes[1..<20])
        current.receivedPages = pageIndex
        partial = current

        guard current.receivedPages >= current.totalPages else { return nil }
        partial = nil
        // Trim to the head's declared length — the last continuation is zero-padded to 20 bytes, and the
        // vendor codec sizes its buffer from the declared length. Without the cut, decoders that derive a
        // record stride from the payload size (temperature's 5B/8B variants) would misparse.
        return LuckRingFrame(cmdType: current.cmdType, dataType: current.dataType,
                             payload: Array(current.payload.prefix(current.declaredLength)),
                             seq: current.seq, devType: current.devType)
    }
}

/// The MixInfo TLV (`K6_MixInfoStruct`): the container the K6 protocol uses for its binding bundle
/// (dataType 110) and its settings-sync reply (dataType 9). Layout:
///   `[totalLen u16 LE][itemCount u8]` then, per property, `[propLen u16 LE = dataLen+3][propType u8][data]`.
/// `totalLen` is `(Σ propBytes) + 1` — the size of everything after the length field itself — and is
/// ignored on decode, which walks `itemCount` properties from offset 3.
enum LuckRingMixInfoTLV {
    struct Property: Equatable {
        let type: UInt8
        let data: [UInt8]
    }

    static func encode(_ properties: [Property]) -> [UInt8] {
        var propBytes: [UInt8] = []
        for property in properties {
            let propLen = property.data.count + 3
            propBytes.append(contentsOf: LuckRingBytes.le16(propLen))
            propBytes.append(property.type)
            propBytes.append(contentsOf: property.data)
        }
        var out = LuckRingBytes.le16(propBytes.count + 1)
        out.append(UInt8(properties.count & 0xff))
        out.append(contentsOf: propBytes)
        return out
    }

    static func decode(_ bytes: [UInt8]) -> [Property] {
        guard bytes.count >= 3 else { return [] }
        let itemCount = Int(bytes[2])
        var properties: [Property] = []
        var i = 3
        for _ in 0..<itemCount {
            guard i + 3 <= bytes.count else { break }
            let propLen = LuckRingBytes.u16(bytes, i)
            let dataLen = propLen - 3
            guard dataLen >= 0, i + 3 + dataLen <= bytes.count else { break }
            let type = bytes[i + 2]
            let data = Array(bytes[(i + 3)..<(i + 3 + dataLen)])
            properties.append(Property(type: type, data: data))
            i += propLen
        }
        return properties
    }
}
