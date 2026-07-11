import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The driver's frame routing, and the one thing it does that no decoder can: **acknowledging the ring's
/// DevControl pushes**. The ring retransmits a push until the app answers `04 <key> {00}`, so a missing
/// ACK doesn't just lose an event — it wedges the link with the same frame over and over.
@MainActor
final class YCBTDriverTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
    }

    private let stream = CBUUID(string: YCBTUUIDs.stream)

    /// The wire bytes the ring sees. The driver enqueues the *logical* command; `RingBLEClient` adds the
    /// length field and CRC via `frame(_:)`, so both halves are asserted here.
    private func wireBytes(_ driver: YCBTDriver, _ logical: Data) -> String {
        driver.frame(logical).hexString
    }

    // MARK: Group-4 auto-ACK

    /// A measurement-status push (`04 13`) must be ACKed with `04 13 07 00 00 <crc>` **and** decoded.
    func testDevControlPushIsAckedAndDecoded() {
        let writer = FakeWriter()
        let driver = YCBTDriver(writer: writer)

        // 04 13 | type 0 (heart rate), state 1, 72 bpm
        let push = YCBTFrame.frame([0x04, 0x13, 0x00, 0x01, 72])
        let events = driver.ingest(push, from: stream)

        XCTAssertEqual(writer.sent, [Data([0x04, 0x13, 0x00])], "every push is ACKed with `04 <key> {00}`")
        XCTAssertEqual(wireBytes(driver, writer.sent[0]), "0413070000e19d")

        guard case let .heartRateSample(bpm, _) = events.first else {
            return XCTFail("the push must still decode, got \(events)")
        }
        XCTAssertEqual(bpm, 72)
    }

    /// The ACK goes out for *every* DevControl key, not just the ones we decode — an unhandled push
    /// (SOS, find-phone, sedentary) still has to stop retransmitting. It surfaces as a plain ack.
    func testUnhandledDevControlPushIsStillAcked() {
        let writer = FakeWriter()
        let driver = YCBTDriver(writer: writer)

        // 04 00 — FindMobile ("find my phone" pressed on the ring). No product surface; ACK + log only.
        let events = driver.ingest(YCBTFrame.frame([0x04, 0x00, 0x01]), from: stream)

        XCTAssertEqual(writer.sent, [Data([0x04, 0x00, 0x00])])
        XCTAssertEqual(wireBytes(driver, writer.sent[0]), "04000700009a1d")
        guard case let .commandAck(commandId) = events.first else {
            return XCTFail("expected commandAck, got \(events)")
        }
        XCTAssertEqual(commandId, 0x00)
    }

    /// A 1-byte `0xFB…0xFF` payload on group 4 is an **error frame**, not a push. The SDK drops it
    /// silently; ACKing it would answer a rejection with an ACK for a push that never happened.
    func testDevControlErrorFrameIsNotAcked() {
        let writer = FakeWriter()
        let driver = YCBTDriver(writer: writer)

        _ = driver.ingest(YCBTFrame.frame([0x04, 0x13, 0xfc]), from: stream)

        XCTAssertTrue(writer.sent.isEmpty, "an error frame must never be ACKed")
    }

    /// Only group 4 is ACKed. A live-stream frame (group 6) that got an ACK would put a stray `06 xx`
    /// write on the wire for every heartbeat the ring streams.
    func testLiveStreamFramesAreNotAcked() {
        let writer = FakeWriter()
        let driver = YCBTDriver(writer: writer)

        _ = driver.ingest(YCBTFrame.frame([0x06, 0x01, 82]), from: stream)

        XCTAssertTrue(writer.sent.isEmpty)
    }

    // MARK: Disconnect

    /// The history transfer is self-driving: its stall watchdog is a timer, so a ring that drops out of
    /// range mid-dump leaves it stepping through the rest of the catalog — one `05 xx` query every 10 s —
    /// into a write queue `RingBLEClient` only clears *at* disconnect. The reconnect would then flush
    /// those stale queries ahead of the handshake, against a fresh transfer that never asked for them.
    /// The driver must therefore abandon the transfer when the link **ends**, not when the next begins.
    ///
    /// An in-flight transfer refuses a re-entrant `start`, so a second `syncHistory()` writing its first
    /// query again is the proof that the disconnect really did abandon the first.
    func testConnectionDidEndAbandonsTheInFlightHistoryTransfer() {
        let writer = FakeWriter()
        let driver = YCBTDriver(writer: writer)
        let engine = driver.makeSyncEngine()

        engine.syncHistory()                       // → `05 02` (sport); the transfer is now in flight
        XCTAssertEqual(writer.sent, [Data([0x05, 0x02])])

        writer.sent.removeAll()
        engine.syncHistory()
        XCTAssertTrue(writer.sent.isEmpty, "sanity: an in-flight transfer refuses a re-entrant start")

        driver.connectionDidEnd()                  // the ring went out of range mid-dump

        engine.syncHistory()
        XCTAssertEqual(writer.sent, [Data([0x05, 0x02])], "the transfer must have been abandoned on disconnect")
    }
}
