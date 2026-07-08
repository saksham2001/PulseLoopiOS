import XCTest
import SwiftData
@testable import PulseLoop

/// Covers the battery-drainage history: the throttled persistence in `EventPersistenceSubscriber`
/// and the windowed read in `MetricsRepository.batterySamples`.
@MainActor
final class BatteryHistoryTests: XCTestCase {
    /// Wide window so the fetch returns every sample written during a test.
    private func allSamples(_ context: ModelContext) -> [BatterySample] {
        let end = Date().addingTimeInterval(60)
        let start = end.addingTimeInterval(-3600 * 24 * 365)
        return MetricsRepository.batterySamples(start: start, end: end, context: context)
    }

    func testFirstReadingIsRecorded() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        subscriber.persist(.batteryLevel(percent: 82))

        let samples = allSamples(context)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.percent, 82)
    }

    func testUnchangedReadingIsDedupedWithinFloor() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        // Same percent three times in quick succession — only the first should persist, since the
        // value hasn't changed and the 30-min floor hasn't elapsed.
        subscriber.persist(.batteryLevel(percent: 82))
        subscriber.persist(.batteryLevel(percent: 82))
        subscriber.persist(.batteryLevel(percent: 82))

        XCTAssertEqual(allSamples(context).count, 1)
    }

    func testChangedReadingIsRecorded() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        // Each change is a new data point even inside the 30-min floor — drainage is the whole point.
        subscriber.persist(.batteryLevel(percent: 82))
        subscriber.persist(.batteryLevel(percent: 81))
        subscriber.persist(.batteryLevel(percent: 80))

        let samples = allSamples(context)
        XCTAssertEqual(samples.count, 3)
        // Fetch is oldest-first, so the series reads as a downward drain.
        XCTAssertEqual(samples.map(\.percent), [82, 81, 80])
    }

    func testOutOfRangeReadingIsIgnored() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        // Garbage / fallback-default values must never enter the history.
        subscriber.persist(.batteryLevel(percent: -1))
        subscriber.persist(.batteryLevel(percent: 200))

        XCTAssertTrue(allSamples(context).isEmpty)
    }

    func testWindowFetchExcludesOutOfRangeSamples() throws {
        let context = try TestSupport.makeContext()
        let now = Date()

        // One sample inside the window, one well outside it.
        context.insert(BatterySample(percent: 50, timestamp: now.addingTimeInterval(-3600)))      // 1h ago
        context.insert(BatterySample(percent: 90, timestamp: now.addingTimeInterval(-3600 * 48))) // 48h ago
        try context.save()

        let start = now.addingTimeInterval(-3600 * 24)   // last 24h
        let rows = MetricsRepository.batterySamples(start: start, end: now, context: context)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.percent, 50)
    }
}
