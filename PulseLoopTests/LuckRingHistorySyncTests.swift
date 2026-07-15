import XCTest
@testable import PulseLoop

/// The history pager: it walks the catalog one type at a time, advancing when a type's data settles or
/// timing it out when nothing comes, refuses a re-entrant `start`, and signals completion. The K6 streams
/// carry no terminal marker, so this time-settled sequencing is the whole of the transfer contract.
@MainActor
final class LuckRingHistorySyncTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        /// The dataType of each request packet written (head byte [5]); REQUEST frames only.
        var requestedTypes: [UInt8] { sent.map { [UInt8]($0)[5] } }
    }

    private final class Spy {
        var stages: [String] = []
        var didFinish: Bool { stages.contains("done") }
    }

    private func makeSync(writer: FakeWriter, spy: Spy, settle: TimeInterval, stall: TimeInterval) -> LuckRingHistorySync {
        LuckRingHistorySync(writer: writer, settleSeconds: settle, stallSeconds: stall, progressSink: { event in
            if case let .syncProgress(stage) = event { spy.stages.append(stage) }
        })
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testSequentialAdvanceOnDataSettle() async {
        let writer = FakeWriter()
        let spy = Spy()
        let sync = makeSync(writer: writer, spy: spy, settle: 0.05, stall: 5)

        sync.start(types: [5, 6])
        XCTAssertEqual(writer.requestedTypes, [5], "the first type is requested immediately")

        sync.noteReceived(dataType: 5)
        await sleep(0.2)
        XCTAssertEqual(writer.requestedTypes, [5, 6], "the pass advanced once type 5's data settled")

        sync.noteReceived(dataType: 6)
        await sleep(0.2)
        XCTAssertFalse(sync.isRunning, "the queue drained")
        XCTAssertTrue(spy.didFinish, "completion is signalled")
    }

    func testUnsupportedTypeIsSkippedOnStall() async {
        let writer = FakeWriter()
        let spy = Spy()
        let sync = makeSync(writer: writer, spy: spy, settle: 5, stall: 0.05)

        sync.start(types: [42])   // no data will ever arrive
        XCTAssertEqual(writer.requestedTypes, [42])

        await sleep(0.2)
        XCTAssertFalse(sync.isRunning, "a type that never answers is skipped on the stall timeout")
        XCTAssertTrue(spy.didFinish)
    }

    func testReEntrantStartIsIgnoredWhileRunning() async {
        let writer = FakeWriter()
        let spy = Spy()
        let sync = makeSync(writer: writer, spy: spy, settle: 5, stall: 5)

        sync.start(types: [5])
        sync.start(types: [6])   // must not interrupt the in-flight pass
        XCTAssertEqual(writer.requestedTypes, [5])
        sync.cancel()            // stop the in-flight timer…
        await sleep(0.05)        // …and let the cancelled Task retire before the instance is torn down
    }

    func testCancelStopsThePass() async {
        let writer = FakeWriter()
        let spy = Spy()
        let sync = makeSync(writer: writer, spy: spy, settle: 0.05, stall: 0.05)

        sync.start(types: [5, 6, 8])
        sync.cancel()
        await sleep(0.2)
        XCTAssertFalse(sync.isRunning)
        XCTAssertEqual(writer.requestedTypes, [5], "cancel halts before any further type is requested")
    }

    func testCatalogAndVitalsSubsetsAreWhatWeExpect() {
        XCTAssertEqual(LuckRingHistorySync.catalog, [5, 6, 8, 40, 41, 42, 47, 53])
        XCTAssertEqual(LuckRingHistorySync.vitalsTypes, [8, 40])
    }
}
