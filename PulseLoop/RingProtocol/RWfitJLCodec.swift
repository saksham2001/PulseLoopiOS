import Foundation

/// One deframed JieLi (`0xAB`) event, as surfaced to `RWfitDriver.ingest`.
enum RWfitJLInbound: Equatable {
    /// CRC-verified response or push. Payload retains the addressing triple and response body.
    case frame(flag: UInt8, triple: RWfitJLTriple, payload: [UInt8])
    /// A completed frame failed its CRC. The vendor drops these without a NACK (`r5/b.java`).
    case crcFailed
}

/// JieLi (`0xAB`) wire codec: framing, CRC-16/ARC, ACKs, and inbound continuation reassembly.
/// Matches the official open-source SDK framing and ACK contract (commit pinned below).
/// https://github.com/RWFitSDK/RW_weixi_miniprogram_sdk/blob/8613daec2c08a41fa6c0bf5476af4f125e1532e5/RW_SDK_DEMO/sdk/rw-ble-sdk.min.js
///
/// Header (6 bytes): `AB flag lenHi lenLo crcHi crcLo`, followed by the payload — whose first three
/// bytes are the `{CMD, Key, KeyFlag}` triple and count toward both `len` and the CRC. A payload
/// longer than one notification continues in **headerless** packets: raw payload bytes until `len`
/// have arrived.
@MainActor
final class RWfitJLCodec {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let maximumPayloadLength = 8 * 1024
    private var buffer: [UInt8] = []

    func reset() { buffer.removeAll() }

    // MARK: - Encode

    /// Frame one payload (triple + data). `isAck: true` sets the reply flag `0x11` — used only for
    /// the ACKs we owe the device; everything else goes out as a request (`0x01`).
    func encode(payload: [UInt8], isAck: Bool = false) -> Data {
        var frame: [UInt8] = [0xab, isAck ? 0x11 : 0x01]
        frame.append(contentsOf: RWfitBytes.packU16BE(payload.count))
        let crc = RWfitBytes.crc16ARC(payload)
        frame.append(UInt8(crc >> 8))
        frame.append(UInt8(crc & 0xff))
        frame.append(contentsOf: payload)
        return Data(frame)
    }

    /// The SDK acknowledges flag-01 frames with flag 11 and exactly the echoed three-byte triple,
    /// including measurement status 0609. Pushes and flag-11 responses are never acknowledged.
    func ack(triple: RWfitJLTriple) -> Data {
        encode(payload: triple.bytes, isAck: true)
    }

    // MARK: - Decode

    /// Feed one notification. Returns the events completed by it (usually none mid-reassembly).
    func decode(_ data: Data) -> [RWfitJLInbound] {
        buffer.append(contentsOf: data)
        var events: [RWfitJLInbound] = []
        while !buffer.isEmpty {
            guard let magic = buffer.firstIndex(of: 0xab) else {
                buffer.removeAll()
                break
            }
            if magic > 0 { buffer.removeFirst(magic) }
            guard buffer.count >= 6 else { break }
            let flag = buffer[1]
            let length = RWfitBytes.u16BE(buffer, 2)
            guard [0x01, 0x11, 0x21].contains(flag), (3...Self.maximumPayloadLength).contains(length) else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length + 6 else { break }
            let payload = Array(buffer[6..<(length + 6)])
            let expectedCRC = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
            guard RWfitBytes.crc16ARC(payload) == expectedCRC else {
                events.append(.crcFailed)
                buffer.removeFirst()
                continue
            }
            buffer.removeFirst(length + 6)
            let triple = RWfitJLTriple(cmd: payload[0], key: payload[1], keyFlag: payload[2])
            events.append(.frame(flag: flag, triple: triple, payload: payload))
        }
        return events
    }
}
