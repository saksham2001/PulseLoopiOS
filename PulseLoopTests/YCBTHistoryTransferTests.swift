import XCTest
@testable import PulseLoop

/// The YCBT history protocol, end to end: query → header → data frames → terminal block → **mandatory
/// ACK** → next type. This is the machinery PulseLoop never had (it paged with `02 26`, an unrelated
/// Get-group opcode, and never ACKed), so these assert the exact outbound bytes, not just behaviour.
@MainActor
final class YCBTHistoryTransferTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
    }

    /// Logical (unframed) commands — the writer seam takes these; `RingBLEClient` adds len + CRC.
    private let heartQuery = Data([0x05, 0x06])
    private let allQuery = Data([0x05, 0x09])
    private let ackAccepted = Data([0x05, 0x80, 0x00])
    private let ackCrcFailure = Data([0x05, 0x80, 0x04])

    /// `[recordCount:u16][totalPackets:u32][totalBytes:u32]`.
    private func header(records: Int, packets: Int, bytes: Int) -> [UInt8] {
        [UInt8(records & 0xff), UInt8(records >> 8),
         UInt8(packets & 0xff), UInt8(packets >> 8), 0, 0,
         UInt8(bytes & 0xff), UInt8(bytes >> 8), 0, 0]
    }

    /// `[totalPackets:u16][totalBytes:u16][crc16:u16]` over the concatenated data payloads.
    private func terminal(packets: Int, buffer: [UInt8], crc: UInt16? = nil) -> [UInt8] {
        let checksum = crc ?? YCBTFrame.crc16(buffer)
        return [UInt8(packets & 0xff), UInt8(packets >> 8),
                UInt8(buffer.count & 0xff), UInt8((buffer.count >> 8) & 0xff),
                UInt8(checksum & 0xff), UInt8((checksum >> 8) & 0xff)]
    }

    /// Two 6-byte HR records (2026-07-06 ~23:00, 71 and 66 bpm) — the same shape the capture carries.
    private let heartBuffer: [UInt8] = [
        0x1c, 0xf0, 0xde, 0x31, 0x00, 0x47,
        0x1a, 0xfe, 0xde, 0x31, 0x00, 0x42,
    ]

    private func heartRates(_ events: [RingDecodedEvent]) -> [Double] {
        events.compactMap { event in
            if case let .historyMeasurement(.heartRate, value, _) = event { return value } else { return nil }
        }
    }

    /// Wait until the watchdog has written `command` — never a fixed sleep: the *next* type's own
    /// watchdog starts running the moment this one is written, so a test that oversleeps is timing the
    /// wrong skip.
    private func waitForWrite(_ command: Data, by writer: FakeWriter) async throws {
        for _ in 0..<500 {
            if writer.sent.contains(command) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("the watchdog never skipped the stalled type")
    }

    // MARK: Happy path

    func testFullCycleAcksAndAdvancesToTheNextType() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)

        transfer.start(types: [.heart, .all])
        XCTAssertEqual(writer.sent, [heartQuery], "start must write `05 06`, the Health-group heart query")

        let progress = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        guard case let .historySyncProgress(stage) = progress.first else {
            return XCTFail("the header must announce progress, got \(progress)")
        }
        XCTAssertEqual(stage, "Syncing heart rate…")

        XCTAssertTrue(transfer.handle(cmd: 0x15, payload: heartBuffer).isEmpty, "data frames decode nothing on their own")

        writer.sent.removeAll()
        let done = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))

        XCTAssertEqual(heartRates(done), [71, 66])
        XCTAssertEqual(writer.sent, [ackAccepted, allQuery],
                       "the terminal block must be ACKed `05 80 00` before the next type is requested")
    }

    /// The regression the whole rewrite exists for: the ring cuts the record stream at frame boundaries
    /// wherever they fall, so a record straddles two data frames. Decoding per-frame (what the old
    /// decoder did) drops it.
    func testRecordStraddlingTwoDataFramesSurvives() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart])

        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 2, bytes: heartBuffer.count))
        // Split mid-record: 9 bytes then 3, so record #2 spans both frames.
        _ = transfer.handle(cmd: 0x15, payload: Array(heartBuffer[0..<9]))
        _ = transfer.handle(cmd: 0x15, payload: Array(heartBuffer[9...]))
        let done = transfer.handle(cmd: 0x80, payload: terminal(packets: 2, buffer: heartBuffer))

        XCTAssertEqual(heartRates(done), [71, 66], "the straddling record must survive reassembly")
    }

    // MARK: Failure paths

    func testCRCMismatchNacksAndRetriesTheTypeOnce() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart, .all])

        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)

        writer.sent.removeAll()
        let first = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer, crc: 0xdead))
        XCTAssertTrue(heartRates(first).isEmpty, "a corrupt buffer must not be decoded")
        XCTAssertEqual(writer.sent, [ackCrcFailure, heartQuery], "NACK `05 80 04`, then re-request the same type")

        // Second failure on the retry: give up on the type rather than looping the ring forever.
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        writer.sent.removeAll()
        _ = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer, crc: 0xdead))
        XCTAssertEqual(writer.sent, [ackCrcFailure, allQuery], "after one retry the type is skipped")
    }

    /// A header of ≤9 bytes is the SDK's "no stored data" reply. There is no transfer, so there is
    /// nothing to ACK — ACKing here would tell the ring we accepted a block it never sent.
    func testNoDataHeaderAdvancesWithoutAcking() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart, .all])

        writer.sent.removeAll()
        _ = transfer.handle(cmd: 0x06, payload: [0x00])
        XCTAssertEqual(writer.sent, [allQuery])
    }

    /// A 1-byte `0xFB…0xFF` payload is a rejection. `0xFC` (unsupported key) is permanent: the type is
    /// dropped for the rest of the session, so a later sync doesn't ask again.
    func testErrorFrameAdvancesAndUnsupportedTypeIsNotRequestedAgain() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart, .all])

        writer.sent.removeAll()
        _ = transfer.handle(cmd: 0x06, payload: [0xfc])
        XCTAssertEqual(writer.sent, [allQuery], "an error frame advances the queue and is never ACKed")

        _ = transfer.handle(cmd: 0x09, payload: [0xfc])
        writer.sent.removeAll()
        transfer.start(types: [.heart, .all])
        XCTAssertTrue(writer.sent.isEmpty, "types the firmware rejected are not re-requested this session")
    }

    // MARK: Queue composition (A3)

    /// The engine asks for the full nine-type catalog, in the SDK's ascending-key order
    /// (`02 04 06 08 09 1A 1E 2F 33`). Sport before All is deliberate: sport buckets *assign* a past
    /// day's step total while the All record's cumulative counter only ratchets it up, so the counter
    /// must land last. Each type here answers "no data", which advances the queue without an ACK —
    /// exactly what a ring that doesn't implement a type does.
    func testEngineRequestsEveryHistoryTypeInOrder() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer)
        engine.runStartup()

        var requested: [UInt8] = []
        for _ in 0..<YCBTHistoryType.catalog.count {
            // A history query is the only 2-byte Health-group command the engine writes.
            guard let query = writer.sent.last(where: { $0.count == 2 && $0[0] == 0x05 }) else { break }
            requested.append(query[1])
            _ = transfer.handle(cmd: query[1], payload: [0x00])
        }
        XCTAssertEqual(requested, [0x02, 0x04, 0x06, 0x08, 0x09, 0x1a, 0x1e, 0x2f, 0x33])
    }

    // MARK: Targeted passes + re-entrancy (A5)

    /// The post-workout backfill asks for exactly the three logs a workout can have added to — heart
    /// (`06`), all (`09`), SpO₂ (`1A`) — not the full nine-type catalog. Sleep / body data / metabolic
    /// can't have changed in the last 40 minutes and are the slow transfers.
    func testSyncVitalsHistoryQueuesOnlyTheThreeVitalsTypes() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer)

        engine.syncVitalsHistory()

        var requested: [UInt8] = []
        while let query = writer.sent.last(where: { $0.count == 2 && $0[0] == 0x05 }) {
            requested.append(query[1])
            writer.sent.removeAll()
            _ = transfer.handle(cmd: query[1], payload: [0x00])   // "no data" → advance
        }
        XCTAssertEqual(requested, [0x06, 0x09, 0x1a])
    }

    /// The periodic 30-minute pass re-runs the full catalog without the connect handshake.
    func testSyncHistoryRerunsTheFullCatalog() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer)

        engine.syncHistory()

        XCTAssertEqual(writer.sent, [Data([0x05, 0x02])], "the queue starts at the first catalog type")
        XCTAssertTrue(writer.sent.allSatisfy { $0[0] == 0x05 }, "no handshake frames — history only")
    }

    /// Three callers can now ask for a transfer (connect, post-workout backfill, the 30-minute pass). A
    /// second `start` while one is in flight must be ignored: the ring keeps streaming the *current*
    /// type's data frames regardless, and they would land in the new type's buffer and fail its CRC.
    func testStartIsIgnoredWhileATransferIsInFlight() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)

        transfer.start(types: [.heart, .all])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        XCTAssertTrue(transfer.isActive)

        writer.sent.removeAll()
        transfer.start(types: [.sleep])
        XCTAssertTrue(writer.sent.isEmpty, "a re-entrant start must not interrupt the in-flight type")

        // …and the in-flight transfer still completes normally, into its own buffer.
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        let done = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))
        XCTAssertEqual(heartRates(done), [71, 66])
        XCTAssertEqual(writer.sent, [ackAccepted, allQuery])
    }

    /// Frames that arrive with nothing in flight (a stray block after we moved on) are ignored.
    func testFramesWhileIdleAreIgnored() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        XCTAssertTrue(transfer.handle(cmd: 0x15, payload: heartBuffer).isEmpty)
        XCTAssertTrue(transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: [])).isEmpty)
        XCTAssertTrue(writer.sent.isEmpty, "an idle transfer must never write — least of all an ACK")
    }

    // MARK: Watchdog (safety net only)

    /// The watchdog exists so a silent ring can't wedge the queue. It must never ACK (that would claim
    /// we received a block we didn't) and must never stand in for the terminal block.
    func testWatchdogSkipsAStalledTypeAndNeverAcks() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 0.2)

        transfer.start(types: [.heart, .all])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        // …and then the ring goes silent: no terminal block ever arrives.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(writer.sent, [heartQuery, allQuery], "a stalled type is skipped, not ACKed")
        XCTAssertFalse(writer.sent.contains { $0.starts(with: [0x05, 0x80]) },
                       "the watchdog must never emit a block ACK")
    }

    /// A `05 80` carries no type identity, so a terminal that the ring sends *late* — for the type the
    /// watchdog just skipped — arrives while the machine is on the next one. It must be ignored, not
    /// charged to that type: its CRC cannot match a buffer it wasn't computed over, so honouring it would
    /// NACK the ring into re-dumping a type nothing was wrong with **and** burn the new type's one retry.
    /// A genuinely empty type never reaches a terminal (the ring says "no data" with the ≤9-byte header).
    func testLateTerminalForASkippedTypeIsIgnoredNotNackedAgainstTheNextType() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)

        transfer.start(types: [.heart, .all])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        // Heart stalls: the watchdog gives up on it and queries `all`. Everything after this point is
        // synchronous — `all` has an inactivity watchdog of its own, and this must run before it fires.
        try await waitForWrite(allQuery, by: writer)

        writer.sent.removeAll()
        // …and only now does heart's terminal turn up.
        let events = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(writer.sent.isEmpty, "a stale terminal must not NACK, and must not re-query")

        // The current type is untouched: it still completes, and still has its retry in hand.
        _ = transfer.handle(cmd: 0x09, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x18, payload: heartBuffer)
        _ = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer, crc: 0xdead))
        XCTAssertEqual(writer.sent, [ackCrcFailure, allQuery], "the retry the stale terminal would have eaten")
    }

    /// A completed transfer cancels its watchdog — otherwise it would fire mid-next-type and skip it.
    func testWatchdogIsNotArmedAfterCompletion() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 0.2)

        transfer.start(types: [.heart])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        _ = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))

        writer.sent.removeAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(writer.sent.isEmpty, "an idle transfer must stay quiet")
    }

    /// `cancel()` is what the driver calls on **disconnect**, and it has to stop the watchdog, not just
    /// reset the state: a watchdog left running walks the rest of the catalog while the ring is gone,
    /// queueing stale queries that the reconnect flushes ahead of its own handshake.
    func testCancelStopsTheWatchdogFromWalkingTheQueue() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 0.2)

        transfer.start(types: [.heart, .all])
        transfer.cancel()
        writer.sent.removeAll()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(writer.sent.isEmpty, "a cancelled transfer must not keep querying")
        XCTAssertFalse(transfer.isActive)
    }
}
