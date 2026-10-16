import XCTest
import SwiftData
@testable import PulseLoop

/// Covers what `fetchLimit` does to a windowed read: which rows it keeps, and which end of the
/// range it drops when the window holds more than the cap.
@MainActor
final class RepositoryFetchLimitTests: XCTestCase {
    /// A capped window has to drop the *oldest* rows, not the newest.
    ///
    /// Sorting forward and then truncating meant a chart over a busy window rendered the beginning
    /// of the range and silently omitted the recent readings — the opposite of what a drainage
    /// chart is for.
    func testBatterySamplesKeepTheNewestRowsWhenTruncated() throws {
        let context = try TestSupport.makeContext()
        let end = Date()
        let start = end.addingTimeInterval(-3600 * 24)

        // 10 samples, one per minute, oldest first. Percent doubles as an ordering marker.
        for index in 0..<10 {
            context.insert(BatterySample(percent: index, timestamp: end.addingTimeInterval(Double(index - 10) * 60)))
        }
        try context.save()

        let capped = MetricsRepository.batterySamples(start: start, end: end, limit: 4, context: context)

        XCTAssertEqual(capped.count, 4)
        XCTAssertEqual(capped.map(\.percent), [6, 7, 8, 9], "Expected the four most recent samples")
        XCTAssertEqual(capped.map(\.timestamp), capped.map(\.timestamp).sorted(),
                       "Documented contract is oldest-first for a left-to-right axis")
    }

    /// The uncapped path must be unaffected by the sort flip.
    func testBatterySamplesStillReturnEverythingOldestFirstUnderTheLimit() throws {
        let context = try TestSupport.makeContext()
        let end = Date()
        let start = end.addingTimeInterval(-3600 * 24)

        for index in 0..<5 {
            context.insert(BatterySample(percent: index * 10, timestamp: end.addingTimeInterval(Double(index - 5) * 60)))
        }
        try context.save()

        let samples = MetricsRepository.batterySamples(start: start, end: end, context: context)
        XCTAssertEqual(samples.map(\.percent), [0, 10, 20, 30, 40])
    }

    /// `latestSession` reads one row via `fetchLimit`; it must still be the newest one.
    func testLatestSleepSessionIsTheMostRecentByStart() throws {
        let context = try TestSupport.makeContext()
        let now = Date()

        let older = SleepSession(date: now.addingTimeInterval(-86_400 * 2),
                                 startAt: now.addingTimeInterval(-86_400 * 2),
                                 endAt: now.addingTimeInterval(-86_400 * 2 + 3600 * 7),
                                 totalMinutes: 420)
        let newest = SleepSession(date: now,
                                  startAt: now.addingTimeInterval(-3600 * 8),
                                  endAt: now.addingTimeInterval(-3600),
                                  totalMinutes: 420)
        let middle = SleepSession(date: now.addingTimeInterval(-86_400),
                                  startAt: now.addingTimeInterval(-86_400),
                                  endAt: now.addingTimeInterval(-86_400 + 3600 * 7),
                                  totalMinutes: 420)
        // Inserted out of order so the result depends on the sort, not on insertion order.
        [older, newest, middle].forEach { context.insert($0) }
        try context.save()

        XCTAssertEqual(SleepRepository.latestSession(context: context)?.id, newest.id)
    }

    func testLatestSleepSessionIsNilOnAnEmptyStore() throws {
        let context = try TestSupport.makeContext()
        XCTAssertNil(SleepRepository.latestSession(context: context))
    }
}
