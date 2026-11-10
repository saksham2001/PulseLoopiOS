import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The erase phase: after a walk, every type whose log was read intact is deleted off the ring with
/// `05 <deleteKey> {02}` — exactly as SmartHealth does after its database insert — but **only** once
/// `commitDeliveredHistory` has proved the records are on disk. A delete is irreversible, so most of
/// these tests are about the cases that must *not* send one.
@MainActor
final class YCBTHistoryEraseTests: XCTestCase {
    /// Records outbound commands and parks every commit request so the test decides the verdict.
    private final class CommitWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var sent: [Data] = []
        var commits: [@MainActor (Bool) -> Void] = []
        func enqueue(_ command: Data) { sent.append(command) }
        func commitDeliveredHistory(_ completion: @escaping @MainActor (Bool) -> Void) {
            commits.append(completion)
        }

        /// Logical Health-Delete commands written so far (`05 40…4E`).
        var deletes: [Data] { sent.filter { $0.count == 3 && $0[0] == 0x05 && (0x40...0x4e).contains($0[1]) } }
    }

    private let heartQuery = Data([0x05, 0x06])
    private let spo2Query = Data([0x05, 0x1a])
    private let allQuery = Data([0x05, 0x09])
    private let heartDelete = Data([0x05, 0x42, 0x02])
    private let spo2Delete = Data([0x05, 0x45, 0x02])
    private let allDelete = Data([0x05, 0x44, 0x02])

    /// Two 6-byte records — valid for heart (`05 06`) and SpO₂ (`05 1a`), which share the stride.
    private let sixByteBuffer: [UInt8] = [
        0x1c, 0xf0, 0xde, 0x31, 0x00, 0x47,
        0x1a, 0xfe, 0xde, 0x31, 0x00, 0x42,
    ]
    /// One 20-byte `05 09` combined record.
    private let allBuffer: [UInt8] = [0x1c, 0xf0, 0xde, 0x31] + [UInt8](repeating: 0, count: 16)

    private func header(packets: Int, bytes: Int) -> [UInt8] {
        [0x02, 0x00, UInt8(packets & 0xff), UInt8(packets >> 8), 0, 0,
         UInt8(bytes & 0xff), UInt8(bytes >> 8), 0, 0]
    }

    private func terminal(packets: Int, buffer: [UInt8], crc: UInt16? = nil) -> [UInt8] {
        let checksum = crc ?? YCBTFrame.crc16(buffer)
        return [UInt8(packets & 0xff), UInt8(packets >> 8),
                UInt8(buffer.count & 0xff), UInt8((buffer.count >> 8) & 0xff),
                UInt8(checksum & 0xff), UInt8((checksum >> 8) & 0xff)]
    }

    /// Header → one data frame → terminal, all accepted. Returns the terminal's events.
    @discardableResult
    private func complete(_ type: YCBTHistoryType, _ buffer: [UInt8], on transfer: YCBTHistoryTransfer,
                          crc: UInt16? = nil) -> [RingDecodedEvent] {
        _ = transfer.handle(cmd: type.queryKey, payload: header(packets: 1, bytes: buffer.count))
        _ = transfer.handle(cmd: type.ackKey, payload: buffer)
        return transfer.handle(cmd: YCBTHealth.terminalBlock, payload: terminal(packets: 1, buffer: buffer, crc: crc))
    }

    private func isFinished(_ events: [RingDecodedEvent]) -> Bool {
        events.contains { if case .historySyncFinished = $0 { return true } else { return false } }
    }

    /// The commit request is deliberately deferred a main-actor turn (see `beginErasePhase`), so wait for
    /// it rather than assert synchronously.
    private func waitForCommit(_ writer: CommitWriter, count: Int = 1) async throws {
        for _ in 0..<500 where writer.commits.count < count {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(writer.commits.count, count, "the erase phase must ask for a durable commit")
    }

    private func waitFor(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(message)
    }

    /// A transfer whose bitmap has arrived and whose walk of heart + SpO₂ has both completed with data.
    private func walkedTransfer(_ writer: CommitWriter, inactivitySeconds: TimeInterval = 10) -> YCBTHistoryTransfer {
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: inactivitySeconds)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart, .spo2])
        complete(.heart, sixByteBuffer, on: transfer)
        complete(.spo2, sixByteBuffer, on: transfer)
        return transfer
    }

    // MARK: Happy path

    /// Deletes go out after the **last** query, only on a `true` commit, one at a time in completion order —
    /// and the walk isn't finished until the last one is answered.
    func testDeletesFollowTheLastQueryAndACommittedSaveOneAtATime() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart, .spo2])

        complete(.heart, sixByteBuffer, on: transfer)
        XCTAssertEqual(writer.sent.last, spo2Query, "the next query, not a delete, follows a completed type")
        XCTAssertTrue(writer.deletes.isEmpty)

        let last = complete(.spo2, sixByteBuffer, on: transfer)
        XCTAssertFalse(isFinished(last), "the walk is not finished until its erase phase is")
        XCTAssertTrue(transfer.isActive)
        try await waitForCommit(writer)
        XCTAssertTrue(writer.deletes.isEmpty, "nothing may be deleted before the commit says the data is on disk")

        writer.commits[0](true)
        XCTAssertEqual(writer.deletes, [heartDelete], "one delete at a time, in completion order")

        XCTAssertTrue(transfer.handle(cmd: 0x45, payload: [0x00]).isEmpty, "a reply on another key is not ours")
        XCTAssertEqual(writer.deletes, [heartDelete])

        XCTAssertFalse(isFinished(transfer.handle(cmd: 0x42, payload: [0x00])))
        XCTAssertEqual(writer.deletes, [heartDelete, spo2Delete])

        XCTAssertTrue(isFinished(transfer.handle(cmd: 0x45, payload: [0x00])))
        XCTAssertFalse(transfer.isActive)
        XCTAssertEqual(writer.deletes, [heartDelete, spo2Delete], "each type is deleted exactly once")
    }

    // MARK: No commit, no delete

    func testAFailedCommitSendsNoDeleteAndFinishesTheWalk() async throws {
        let writer = CommitWriter()
        let transfer = walkedTransfer(writer)
        var outOfBand: [RingDecodedEvent] = []
        transfer.onOutOfBandEvents = { outOfBand.append(contentsOf: $0) }
        try await waitForCommit(writer)

        writer.commits[0](false)

        XCTAssertTrue(writer.deletes.isEmpty, "a failed save must leave the ring's data in place")
        XCTAssertFalse(transfer.isActive)
        XCTAssertTrue(isFinished(outOfBand), "the walk still finishes")
    }

    /// The default writer (no persistence proof) fails closed.
    func testTheDefaultWriterNeverAuthorizesADelete() async throws {
        final class PlainWriter: RingCommandWriter {
            nonisolated deinit {}
            var sent: [Data] = []
            func enqueue(_ command: Data) { sent.append(command) }
        }
        let writer = PlainWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart])
        complete(.heart, sixByteBuffer, on: transfer)

        try await waitFor({ !transfer.isActive }, "the walk must finish")
        XCTAssertFalse(writer.sent.contains { $0.count == 3 && (0x40...0x4e).contains($0[1]) })
    }

    // MARK: Ineligible types

    /// A no-data header and a twice-failed CRC both leave the type undeleted; only the type actually read
    /// intact is erased.
    func testNoDeleteForAnEmptyHeaderOrACRCFailure() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart, .all, .spo2])

        _ = transfer.handle(cmd: 0x06, payload: [0x00])                 // heart: "no data"
        complete(.all, allBuffer, on: transfer, crc: 0xdead)             // all: CRC fails…
        complete(.all, allBuffer, on: transfer, crc: 0xdead)             // …and fails the retry
        complete(.spo2, sixByteBuffer, on: transfer)
        try await waitForCommit(writer)
        writer.commits[0](true)

        XCTAssertEqual(writer.deletes, [spo2Delete])
    }

    /// When nothing is eligible there is nothing to commit: the walk finishes synchronously, as before.
    func testAWalkWithNothingEligibleFinishesWithoutACommit() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart])

        XCTAssertTrue(isFinished(transfer.handle(cmd: 0x06, payload: [0x00])))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(writer.commits.isEmpty)
        XCTAssertTrue(writer.deletes.isEmpty)
    }

    /// A type the watchdog abandoned was never verified, so it is never erased.
    func testNoDeleteForAWatchdogSkippedType() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart, .spo2])
        _ = transfer.handle(cmd: 0x06, payload: header(packets: 1, bytes: sixByteBuffer.count))
        _ = transfer.handle(cmd: 0x15, payload: sixByteBuffer)
        // Heart's terminal never comes.
        try await waitFor({ writer.sent.contains(self.spo2Query) }, "the watchdog never skipped heart")

        complete(.spo2, sixByteBuffer, on: transfer)
        try await waitForCommit(writer)
        writer.commits[0](true)

        XCTAssertEqual(writer.deletes, [spo2Delete])
    }

    /// A type the ring never answered at all (the R99's `05 1a`) is remembered as silent for the
    /// connection — and silence never makes it eligible: neither that walk nor a later one on the same
    /// link erases it, while the types that did answer are erased as usual.
    func testASilentTypeIsNeverErased() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer, inactivitySeconds: 0.05, absoluteCapSeconds: 5)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart, .spo2])
        complete(.heart, sixByteBuffer, on: transfer)
        XCTAssertEqual(writer.sent.last, spo2Query)
        // SpO₂: no header, no error, nothing — the watchdog skips it and the erase phase begins.
        try await waitForCommit(writer)
        writer.commits[0](true)
        XCTAssertTrue(isFinished(transfer.handle(cmd: 0x42, payload: [0x00])))
        XCTAssertEqual(writer.deletes, [heartDelete])

        writer.sent.removeAll()
        transfer.start(types: [.heart, .spo2])
        complete(.heart, sixByteBuffer, on: transfer)
        XCTAssertEqual(writer.sent, [heartQuery, Data([0x05, 0x80, 0x00])],
                       "the silent type is not asked again on this link")
        try await waitForCommit(writer, count: 2)
        writer.commits[1](true)
        XCTAssertEqual(writer.deletes, [heartDelete], "and is never erased")
    }

    /// Until this connection's `02 01` bitmap arrives, the driver filters samples on the baseline set, so
    /// a saved log may be missing fields the ring does have. Nothing is erased then.
    func testNoDeleteBeforeTheCapabilityBitmap() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart, .all])
        complete(.heart, sixByteBuffer, on: transfer)

        XCTAssertTrue(isFinished(complete(.all, allBuffer, on: transfer)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(writer.commits.isEmpty)
        XCTAssertTrue(writer.deletes.isEmpty, "neither heart nor all may be erased without the bitmap")
    }

    // MARK: Re-fetch (late bitmap) withdraws the erase

    /// A type re-queued mid-walk (the engine re-runs `all` when the bitmap unlocks one of its optional
    /// fields) loses its pending delete: the copy already saved is the incomplete one. If the re-run comes
    /// back empty, `all` stays on the ring.
    func testARequeuedTypeIsNotDeletedUnlessItsRerunCompletes() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.all, .heart])

        complete(.all, allBuffer, on: transfer)
        transfer.append(types: [.all])                     // late bitmap, heart in flight
        complete(.heart, sixByteBuffer, on: transfer)
        XCTAssertEqual(writer.sent.last, allQuery, "the re-run is asked for before any delete")
        _ = transfer.handle(cmd: 0x09, payload: [0x00])    // re-run: no data

        try await waitForCommit(writer)
        writer.commits[0](true)
        XCTAssertEqual(writer.deletes, [heartDelete], "all's first read is suspect, so it is not erased")
    }

    /// The same, when the re-queue lands *during* the erase phase: the remaining delete for that type is
    /// withdrawn, the re-run goes out once the in-flight delete is answered, and it earns its own erase.
    func testARequeueDuringTheErasePhaseDefersThatTypeToItsRerun() async throws {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.noteCapabilityBitmapReceived()
        transfer.start(types: [.heart, .all])
        complete(.heart, sixByteBuffer, on: transfer)
        complete(.all, allBuffer, on: transfer)
        try await waitForCommit(writer)
        writer.commits[0](true)
        XCTAssertEqual(writer.deletes, [heartDelete])

        transfer.append(types: [.all])
        XCTAssertEqual(writer.sent.last, heartDelete, "the in-flight delete is not interrupted")

        _ = transfer.handle(cmd: 0x42, payload: [0x00])
        XCTAssertEqual(writer.sent.last, allQuery, "all is re-fetched, not deleted")
        XCTAssertEqual(writer.deletes, [heartDelete])

        complete(.all, allBuffer, on: transfer)
        try await waitForCommit(writer, count: 2)
        writer.commits[1](true)
        XCTAssertEqual(writer.deletes, [heartDelete, allDelete], "the completed re-run is erased")
        XCTAssertTrue(isFinished(transfer.handle(cmd: 0x44, payload: [0x00])))
    }

    // MARK: Error replies

    /// A 1-byte error on a key that isn't the in-flight type's — e.g. a late rejection of a delete the
    /// watchdog gave up on — must not advance past the type being dumped.
    func testAStrayErrorReplyDoesNotSkipTheCurrentType() {
        let writer = CommitWriter()
        let transfer = YCBTHistoryTransfer(writer: writer)
        transfer.start(types: [.heart, .spo2])
        _ = transfer.handle(cmd: 0x06, payload: header(packets: 1, bytes: sixByteBuffer.count))

        XCTAssertTrue(transfer.handle(cmd: 0x42, payload: [0xfc]).isEmpty)
        XCTAssertTrue(transfer.handle(cmd: 0x09, payload: [0xfb]).isEmpty)
        XCTAssertEqual(writer.sent, [heartQuery], "a foreign error must not move the queue")

        _ = transfer.handle(cmd: 0x15, payload: sixByteBuffer)
        let done = transfer.handle(cmd: 0x80, payload: terminal(packets: 1, buffer: sixByteBuffer))
        XCTAssertEqual(done.filter { if case .historyMeasurement = $0 { return true } else { return false } }.count, 2,
                       "heart still completes into its own buffer")
        XCTAssertEqual(writer.sent.last, spo2Query)
    }

    /// The ring rejecting a delete is logged and the phase moves on — no retry, like the vendor.
    func testARejectedDeleteMovesOnWithoutRetry() async throws {
        let writer = CommitWriter()
        let transfer = walkedTransfer(writer)
        try await waitForCommit(writer)
        writer.commits[0](true)

        _ = transfer.handle(cmd: 0x42, payload: [0xfc])

        XCTAssertEqual(writer.deletes, [heartDelete, spo2Delete], "on to the next type, heart not re-sent")
    }

    /// A ring that never answers a delete can't hold the walk open: the watchdog moves on, then finishes.
    func testAnUnansweredDeleteTimesOutAndTheWalkFinishes() async throws {
        let writer = CommitWriter()
        let transfer = walkedTransfer(writer, inactivitySeconds: 0.05)
        var outOfBand: [RingDecodedEvent] = []
        transfer.onOutOfBandEvents = { outOfBand.append(contentsOf: $0) }
        try await waitForCommit(writer)
        writer.commits[0](true)

        try await waitFor({ !transfer.isActive }, "the delete watchdog never ended the phase")
        XCTAssertEqual(writer.deletes, [heartDelete, spo2Delete], "each delete once, no retry")
        XCTAssertTrue(isFinished(outOfBand))
    }

    // MARK: Re-entrancy + disconnect

    /// `.historySyncFinished` waits for the erase phase, and so does a new pass: a query interleaved with
    /// a delete could be answered out of order against either.
    func testStartIsRefusedUntilTheErasePhaseEnds() async throws {
        let writer = CommitWriter()
        let transfer = walkedTransfer(writer)
        let before = writer.sent.count

        transfer.start(types: [.sleep])                    // while awaiting the commit
        XCTAssertEqual(writer.sent.count, before)
        try await waitForCommit(writer)
        writer.commits[0](true)
        transfer.start(types: [.sleep])                    // while a delete is in flight
        XCTAssertFalse(writer.sent.contains(Data([0x05, 0x04])))

        _ = transfer.handle(cmd: 0x42, payload: [0x00])
        XCTAssertTrue(isFinished(transfer.handle(cmd: 0x45, payload: [0x00])))
        transfer.start(types: [.sleep])
        XCTAssertEqual(writer.sent.last, Data([0x05, 0x04]), "a pass is accepted once the phase is over")
    }

    /// A commit verdict that lands after a disconnect — even once a reconnect has started a fresh walk —
    /// authorizes nothing.
    func testACommitResolvedAfterDisconnectDeletesNothing() async throws {
        let writer = CommitWriter()
        let transfer = walkedTransfer(writer)
        try await waitForCommit(writer)

        transfer.cancel()                                  // disconnect
        transfer.noteCapabilityBitmapReceived()            // reconnect…
        transfer.start(types: [.heart])                    // …and a new walk begins
        writer.commits[0](true)                            // the old link's verdict arrives late

        XCTAssertTrue(writer.deletes.isEmpty)
        XCTAssertEqual(writer.sent.last, heartQuery, "the new walk is undisturbed")
    }

    /// A disconnect mid-phase stops it dead: no further deletes, from a reply or from the watchdog.
    func testDisconnectMidErasePhaseSendsNothingMore() async throws {
        let writer = CommitWriter()
        let transfer = walkedTransfer(writer, inactivitySeconds: 0.05)
        try await waitForCommit(writer)
        writer.commits[0](true)
        XCTAssertEqual(writer.deletes, [heartDelete])

        transfer.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)     // well past the delete watchdog
        _ = transfer.handle(cmd: 0x42, payload: [0x00])    // a late reply from the old link

        XCTAssertEqual(writer.deletes, [heartDelete], "nothing more may be deleted after a disconnect")
        XCTAssertFalse(transfer.isActive)
    }

    // MARK: Driver wiring

    private let stream = CBUUID(string: YCBTUUIDs.stream)
    private let command = CBUUID(string: YCBTUUIDs.command)

    /// Drive the vitals pass (heart → all → SpO₂) through the driver: heart has data, the rest are empty.
    private func driveVitalsPass(_ driver: YCBTDriver) {
        let engine = driver.makeSyncEngine()
        engine.syncVitalsHistory()
        _ = driver.ingest(YCBTFrame.frame([0x05, 0x06] + header(packets: 1, bytes: sixByteBuffer.count)), from: stream)
        _ = driver.ingest(YCBTFrame.frame([0x05, 0x15] + sixByteBuffer), from: stream)
        _ = driver.ingest(YCBTFrame.frame([0x05, 0x80] + terminal(packets: 1, buffer: sixByteBuffer)), from: stream)
        _ = driver.ingest(YCBTFrame.frame([0x05, 0x09, 0x00]), from: stream)
        _ = driver.ingest(YCBTFrame.frame([0x05, 0x1a, 0x00]), from: stream)
    }

    /// The driver tells the transfer when this connection's `02 01` reply lands — that is what enables
    /// erasing at all on a real link.
    func testTheDriversBitmapEnablesTheErasePhase() async throws {
        let writer = CommitWriter()
        let driver = YCBTDriver(writer: writer, profile: .permissiveTestProfile)
        driver.connectionDidStart()
        _ = driver.ingest(YCBTFrame.frame([0x02, 0x01] + [UInt8](repeating: 0, count: 27)), from: command)

        driveVitalsPass(driver)
        try await waitForCommit(writer)
        writer.commits[0](true)

        XCTAssertEqual(writer.deletes, [heartDelete], "only heart had records")
    }

    func testWithoutTheBitmapTheDriverNeverErases() async throws {
        let writer = CommitWriter()
        let driver = YCBTDriver(writer: writer, profile: .permissiveTestProfile)
        driver.connectionDidStart()

        driveVitalsPass(driver)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(writer.commits.isEmpty)
        XCTAssertTrue(writer.deletes.isEmpty)
    }

    /// The bitmap belongs to one link: after a reconnect, a walk that finishes before the new `02 01`
    /// reply erases nothing.
    func testTheBitmapDoesNotSurviveAReconnect() async throws {
        let writer = CommitWriter()
        let driver = YCBTDriver(writer: writer, profile: .permissiveTestProfile)
        driver.connectionDidStart()
        _ = driver.ingest(YCBTFrame.frame([0x02, 0x01] + [UInt8](repeating: 0, count: 27)), from: command)
        driver.connectionDidEnd()
        driver.connectionDidStart()

        driveVitalsPass(driver)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(writer.commits.isEmpty)
        XCTAssertTrue(writer.deletes.isEmpty)
    }
}
