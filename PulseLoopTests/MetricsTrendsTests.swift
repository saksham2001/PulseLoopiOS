import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class MetricsTrendsTests: XCTestCase {
    func testSevenDayTrendIsCalendarAlignedAndContiguous() throws {
        let context = try TestSupport.makeContext()
        // Seed a couple of real days; the rest of the Monday-anchored week fills as zero.
        TestSupport.insertActivity(date: Date(), steps: 9000, into: context)
        TestSupport.insertActivity(date: TestSupport.day(-1), steps: 7000, into: context)

        let trends = MetricsService.buildTodaySummary(context: context).trends
        XCTAssertEqual(trends.steps7d.count, 7)

        var calendar = Calendar.current
        calendar.firstWeekday = 2
        XCTAssertEqual(calendar.component(.weekday, from: trends.steps7d[0].date), 2, "week should start Monday")

        let dates = trends.steps7d.map { calendar.startOfDay(for: $0.date) }
        for index in 1..<dates.count {
            let gap = calendar.dateComponents([.day], from: dates[index - 1], to: dates[index]).day
            XCTAssertEqual(gap, 1, "days must be contiguous")
        }
    }

    func testTwelveMonthGroupingSumsByMonth() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        // Anchor to fixed days so this stays deterministic on month boundaries (e.g. the 1st):
        // two days pinned to the middle of one month, one pinned to the middle of the month
        // before it. That's always exactly two distinct months, both inside the 12-month window.
        let midThisMonth = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: Date()),
            month: calendar.component(.month, from: Date()),
            day: 15, hour: 12
        )) ?? Date()
        let midPrevMonth = calendar.date(byAdding: .month, value: -1, to: midThisMonth) ?? midThisMonth

        TestSupport.insertActivity(date: midThisMonth, steps: 5000, source: "live", into: context)
        TestSupport.insertActivity(date: calendar.date(byAdding: .day, value: -1, to: midThisMonth) ?? midThisMonth,
                                   steps: 3000, source: "live", into: context)
        TestSupport.insertActivity(date: midPrevMonth, steps: 4000, source: "live", into: context)

        let samples = MetricsService.metricRange(metric: .steps, range: .twelveMonths, context: context)
        XCTAssertEqual(samples.count, 2, "two distinct months")
        XCTAssertEqual(samples.map(\.value).reduce(0, +), 12000)
    }
}
