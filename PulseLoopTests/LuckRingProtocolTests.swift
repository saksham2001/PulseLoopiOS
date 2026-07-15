import XCTest
@testable import PulseLoop

/// The K6 "Protocol B" framing: the 20-byte packetizer (head / continuation / ACK), the assembler's
/// round-trip and its recovery from a stale head, and the MixInfo TLV. These are the bytes the ring sees
/// and the bytes it sends, so a golden-byte pin here is the whole contract.
@MainActor
final class LuckRingProtocolTests: XCTestCase {
    private let packetizer = LuckRingPacketizer()

    // MARK: Packetizer

    func testHeadPacketGoldenBytes() {
        // REQUEST devInfo (cmd 3, dataType 2, empty payload), seq 0, devType 1.
        let frame = LuckRingFrame(cmdType: .request, dataType: 2, payload: [], seq: 0, devType: 1)
        let packets = packetizer.packets(for: frame)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].count, 20)
        XCTAssertEqual(packets[0].hexString, "0001000003020000000000000000000000000000")
    }

    func testSinglePacketCarriesFirstTenPayloadBytes() {
        let frame = LuckRingFrame(cmdType: .send, dataType: 24, payload: [1], seq: 7, devType: 1)
        let packets = packetizer.packets(for: frame)
        XCTAssertEqual(packets.count, 1)
        let bytes = [UInt8](packets[0])
        XCTAssertEqual(bytes[0], 0)       // head marker
        XCTAssertEqual(bytes[1], 1)       // devType
        XCTAssertEqual(bytes[2], 0)       // continuation pages
        XCTAssertEqual(bytes[3], 7)       // seq
        XCTAssertEqual(bytes[4], 1)       // cmdType SEND
        XCTAssertEqual(bytes[5], 24)      // dataType
        XCTAssertEqual(bytes[8], 1)       // payload length LE
        XCTAssertEqual(bytes[9], 0)
        XCTAssertEqual(bytes[10], 1)      // payload[0]
    }

    func testAckGoldenBytes() {
        let ack = packetizer.ack(dataType: 8, seq: 5, devType: 1)
        XCTAssertEqual(ack.count, 20)
        // [4]=4 ACK, [5]=8 dataType, [8]=1 len, [10]=1 status.
        XCTAssertEqual(ack.hexString, "0001000504080000010001000000000000000000")
    }

    func testMultiPacketSplitAndPageCount() {
        // 25-byte payload → head (first 10) + 1 continuation (next 15 of 19).
        let payload = (0..<25).map { UInt8($0) }
        XCTAssertEqual(LuckRingPacketizer.continuationPages(payloadLength: 25), 1)
        let frame = LuckRingFrame(cmdType: .send, dataType: 110, payload: payload, seq: 3, devType: 1)
        let packets = packetizer.packets(for: frame)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].count, 20)
        XCTAssertEqual([UInt8](packets[0])[2], 1)     // one continuation page declared
        XCTAssertEqual([UInt8](packets[1])[0], 1)     // continuation index (1-based)
        XCTAssertEqual(Array([UInt8](packets[1])[1...15]), Array(payload[10...24]))
    }

    // MARK: Assembler round-trip

    func testAssemblerRoundTripSinglePacket() {
        let assembler = LuckRingFrameAssembler()
        let frame = LuckRingFrame(cmdType: .send, dataType: 3, payload: [88, 1], seq: 9, devType: 1)
        var completed: LuckRingFrame?
        for packet in packetizer.packets(for: frame) {
            completed = assembler.append(packet)
        }
        XCTAssertEqual(completed, frame)
    }

    func testAssemblerRoundTripMultiPacket() {
        let assembler = LuckRingFrameAssembler()
        let payload = (0..<67).map { UInt8($0 & 0xff) }   // the MixInfo bundle's size
        let frame = LuckRingFrame(cmdType: .send, dataType: 110, payload: payload, seq: 4, devType: 1)
        let packets = packetizer.packets(for: frame)
        XCTAssertEqual(packets.count, 4)                  // head + 3 continuations

        var completed: LuckRingFrame?
        for (i, packet) in packets.enumerated() {
            let result = assembler.append(packet)
            if i < packets.count - 1 {
                XCTAssertNil(result, "must not complete until the last continuation")
            } else {
                completed = result
            }
        }
        XCTAssertEqual(completed, frame)
    }

    func testAssemblerTrimsPaddingWhenPayloadDoesNotFillTheLastPage() {
        let assembler = LuckRingFrameAssembler()
        // 25 bytes needs one continuation but fills only 15 of its 19 payload slots: the last packet is
        // zero-padded on the wire, and the assembler must cut back to the head's declared length —
        // temperature derives its record stride from the payload size, so padding would corrupt it.
        let payload = (1...25).map { UInt8($0) }
        let frame = LuckRingFrame(cmdType: .send, dataType: 47, payload: payload, seq: 3, devType: 1)
        var completed: LuckRingFrame?
        for packet in packetizer.packets(for: frame) {
            completed = assembler.append(packet)
        }
        XCTAssertEqual(completed?.payload.count, 25, "padding from the final packet must be trimmed")
        XCTAssertEqual(completed, frame)
    }

    func testAssemblerRecoversFromAStaleHead() {
        let assembler = LuckRingFrameAssembler()
        // A head that promises continuations, then a *new* head before they arrive: the partial is dropped.
        let abandoned = LuckRingFrame(cmdType: .send, dataType: 5, payload: (0..<30).map { UInt8($0) }, seq: 1, devType: 1)
        _ = assembler.append(packetizer.packets(for: abandoned)[0])   // head only, no continuations

        let fresh = LuckRingFrame(cmdType: .send, dataType: 3, payload: [77, 0], seq: 2, devType: 1)
        let completed = assembler.append(packetizer.packets(for: fresh)[0])
        XCTAssertEqual(completed, fresh, "a fresh head mid-assembly abandons the stale partial and completes")
    }

    func testAssemblerDropsAContinuationWithNoHead() {
        let assembler = LuckRingFrameAssembler()
        var continuation = [UInt8](repeating: 0, count: 20)
        continuation[0] = 1
        XCTAssertNil(assembler.append(Data(continuation)))
    }

    func testAssemblerParsesADeviceAck() {
        let assembler = LuckRingFrameAssembler()
        // A device ACK head: [4]=4, status at [10].
        var ack = [UInt8](repeating: 0, count: 20)
        ack[1] = 1; ack[3] = 6; ack[4] = 4; ack[5] = 111; ack[8] = 1; ack[10] = 1
        let frame = assembler.append(Data(ack))
        XCTAssertEqual(frame?.cmdType, .ack)
        XCTAssertEqual(frame?.dataType, 111)
        XCTAssertEqual(frame?.payload, [1])
    }

    // MARK: MixInfo TLV

    func testMixInfoTLVRoundTrip() {
        let properties: [LuckRingMixInfoTLV.Property] = [
            .init(type: 102, data: [1, 2, 3, 4]),
            .init(type: 124, data: [1, 0xFF, 0xFF, 0, 0]),
            .init(type: 120, data: [1, 0]),
        ]
        let encoded = LuckRingMixInfoTLV.encode(properties)
        // Header: [totalLen u16 LE][itemCount], totalLen = Σ propBytes + 1.
        let propBytesLen = (4 + 3) + (5 + 3) + (2 + 3)
        XCTAssertEqual(LuckRingBytes.u16(encoded, 0), propBytesLen + 1)
        XCTAssertEqual(encoded[2], 3)
        XCTAssertEqual(LuckRingMixInfoTLV.decode(encoded), properties)
    }
}
