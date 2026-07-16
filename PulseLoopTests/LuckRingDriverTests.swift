import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The driver's inbound routing, and the one thing no decoder can do: **acknowledging a device-initiated
/// SEND**. The ring retransmits an un-ACKed SEND until the app answers, so a missing ACK wedges the link;
/// an ACK for an ACK, or for a SEND_NO_ACK, is wrong the other way.
@MainActor
final class LuckRingDriverTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
    }

    private let notify = CBUUID(string: LuckRingUUIDs.notify)
    private let packetizer = LuckRingPacketizer()

    private func packets(_ frame: LuckRingFrame) -> [Data] {
        packetizer.packets(for: frame)
    }

    /// Concatenate byte chunks without `+` chains — CI's older Swift compiler times out
    /// type-checking heterogeneous `[UInt8] + [literal]` expressions.
    private func cat(_ parts: [UInt8]...) -> [UInt8] {
        parts.flatMap { $0 }
    }

    // MARK: Auto-ACK

    func testDeviceSendIsAckedAndDecoded() {
        let writer = FakeWriter()
        let driver = LuckRingDriver(writer: writer)

        let frame = LuckRingFrame(cmdType: .send, dataType: LuckRingDataType.battery, payload: [90, 1], seq: 5, devType: 2)
        let events = driver.ingest(packets(frame)[0], from: notify)

        XCTAssertEqual(writer.sent.count, 1, "a device SEND must be ACKed")
        let ack = [UInt8](writer.sent[0])
        XCTAssertEqual(ack[4], 4, "ACK cmdType")
        XCTAssertEqual(ack[5], LuckRingDataType.battery, "ACK echoes the frame's dataType")
        XCTAssertEqual(ack[3], 5, "ACK echoes the frame's seq")
        XCTAssertEqual(ack[1], 2, "ACK echoes the frame's devType")

        guard case let .battery(percent) = events.first else { return XCTFail("expected battery, got \(events)") }
        XCTAssertEqual(percent, 90)
    }

    func testDeviceAckIsNotAcked() {
        let writer = FakeWriter()
        let driver = LuckRingDriver(writer: writer)

        var ack = [UInt8](repeating: 0, count: 20)
        ack[1] = 1; ack[4] = 4; ack[5] = LuckRingDataType.mixInfo; ack[8] = 1; ack[10] = 1
        _ = driver.ingest(Data(ack), from: notify)

        XCTAssertTrue(writer.sent.isEmpty, "an ACK must never be ACKed")
    }

    func testSendNoAckIsNotAcked() {
        let writer = FakeWriter()
        let driver = LuckRingDriver(writer: writer)

        let frame = LuckRingFrame(cmdType: .sendNoAck, dataType: LuckRingDataType.realHeart,
                                  payload: cat(LuckRingBytes.le16(1), [1], LuckRingBytes.le32(1_700_000_000), [70]),
                                  seq: 0, devType: 1)
        _ = driver.ingest(packets(frame)[0], from: notify)

        XCTAssertTrue(writer.sent.isEmpty, "a SEND_NO_ACK expects no reply")
    }

    // MARK: Reassembly

    func testMultiPacketFrameOnlyAcksAndDecodesOnceComplete() {
        let writer = FakeWriter()
        let driver = LuckRingDriver(writer: writer)

        // A 2-record HR history frame that spans a head + one continuation.
        let payload = cat(LuckRingBytes.le16(2), [2],
                          LuckRingBytes.le32(1_700_000_000), [72],
                          LuckRingBytes.le32(1_700_000_060), [75])
        let frame = LuckRingFrame(cmdType: .send, dataType: LuckRingDataType.historyHeart, payload: payload, seq: 1, devType: 1)
        let wire = packets(frame)
        XCTAssertGreaterThan(wire.count, 1)

        let firstEvents = driver.ingest(wire[0], from: notify)
        XCTAssertTrue(firstEvents.isEmpty, "no decode until the frame is whole")
        XCTAssertTrue(writer.sent.isEmpty, "no ACK until the frame is whole")

        let lastEvents = driver.ingest(wire[1], from: notify)
        XCTAssertEqual(writer.sent.count, 1, "ACK once, on completion")
        XCTAssertEqual(lastEvents.count, 2, "both HR records decode")
    }

    // MARK: Lifecycle

    func testConnectionResetDiscardsAPartialFrame() {
        let writer = FakeWriter()
        let driver = LuckRingDriver(writer: writer)

        let payload = cat(LuckRingBytes.le16(2), [2],
                          LuckRingBytes.le32(1_700_000_000), [72],
                          LuckRingBytes.le32(1_700_000_060), [75])
        let wire = packets(LuckRingFrame(cmdType: .send, dataType: LuckRingDataType.historyHeart, payload: payload, seq: 1, devType: 1))

        _ = driver.ingest(wire[0], from: notify)   // head only
        driver.connectionDidStart()                // the link came back — discard the partial
        let events = driver.ingest(wire[1], from: notify)   // a continuation with no head now

        XCTAssertTrue(events.isEmpty, "the reset dropped the partial, so the stray continuation is ignored")
        XCTAssertTrue(writer.sent.isEmpty)
    }
}
