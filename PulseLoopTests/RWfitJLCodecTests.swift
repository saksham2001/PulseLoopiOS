import XCTest
@testable import PulseLoop

/// The JieLi (`0xAB`) wire contract: header layout, CRC-16/ARC, the triple-echo ACK (with its
/// exact three-byte payload), and headerless continuation reassembly against the official SDK.
@MainActor
final class RWfitJLCodecTests: XCTestCase {

    func testCRC16ARCReferenceVector() {
        // The standard CRC-16/ARC check value — proves the bitwise form matches the vendor's table.
        XCTAssertEqual(RWfitBytes.crc16ARC(Array("123456789".utf8)), 0xbb3d)
        XCTAssertEqual(RWfitBytes.crc16ARC([]), 0)
    }

    func testEncodeHeaderLayout() {
        let payload: [UInt8] = [0x02, 0x03, 0x10]
        let frame = [UInt8](RWfitJLCodec().encode(payload: payload))

        XCTAssertEqual(frame[0], 0xab)
        XCTAssertEqual(frame[1], 0x01, "requests carry flag 0x01")
        XCTAssertEqual(RWfitBytes.u16BE(frame, 2), 3, "dataLen counts the triple")
        let crc = RWfitBytes.crc16ARC(payload)
        XCTAssertEqual(frame[4], UInt8(crc >> 8), "CRC big-endian in the header")
        XCTAssertEqual(frame[5], UInt8(crc & 0xff))
        XCTAssertEqual(Array(frame[6...]), payload)
    }

    func testAckEchoesTripleWithFlag11() {
        let ack = [UInt8](RWfitJLCodec().ack(triple: RWfitJLTriple(cmd: 0x05, key: 0x03, keyFlag: 0x10)))
        XCTAssertEqual(ack[1], 0x11)
        XCTAssertEqual(Array(ack[6...]), [0x05, 0x03, 0x10])
    }

    func testRealtimeAckEchoesOnlyTriple() {
        // SDK ACKs all commands uniformly, including 0609 measurement state.
        let ack = [UInt8](RWfitJLCodec().ack(triple: RWfitJLTriple(cmd: 0x06, key: 0x09, keyFlag: 0x00)))
        XCTAssertEqual(Array(ack[6...]), [0x06, 0x09, 0x00])
        XCTAssertEqual(ack.count, 9)
    }

    func testDecodeSingleFrameRoundTrip() {
        let codec = RWfitJLCodec()
        let payload: [UInt8] = [0x02, 0x03, 0x10, 0x5a, 0x0e, 0xd8]
        let events = codec.decode(codec.encode(payload: payload))
        XCTAssertEqual(events, [.frame(flag: 0x01, triple: RWfitJLTriple(cmd: 0x02, key: 0x03, keyFlag: 0x10),
                                       payload: payload)])
    }

    func testDecodeDeviceAck() {
        let codec = RWfitJLCodec()
        let events = codec.decode(codec.encode(payload: [0x02, 0x01, 0x00], isAck: true))
        XCTAssertEqual(events, [.frame(flag: 0x11, triple: RWfitJLTriple(cmd: 0x02, key: 0x01, keyFlag: 0x00),
                                       payload: [0x02, 0x01, 0x00])])
    }

    func testHeaderlessContinuationReassembly() {
        let codec = RWfitJLCodec()
        // A 40-byte payload split as the firmware does: header packet with the first bytes, then a
        // raw continuation carrying the rest — no header, no magic (`r5/b.java`'s multi-packet arm).
        let payload: [UInt8] = [0x05, 0x03, 0x10] + (0..<37).map { UInt8($0) }
        let whole = [UInt8](codec.encode(payload: payload))
        let headerPacket = Data(whole[0..<26])
        let continuation = Data(whole[26...])

        XCTAssertTrue(codec.decode(headerPacket).isEmpty, "nothing surfaces mid-reassembly")
        let events = codec.decode(continuation)
        XCTAssertEqual(events, [.frame(flag: 0x01, triple: RWfitJLTriple(cmd: 0x05, key: 0x03, keyFlag: 0x10),
                                       payload: payload)])
    }

    func testCRCFailureIsSurfacedAndDropped() {
        let codec = RWfitJLCodec()
        var corrupted = [UInt8](codec.encode(payload: [0x02, 0x03, 0x10, 0x42]))
        corrupted[9] ^= 0xff
        XCTAssertEqual(codec.decode(Data(corrupted)), [.crcFailed])
    }

    func testGarbageIsDropped() {
        let codec = RWfitJLCodec()
        XCTAssertTrue(codec.decode(Data([0x7e, 0x01, 0x01, 0x00])).isEmpty,
                      "a legacy frame on a JieLi link is noise, not a crash")
    }

    func testResetDropsHalfAssembledFrame() {
        let codec = RWfitJLCodec()
        let payload: [UInt8] = [0x05, 0x03, 0x10] + (0..<37).map { UInt8($0) }
        let whole = [UInt8](codec.encode(payload: payload))
        _ = codec.decode(Data(whole[0..<26]))
        codec.reset()
        XCTAssertTrue(codec.decode(Data(whole[26...])).isEmpty,
                      "a continuation from the dropped link must not complete on the new one")
    }
    func testEveryHeaderSplitPreservesResponseBodyAndPushFlag() {
        for flag in [UInt8(0x01), 0x11, 0x21] {
            for split in 1...6 {
                let codec = RWfitJLCodec()
                let payload: [UInt8] = [0x02, 0x03, 0x10, 76]
                var frame = [UInt8](codec.encode(payload: payload))
                frame[1] = flag
                XCTAssertTrue(codec.decode(Data(frame.prefix(split))).isEmpty)
                XCTAssertEqual(codec.decode(Data(frame.dropFirst(split))), [
                    .frame(flag: flag, triple: .battery, payload: payload),
                ])
            }
        }
    }

    func testMultipleFramesAndCRCRecoveryInOneNotification() {
        let codec = RWfitJLCodec()
        let payload: [UInt8] = [0x02, 0x03, 0x10, 76]
        let valid = codec.encode(payload: payload)
        var broken = [UInt8](valid)
        broken[4] ^= 1
        XCTAssertEqual(codec.decode(Data(broken) + valid + valid), [
            .crcFailed, .frame(flag: 0x01, triple: .battery, payload: payload),
            .frame(flag: 0x01, triple: .battery, payload: payload),
        ])
    }

    func testOversizedHeaderCannotBlockNextValidFrame() {
        let codec = RWfitJLCodec()
        let payload: [UInt8] = [0x02, 0x03, 0x10, 76]
        let invalid = Data([0xab, 0x01, 0x20, 0x01, 0, 0])
        XCTAssertEqual(codec.decode(invalid + codec.encode(payload: payload)), [
            .frame(flag: 0x01, triple: .battery, payload: payload),
        ])
    }

}
