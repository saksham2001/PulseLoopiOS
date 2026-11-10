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

    // MARK: Terminal cross-check

    /// The CRC alone does not catch a **short** buffer. A dropped data frame leaves us holding fewer
    /// bytes than the ring sent; cross-checking the terminal's packet and byte counts against both the
    /// header's promise and the buffer we actually built turns "silently short" into a NAK and a retry.
    func testTerminalWithMismatchedCountsIsNakedAndRetried() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: Array(heartBuffer.prefix(6)))   // one frame lost
        writer.sent.removeAll()

        // The ring's terminal describes what it *sent* — 12 bytes — but we only hold 6.
        let events = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))

        XCTAssertEqual(writer.sent.first, ackCrcFailure, "a short buffer must be NAKed, not accepted")
        XCTAssertEqual(writer.sent.last, heartQuery, "and the type re-requested")
        XCTAssertTrue(events.isEmpty, "nothing may be decoded from a buffer we know is incomplete")
    }

    /// A terminal whose counts disagree with the *header* is equally untrustworthy, even when its own
    /// byte count happens to match the buffer.
    func testTerminalDisagreeingWithTheHeaderIsNaked() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 9, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        writer.sent.removeAll()

        _ = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))

        XCTAssertEqual(writer.sent.first, ackCrcFailure)
    }

    /// The happy path must be unaffected: matching counts and CRC still ACK and decode.
    func testMatchingCountsStillAcceptTheTransfer() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        writer.sent.removeAll()

        let events = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))

        XCTAssertEqual(writer.sent.first, ackAccepted)
        XCTAssertEqual(events.filter { if case .historyMeasurement = $0 { return true } else { return false } }.count, 2)
    }

    // MARK: append

    /// The ring's `02 01` bitmap arrives *during* the startup walk, so the types it unlocks have to join
    /// the queue without disturbing the block in flight — `start` refuses outright while active, which is
    /// right for a second full pass and wrong for this.
    func testAppendExtendsTheQueueWithoutDisturbingTheInFlightType() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart])
        _ = transfer.handle(cmd: 0x06, payload: header(records: 2, packets: 1, bytes: heartBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: heartBuffer)
        writer.sent.removeAll()

        transfer.append(types: [.all])
        XCTAssertTrue(writer.sent.isEmpty, "append must not interrupt the block being received")

        _ = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))
        XCTAssertEqual(writer.sent.last, allQuery, "the appended type is requested when the queue reaches it")
    }

    /// Appending while idle has to start the machine, or a bitmap that lands after a finished walk would
    /// leave its types unfetched until the next sync.
    func testAppendStartsTheMachineWhenIdle() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)

        transfer.append(types: [.all])

        XCTAssertEqual(writer.sent, [allQuery])
    }

    /// Asking twice would re-dump a log we already hold and re-upsert every record in it.
    func testAppendIgnoresTypesAlreadyQueuedOrInFlight() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart, .all])
        writer.sent.removeAll()

        transfer.append(types: [.heart, .all])

        XCTAssertTrue(writer.sent.isEmpty, "neither the in-flight type nor a queued one may be re-added")
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
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: .permissiveTestProfile)
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

    // MARK: Capability-gated queue

    /// A ring that doesn't implement a type answers "no data" or `0xFC`, both handled — so this is not
    /// about correctness, it is about not spending ten seconds of watchdog per absent type on every
    /// single sync. For the R10M baseline that leaves exactly four queries.
    func testR10MStartupAsksOnlyForTheLogsItKeeps() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: YCBTFamilyProfile(
            baselineCapabilities: YCBTCoordinator().capabilities,
            bitmapGatedCapabilities: YCBTCoordinator().bitmapGatedCapabilities,
            queryChipSchemeAtStartup: false,
            supportsBloodPressureMonitor: false
        ))
        engine.runStartup()

        var requested: [UInt8] = []
        while let query = writer.sent.last(where: { $0.count == 2 && $0[0] == 0x05 }) {
            requested.append(query[1])
            writer.sent.removeAll()
            _ = transfer.handle(cmd: query[1], payload: [0x00])   // "no data" → advance
        }
        XCTAssertEqual(requested, [0x02, 0x04, 0x06, 0x09], "sport, sleep, heart, all — and nothing else")
        XCTAssertFalse(requested.contains(0x1a), "no dedicated SpO₂ log on this ring")
    }

    /// A capability the bitmap unlocks mid-walk has to reach the queue, or its log waits for the next
    /// sync. `.all` is re-queued alongside because BP is an *optional field* of a record we already ran —
    /// so the run that just happened decoded it with that field dropped.
    func testALateBitmapAppendsTheNewlyUnlockedTypes() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: YCBTFamilyProfile(
            baselineCapabilities: [.heartRate],
            bitmapGatedCapabilities: [.bloodPressure]
        ))
        // Baseline is heart-rate only, so the startup queue is heart + all (all is never gated).
        engine.runStartup()
        // The bitmap lands while `05 06` is still in flight — the case `start` cannot serve.
        engine.handle(.supportFunctions([.bloodPressure]))

        var requested: [UInt8] = []
        while let query = writer.sent.last(where: { $0.count == 2 && $0[0] == 0x05 }) {
            requested.append(query[1])
            writer.sent.removeAll()
            _ = transfer.handle(cmd: query[1], payload: [0x00])   // "no data" → advance
        }
        XCTAssertEqual(requested, [0x06, 0x09, 0x08], "the blood-pressure log joins the queue behind the rest")
    }

    /// A bitmap that lands *after* the walk finished has to restart the machine for its new types — the
    /// `05 09` combined record it already ran was decoded with the BP fields dropped.
    func testALateBitmapAfterTheWalkRerunsTheCombinedRecord() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: YCBTFamilyProfile(
            baselineCapabilities: [.heartRate],
            bitmapGatedCapabilities: [.bloodPressure]
        ))
        engine.runStartup()
        while let query = writer.sent.last(where: { $0.count == 2 && $0[0] == 0x05 }) {
            writer.sent.removeAll()
            _ = transfer.handle(cmd: query[1], payload: [0x00])
        }
        writer.sent.removeAll()

        engine.handle(.supportFunctions([.bloodPressure]))

        var requested: [UInt8] = []
        while let query = writer.sent.last(where: { $0.count == 2 && $0[0] == 0x05 }) {
            requested.append(query[1])
            writer.sent.removeAll()
            _ = transfer.handle(cmd: query[1], payload: [0x00])
        }
        XCTAssertTrue(requested.contains(0x08), "the blood-pressure log is now worth asking for")
        XCTAssertTrue(requested.contains(0x09), "and `all` is re-run for its optional BP fields")
    }

    /// The R10M ACKs the handshake's `03 09` but doesn't always start publishing until its history dump
    /// is done, so today's steps sit at whatever the last session left. One extra frame after the walk
    /// fixes a reconnect that otherwise looks frozen — and it must fire exactly once.
    func testLiveStatusIsReassertedOnceAfterTheStartupWalk() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: .permissiveTestProfile)
        let liveStatus = Data([0x03, 0x09, 0x01, 0x00, 0x02])

        engine.runStartup()
        writer.sent.removeAll()

        engine.handle(.historySyncFinished)
        XCTAssertEqual(writer.sent, [liveStatus])

        writer.sent.removeAll()
        engine.handle(.historySyncFinished)
        XCTAssertTrue(writer.sent.isEmpty, "only the startup walk earns the re-issue")
    }

    // MARK: Targeted passes + re-entrancy (A5)

    /// The post-workout backfill asks for exactly the three logs a workout can have added to — heart
    /// (`06`), all (`09`), SpO₂ (`1A`) — not the full nine-type catalog. Sleep / body data / metabolic
    /// can't have changed in the last 40 minutes and are the slow transfers.
    func testSyncVitalsHistoryQueuesOnlyTheThreeVitalsTypes() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: .permissiveTestProfile)

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
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: .permissiveTestProfile)

        engine.syncHistory()

        XCTAssertEqual(
            writer.sent,
            [Data([0x03, 0x09, 0x01, 0x00, 0x02]), Data([0x05, 0x02])],
            "live status is re-asserted, then the queue starts at the first catalog type"
        )
    }

    /// Pull-to-refresh is the gesture a user makes *because* today's steps look stale, and on a ring whose
    /// `03 09` subscription went quiet the history walk alone won't move them: the cumulative counter
    /// arrives on the `06 00` stream, not in any log.
    func testSyncHistoryReassertsLiveStatusBeforeTheWalk() {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: .permissiveTestProfile)

        engine.syncHistory()

        XCTAssertEqual(writer.sent.first, Data([0x03, 0x09, 0x01, 0x00, 0x02]))
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

    // MARK: Silent types (session memory)

    private let spo2Query = Data([0x05, 0x1a])

    /// Walk whatever the engine queued: every query is answered "no data", except `silentKey`, which
    /// gets nothing at all — the watchdog has to skip it. Returns the query keys in the order asked.
    private func walk(_ transfer: YCBTHistoryTransfer, _ writer: FakeWriter,
                      silentOn silentKey: UInt8? = nil) async throws -> [UInt8] {
        let isQuery: (Data) -> Bool = { $0.count == 2 && $0[0] == 0x05 }
        var requested: [UInt8] = []
        while let query = writer.sent.last(where: isQuery) {
            requested.append(query[1])
            writer.sent.removeAll()
            if query[1] == silentKey {
                for _ in 0..<500 where !writer.sent.contains(where: isQuery) && transfer.isActive {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                XCTAssertFalse(writer.sent.contains { $0.starts(with: [0x05, 0x80]) }, "a skip never ACKs")
            } else {
                _ = transfer.handle(cmd: query[1], payload: [0x00])
            }
        }
        XCTAssertFalse(transfer.isActive, "the walk must finish")
        return requested
    }

    /// The R99 never answers `05 1a` — no header, no error, nothing. That costs the watchdog once; after
    /// that, neither a vitals backfill nor the 30-minute pass on the same connection asks again.
    func testASilentTypeIsSkippedOnceThenNotAskedAgainOnTheSameConnection() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)
        let engine = YCBTSyncEngine(writer: writer, transfer: transfer, profile: .permissiveTestProfile)

        engine.syncVitalsHistory()
        let first = try await walk(transfer, writer, silentOn: 0x1a)
        XCTAssertEqual(first, [0x06, 0x09, 0x1a], "the first pass asks, and the watchdog skips it")

        engine.syncVitalsHistory()
        let backfill = try await walk(transfer, writer)
        XCTAssertEqual(backfill, [0x06, 0x09], "the next backfill no longer waits on the silent log")

        engine.syncHistory()
        let periodic = try await walk(transfer, writer)
        XCTAssertEqual(periodic, [0x02, 0x04, 0x06, 0x08, 0x09, 0x1e, 0x2f, 0x33],
                       "nor does the periodic full pass")
    }

    /// The memory belongs to one link: after a disconnect (`cancel()`, which the driver calls on both
    /// `connectionDidEnd` and `connectionDidStart`) a silent type is asked again. A `0xFC` rejection, by
    /// contrast, is a firmware fact and outlives the reconnect.
    func testASilentTypeIsAskedAgainAfterAReconnect() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)

        transfer.start(types: [.heart, .spo2])
        _ = transfer.handle(cmd: 0x06, payload: [0xfc])   // heart: unsupported key
        try await waitForWrite(spo2Query, by: writer)     // spo2: asked…
        for _ in 0..<500 where transfer.isActive { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(transfer.isActive, "…and skipped by the watchdog")

        writer.sent.removeAll()
        transfer.start(types: [.heart, .spo2])
        XCTAssertTrue(writer.sent.isEmpty, "both are remembered on this connection")

        transfer.cancel()
        transfer.start(types: [.heart, .spo2])
        XCTAssertEqual(writer.sent, [spo2Query], "a new link asks the silent type again, not the rejected one")
    }

    /// A ring that *answered* — a header, or even just a data frame — and then stalled has a transfer
    /// that went wrong, not a log it lacks. The next pass must try it again.
    func testATypeThatAnsweredThenStalledIsNotRememberedAsSilent() async throws {
        for firstFrame in [(cmd: UInt8(0x1a), payload: header(records: 2, packets: 1, bytes: heartBuffer.count)),
                           (cmd: UInt8(0x22), payload: heartBuffer)] {
            let writer = FakeWriter()
            let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)

            transfer.start(types: [.spo2])
            _ = transfer.handle(cmd: firstFrame.cmd, payload: firstFrame.payload)
            for _ in 0..<500 where transfer.isActive { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertFalse(transfer.isActive, "the watchdog skips the stalled type")

            writer.sent.removeAll()
            transfer.start(types: [.spo2])
            XCTAssertEqual(writer.sent, [spo2Query], "a type that replied on 0x\(String(firstFrame.cmd, radix: 16)) is asked again")
        }
    }

    /// `05 80` carries no type identity, so a late terminal for the previous type is not an answer from
    /// this one: a type that saw nothing else is still silent.
    func testALateTerminalForThePreviousTypeDoesNotCountAsAnAnswer() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)

        transfer.start(types: [.spo2])
        _ = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: heartBuffer))
        for _ in 0..<500 where transfer.isActive { try await Task.sleep(nanoseconds: 1_000_000) }

        writer.sent.removeAll()
        transfer.start(types: [.spo2])
        XCTAssertTrue(writer.sent.isEmpty)
    }

    /// Only the vendor-unqueried logs (`05 1a`, `05 1e`) may be remembered as silent. A core log that
    /// misses one reply is asked again on the very next pass — skipping it until a reconnect could let it
    /// fill up unread on a ring that stays connected for days.
    func testACoreLogThatMissedOneReplyIsAskedAgainNextPass() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)
        transfer.start(types: [.all])
        for _ in 0..<500 where transfer.isActive { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(transfer.isActive, "the watchdog skips the unanswered pass")

        writer.sent.removeAll()
        transfer.start(types: [.all])
        XCTAssertEqual(writer.sent, [allQuery], "the All log is never remembered as silent")
    }

    /// The bitmap path (`append`) must not re-ask a silent type either.
    func testAppendSkipsASilentType() async throws {
        let writer = FakeWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)
        transfer.start(types: [.spo2])
        for _ in 0..<500 where transfer.isActive { try await Task.sleep(nanoseconds: 1_000_000) }

        writer.sent.removeAll()
        transfer.append(types: [.spo2, .all])
        XCTAssertEqual(writer.sent, [allQuery])
    }
}
