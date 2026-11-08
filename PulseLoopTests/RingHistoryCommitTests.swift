import XCTest
import SwiftData
@testable import PulseLoop

/// The durable-commit barrier is the only thing that authorizes erasing history from a ring, so every
/// path that can't prove a save must answer `false`.
@MainActor
final class RingHistoryCommitTests: XCTestCase {
    private final class BareWriter: RingCommandWriter {
        nonisolated deinit {}
        func enqueue(_ command: Data) {}
    }

    private func heartRateRows(_ context: ModelContext) throws -> [PulseLoop.Measurement] {
        let kindRaw = MeasurementKind.heartRate.rawValue
        return try context.fetch(FetchDescriptor<PulseLoop.Measurement>(
            predicate: #Predicate<PulseLoop.Measurement> { $0.kindRaw == kindRaw }))
    }

    /// History applied before the barrier is saved (not left to the debounce) before the waiter hears
    /// `true`.
    func testBarrierSavesPendingHistoryThenCommits() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 61,
                                               timestamp: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(context.hasChanges, "precondition: the sample is only batched, not saved")

        var outcome: Bool?
        let id = RingHistoryCommit.register { outcome = $0 }
        subscriber.persist(.historyCommitBarrier(id))

        XCTAssertEqual(outcome, true)
        XCTAssertFalse(context.hasChanges, "the barrier must leave nothing unsaved")
        XCTAssertEqual(try heartRateRows(context).count, 1)
    }

    /// A waiter is answered exactly once — a late duplicate resolve (or the timeout firing after the
    /// subscriber answered) must not re-run the erase.
    func testWaiterIsResolvedExactlyOnce() {
        var outcomes: [Bool] = []
        let id = RingHistoryCommit.register { outcomes.append($0) }
        RingHistoryCommit.resolve(id, committed: true)
        RingHistoryCommit.resolve(id, committed: false)
        XCTAssertEqual(outcomes, [true])
    }

    /// No persistence subscriber ever reaches the barrier ⇒ the timeout answers `false`.
    func testUnansweredBarrierTimesOutAsNotCommitted() {
        let done = expectation(description: "timeout")
        _ = RingHistoryCommit.register(timeoutNanoseconds: 10_000_000) { committed in
            XCTAssertFalse(committed)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// A writer that can't route a barrier to persistence (tests, previews) fails closed.
    func testDefaultWriterNeverAuthorizesAnErase() {
        var outcome: Bool?
        BareWriter().commitDeliveredHistory { outcome = $0 }
        XCTAssertEqual(outcome, false)
    }
}
