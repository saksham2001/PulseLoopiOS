import XCTest
@testable import PulseLoop

@MainActor
final class RWfitHistorySyncTests: XCTestCase {
    private final class Writer: RingCommandWriter {
        nonisolated deinit {}
        var payloads: [[UInt8]] = []
        var onWrite: (([UInt8]) -> Void)?
        func enqueue(_ command: Data) {}
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            let payload = Array(command.dropFirst(6))
            payloads.append(payload)
            completion(.success(()))
            onWrite?(payload)
        }
    }

    private func setup(_ writer: Writer) -> (RWfitHistorySync, RWfitCommandGate) {
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec(), responseTimeout: 0.02)
        gate.framing = .jieli
        let sync = RWfitHistorySync(gate: gate, progressSink: { _ in })
        sync.framing = .jieli
        sync.deviceIdentifier = UUID().uuidString
        sync.persist = { _ in }
        return (sync, gate)
    }

    private func respond(_ payload: [UInt8], gate: RWfitCommandGate) {
        gate.noteJieliFrame(flag: 0x11, triple: .init(cmd: payload[0], key: payload[1], keyFlag: payload[2]), payload: payload)
    }

    func testMultiplePagesAreSavedBeforeConsumption() async {
        let writer = Writer()
        let (sync, gate) = setup(writer)
        var reads = 0
        var order: [String] = []
        sync.persist = { events in
            XCTAssertEqual(events.count, 2)
            order.append("save")
        }
        writer.onWrite = { payload in
            if payload[2] == 0x10 {
                reads += 1
                order.append("get")
                self.respond(reads < 3 ? [5, 3, 0x10, 0, 0, 0, UInt8(reads), 70, 0] : [5, 3, 0x10], gate: gate)
            } else {
                order.append("delete")
                self.respond(payload, gate: gate)
            }
        }
        let outcome = await sync.run(types: [.heartRate])
        XCTAssertEqual(outcome, .success(records: 2))
        XCTAssertEqual(order, ["get", "get", "get", "save", "delete"])
        gate.cancel()
    }

    func testStorageFailurePreservesRingHistory() async {
        let writer = Writer()
        let (sync, gate) = setup(writer)
        var reads = 0
        sync.persist = { _ in throw RWfitSessionError.persistence }
        writer.onWrite = { payload in
            reads += 1
            self.respond(reads == 1 ? [5, 3, 0x10, 0, 0, 0, 1, 70, 0] : [5, 3, 0x10], gate: gate)
        }
        let outcome = await sync.run(types: [.heartRate])
        guard case .failed = outcome else { return XCTFail("Expected failed persistence, got \(outcome)") }
        XCTAssertFalse(writer.payloads.contains { $0[2] == 0x30 })
        gate.cancel()
    }

    func testMalformedHistoryIsNotConsumed() async {
        let writer = Writer()
        let (sync, gate) = setup(writer)
        var reads = 0
        writer.onWrite = { _ in
            reads += 1
            self.respond(reads == 1 ? [5, 3, 0x10, 99] : [5, 3, 0x10], gate: gate)
        }
        let outcome = await sync.run(types: [.heartRate])
        guard case .failed = outcome else { return XCTFail("Malformed record must fail") }
        XCTAssertFalse(writer.payloads.contains { $0[2] == 0x30 })
        gate.cancel()
    }

    func testSilenceFailsButExplicitEmptyResponseSucceeds() async {
        let silentWriter = Writer()
        let (silentSync, silentGate) = setup(silentWriter)
        let failure = await silentSync.run(types: [.heartRate])
        guard case .failed = failure else { return XCTFail("Silence is not successful empty history") }
        XCTAssertEqual(silentWriter.payloads.count, 3)
        XCTAssertFalse(silentSync.isRunning)
        silentGate.cancel()

        let writer = Writer()
        let (sync, gate) = setup(writer)
        writer.onWrite = { self.respond($0, gate: gate) }
        let success = await sync.run(types: [.heartRate])
        XCTAssertEqual(success, .success(records: 0))
        gate.cancel()
    }

    func testPauseStopsAtPageBoundaryAndResumes() async throws {
        let writer = Writer()
        let (sync, gate) = setup(writer)
        var reads = 0
        writer.onWrite = { payload in
            if payload[2] == 0x10 {
                reads += 1
                if reads == 1 { sync.isPaused = true }
                self.respond(reads == 1 ? [5, 3, 0x10, 0, 0, 0, 1, 70, 0] : payload, gate: gate)
            } else { self.respond(payload, gate: gate) }
        }
        let task = Task { await sync.run(types: [.heartRate]) }
        for _ in 0..<100 where !sync.isPaused { try await Task.sleep(nanoseconds: 5_000_000) }
        try await sync.waitUntilPaused()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reads, 1)
        sync.isPaused = false
        let outcome = await task.value
        XCTAssertEqual(outcome, .success(records: 1))
        gate.cancel()
    }

    func testSleepPageIsDurableBeforeDeleteAndRetainedOnSaveFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        RWfitHistoryPersistence.journalDirectoryOverride = directory
        defer {
            RWfitHistoryPersistence.journalDirectoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let writer = Writer()
        let (sync, gate) = setup(writer)
        let identifier = try XCTUnwrap(sync.deviceIdentifier)
        let page: [UInt8] = [5, 5, 0x10, 0, 0, 0, 1, 2, 0, 1]
        var reads = 0
        var checkedJournal = false
        sync.persist = { _ in throw RWfitSessionError.persistence }
        writer.onWrite = { payload in
            if payload[2] == 0x10 {
                reads += 1
                self.respond(reads == 1 ? page : payload, gate: gate)
            } else {
                XCTAssertEqual(try? RWfitHistoryPersistence.sleepPayload(deviceID: identifier), page)
                checkedJournal = true
                self.respond(payload, gate: gate)
            }
        }
        let outcome = await sync.run(types: [.sleep])
        guard case .failed = outcome else { return XCTFail("Incomplete sleep or failed save must fail") }
        XCTAssertTrue(checkedJournal)
        XCTAssertEqual(try RWfitHistoryPersistence.sleepPayload(deviceID: identifier), page)
        gate.cancel()
    }

    func testCancellationWhilePausedDoesNotIssueHistoryRequest() async {
        let writer = Writer()
        let (sync, gate) = setup(writer)
        sync.isPaused = true
        let task = Task { await sync.run(types: [.heartRate]) }
        await Task.yield()
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(writer.payloads.isEmpty)
        gate.cancel()
    }
    func testDeleteFailureAfterDurableSaveReportsPartialImport() async {
        let writer = Writer()
        let (sync, gate) = setup(writer)
        var reads = 0
        var saved = 0
        sync.persist = { saved += $0.count }
        writer.onWrite = { payload in
            guard payload[2] == 0x10 else { return }
            reads += 1
            self.respond(reads == 1 ? [5, 3, 0x10, 0, 0, 0, 1, 70, 0] : payload, gate: gate)
        }
        let outcome = await sync.run(types: [.heartRate])
        XCTAssertEqual(saved, 1)
        guard case let .partial(records, _) = outcome else { return XCTFail("Saved records must remain visible in partial outcome") }
        XCTAssertEqual(records, 1)
        XCTAssertEqual(writer.payloads.filter { $0[2] == 0x30 }.count, 1)
        gate.cancel()
    }

    func testIncompleteSleepDoesNotPreventLaterHeartRateImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        RWfitHistoryPersistence.journalDirectoryOverride = directory
        defer {
            RWfitHistoryPersistence.journalDirectoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let writer = Writer()
        let (sync, gate) = setup(writer)
        let identifier = try XCTUnwrap(sync.deviceIdentifier)
        let sleepPage: [UInt8] = [5, 5, 0x10, 0, 0, 0, 1, 0x11, 0, 0]
        var sleepReads = 0
        var heartReads = 0
        var saved = 0
        sync.persist = { saved += $0.count }
        writer.onWrite = { payload in
            var response = payload
            if payload[2] == 0x10 && payload[1] == 5 {
                sleepReads += 1
                if sleepReads == 1 { response = sleepPage }
            } else if payload[2] == 0x10 && payload[1] == 3 {
                heartReads += 1
                if heartReads == 1 { response = [5, 3, 0x10, 0, 0, 0, 1, 70, 0] }
            }
            self.respond(response, gate: gate)
        }
        let outcome = await sync.run(types: [.sleep, .heartRate])
        guard case let .partial(records, reason) = outcome else { return XCTFail("Expected partial import, got \(outcome)") }
        XCTAssertEqual(records, 1)
        XCTAssertEqual(saved, 1)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(heartReads, 2)
        XCTAssertEqual(try RWfitHistoryPersistence.sleepPayload(deviceID: identifier), sleepPage,
                       "Unfinished sleep session must remain recoverable")
        gate.cancel()
    }

}
