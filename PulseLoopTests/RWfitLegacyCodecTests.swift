import XCTest
@testable import PulseLoop

/// The legacy (`0x7E`) wire contract: header layout, XOR checksums, serials, the two-sided ACK
/// handshake (device `0xFE` in, app `0xFF` out) and inbound multi-packet reassembly — all
/// byte-for-byte against `x5/d.java`. Fixtures are hand-assembled from that file's header math.
@MainActor
final class RWfitLegacyCodecTests: XCTestCase {

    /// Build an inbound device frame the way the ring's firmware does (single-packet).
    private func deviceFrame(cmd: UInt8, payload: [UInt8], serial: Int = 7) -> Data {
        var bytes: [UInt8] = [0x7e, 0x01, cmd, 0x00, UInt8(payload.count)]
        bytes += RWfitBytes.packU16BE(serial)
        bytes.append(payload.isEmpty ? 0 : RWfitBytes.xorChecksum(payload))
        bytes += payload
        return Data(bytes)
    }

    // MARK: - Encode

    func testEncodeSingleFrameLayout() {
        let codec = RWfitLegacyCodec()
        let (frame, serial) = codec.encode(cmd: 0x21, payload: [0x07, 0xea, 8, 5, 12, 30, 15])

        let bytes = [UInt8](frame)
        XCTAssertEqual(serial, 1, "serials start at 1")
        XCTAssertEqual(Array(bytes[0..<5]), [0x7e, 0x01, 0x21, 0x00, 7], "magic/version/cmd/flags/len")
        XCTAssertEqual(RWfitBytes.u16BE(bytes, 5), 1, "serial big-endian at [5..6]")
        XCTAssertEqual(bytes[7], RWfitBytes.xorChecksum([0x07, 0xea, 8, 5, 12, 30, 15]), "XOR of payload")
        XCTAssertEqual(Array(bytes[8...]), [0x07, 0xea, 8, 5, 12, 30, 15])
    }

    func testEncodeEmptyPayloadHasZeroChecksum() {
        let codec = RWfitLegacyCodec()
        let (frame, _) = codec.encode(cmd: 0xa3, payload: [])
        XCTAssertEqual([UInt8](frame), [0x7e, 0x01, 0xa3, 0x00, 0x00, 0x00, 0x01, 0x00])
    }

    func testSerialsIncrementPerFrame() {
        let codec = RWfitLegacyCodec()
        XCTAssertEqual(codec.encode(cmd: 0x01, payload: []).serial, 1)
        XCTAssertEqual(codec.encode(cmd: 0x01, payload: []).serial, 2)
    }

    func testAppAckFrameEchoesInboundSerial() {
        let codec = RWfitLegacyCodec()
        let ack = [UInt8](codec.ack(cmd: 0xa3, serial: 0x1234, status: 0x00))
        XCTAssertEqual(ack[2], RWfitLegacyCommand.appAck, "app ACKs go out as 0xFF")
        XCTAssertEqual(Array(ack[8...]), [0x12, 0x34, 0xa3, 0x00], "[inSerHi, inSerLo, cmd, status]")
    }

    // MARK: - Decode

    func testDecodeSingleFrameEmitsAckThenFrame() {
        let codec = RWfitLegacyCodec()
        let events = codec.decode(deviceFrame(cmd: 0x01, payload: [0, 0, 90], serial: 9))
        XCTAssertEqual(events, [
            .ackNeeded(cmd: 0x01, serial: 9),
            .frame(cmd: 0x01, payload: [0, 0, 90]),
        ], "ACK request precedes the frame — decode must never delay the ring's retransmit window")
    }

    func testDecodeDeviceAckIsNotAckedBack() {
        let codec = RWfitLegacyCodec()
        let events = codec.decode(deviceFrame(cmd: 0xfe, payload: [0x00, 0x03, 0x21, 0x00]))
        XCTAssertEqual(events, [.deviceAck(cmd: 0x21, serial: 3, status: 0)],
                       "a 0xFE releases the gate and must never generate an ACK of an ACK")
    }

    func testChecksumFailureAsksForRetransmit() {
        var corrupted = [UInt8](deviceFrame(cmd: 0x01, payload: [0, 0, 90], serial: 9))
        corrupted[8] ^= 0xff
        let events = RWfitLegacyCodec().decode(Data(corrupted))
        XCTAssertEqual(events, [.checksumFailed(cmd: 0x01, serial: 9)])
    }

    func testGarbageAndShortFramesAreDropped() {
        let codec = RWfitLegacyCodec()
        XCTAssertTrue(codec.decode(Data([0xab, 0x01])).isEmpty, "wrong magic")
        XCTAssertTrue(codec.decode(Data([0x7e, 0x01, 0x01])).isEmpty, "truncated header")
    }

    // MARK: - Multi-packet reassembly

    /// Chunked history reply: each chunk carries the full header + `totalBE currentBE`, each is
    /// individually ACKed, and the combined payload surfaces when the last chunk lands — sorted by
    /// chunk index, exactly like `x5/d.java h()`.
    private func chunk(cmd: UInt8, serial: Int, total: Int, current: Int, body: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x7e, 0x01, cmd, 0x08, UInt8(body.count)]
        bytes += RWfitBytes.packU16BE(serial)
        bytes.append(RWfitBytes.xorChecksum(body))
        bytes += RWfitBytes.packU16BE(total)
        bytes += RWfitBytes.packU16BE(current)
        bytes += body
        return Data(bytes)
    }

    func testMultiPacketReassemblyAcksEveryChunkAndJoinsInOrder() {
        let codec = RWfitLegacyCodec()

        let first = codec.decode(chunk(cmd: 0xa3, serial: 11, total: 2, current: 1, body: [1, 2, 3]))
        XCTAssertEqual(first, [.ackNeeded(cmd: 0xa3, serial: 11)], "no frame until all chunks are in")

        let second = codec.decode(chunk(cmd: 0xa3, serial: 12, total: 2, current: 2, body: [4, 5]))
        XCTAssertEqual(second, [
            .ackNeeded(cmd: 0xa3, serial: 12),
            .frame(cmd: 0xa3, payload: [1, 2, 3, 4, 5]),
        ])
    }

    func testResetDropsHalfAssembledFrames() {
        let codec = RWfitLegacyCodec()
        _ = codec.decode(chunk(cmd: 0xa3, serial: 11, total: 2, current: 1, body: [1, 2, 3]))
        codec.reset()
        let events = codec.decode(chunk(cmd: 0xa3, serial: 12, total: 2, current: 2, body: [4, 5]))
        XCTAssertEqual(events, [.ackNeeded(cmd: 0xa3, serial: 12)],
                       "a chunk from the dropped link must not complete a frame on the new one")
    }
}
