import XCTest
import SwiftData
@testable import PulseLoop

/// Calendar windows for the vital detail periods (issue #102): midnight→midnight days that stay
/// correct across DST, weeks ending today, calendar months, and chart fetches bounded to the window.
@MainActor
final class VitalPeriodsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// The reporter's case: at 10:04 on Oct 6, Day is Oct 6 00:00 → Oct 7 00:00, not a rolling 24 h.
    func testDayAt1004IsTheCalendarDay() {
        let now = date(2026, 10, 6, 10, 4)
        let anchor = VitalPeriods.latestAnchor(.day, now: now, calendar: calendar)
        let window = VitalPeriods.window(.day, anchor: anchor, calendar: calendar)
        XCTAssertEqual(window.start, date(2026, 10, 6))
        XCTAssertEqual(window.end, date(2026, 10, 7))
        XCTAssertTrue(window.contains(date(2026, 10, 6, 21, 30)), "the evening belongs to the 6th")
        XCTAssertFalse(window.contains(date(2026, 10, 5, 22, 0)))
    }

    func testDSTDaysAreMidnightToMidnight() {
        // Spring forward (23 h) and fall back (25 h) in New York.
        let spring = VitalPeriods.window(.day, anchor: date(2026, 3, 8), calendar: calendar)
        XCTAssertEqual(spring.duration, 23 * 3600)
        XCTAssertEqual(spring.end, date(2026, 3, 9))

        let fall = VitalPeriods.window(.day, anchor: date(2026, 11, 1), calendar: calendar)
        XCTAssertEqual(fall.duration, 25 * 3600)
        XCTAssertEqual(fall.end, date(2026, 11, 2))

        // Stepping back across the change still lands on midnight.
        let back = VitalPeriods.step(.day, anchor: date(2026, 3, 9), by: -1, calendar: calendar)
        XCTAssertEqual(back, date(2026, 3, 8))
        XCTAssertEqual(calendar.component(.hour, from: VitalPeriods.step(.day, anchor: date(2026, 3, 8), by: 1, calendar: calendar)), 0)
    }

    func testWeekEndsTodayAndStepsBySevenDays() {
        let now = date(2026, 11, 9, 19, 0)
        let anchor = VitalPeriods.latestAnchor(.week, now: now, calendar: calendar)
        XCTAssertEqual(anchor, date(2026, 11, 3))
        XCTAssertEqual(VitalPeriods.window(.week, anchor: anchor, calendar: calendar).end, date(2026, 11, 10))
        // A week spanning the fall-back change is 7 calendar days (169 h).
        let previous = VitalPeriods.step(.week, anchor: anchor, by: -1, calendar: calendar)
        XCTAssertEqual(previous, date(2026, 10, 27))
        XCTAssertEqual(VitalPeriods.window(.week, anchor: previous, calendar: calendar).duration, 7 * 86_400 + 3600)
    }

    func testMonthIsTheCalendarMonth() {
        let now = date(2026, 3, 31, 12)
        let anchor = VitalPeriods.latestAnchor(.month, now: now, calendar: calendar)
        XCTAssertEqual(anchor, date(2026, 3, 1))
        XCTAssertEqual(VitalPeriods.window(.month, anchor: anchor, calendar: calendar).end, date(2026, 4, 1))
        XCTAssertEqual(VitalPeriods.step(.month, anchor: anchor, by: -1, calendar: calendar), date(2026, 2, 1))
        XCTAssertEqual(VitalPeriods.window(.month, anchor: date(2026, 2, 1), calendar: calendar).end, date(2026, 3, 1))
    }

    func testLabels() {
        let now = date(2026, 11, 9, 19, 0)
        XCTAssertEqual(PeriodNavLabels.day(date(2026, 11, 9), now: now, calendar: calendar).primary, "Today")
        XCTAssertEqual(PeriodNavLabels.day(date(2026, 11, 8), now: now, calendar: calendar).primary, "Yesterday")
        XCTAssertEqual(PeriodNavLabels.week(date(2026, 11, 3), now: now, calendar: calendar).primary, "Last 7 days")
        XCTAssertEqual(PeriodNavLabels.month(date(2026, 11, 1), now: now, calendar: calendar).primary, "This month")
        XCTAssertNotEqual(PeriodNavLabels.month(date(2026, 10, 1), now: now, calendar: calendar).primary, "This month")
    }

    /// The chart fetch is bounded to `[start, end)` — no rolling 24 h, no demo full-history widening.
    func testMeasurementWindowIsBoundedToThePeriod() throws {
        let context = try TestSupport.makeContext()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        TestSupport.insertMeasurement(kind: .heartRate, value: 60, timestamp: day.addingTimeInterval(-60), source: .mock, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: day.addingTimeInterval(3600), source: .mock, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 80, timestamp: next, source: .mock, into: context)
        let samples = MetricsService.measurementWindow(kind: .heartRate, start: day, end: next, range: .twentyFourHours, context: context)
        XCTAssertEqual(samples.map(\.value), [70])
    }
    /// The calendar-window fetch applies the estimated-SpO₂ rule (`EstimatedSpO2`) on the raw rows:
    /// hidden by default, kept and flagged when the user shows estimates.
    func testSpO2WindowHidesOrFlagsEstimatedHourlyRows() throws {
        let context = try TestSupport.makeContext()
        let now = Date()
        let heartRates = [48, 57, 67, 75, 82, 92, 105, 70]
        func spo2(_ hr: Int) -> Double { hr <= 48 ? 88 : hr <= 57 ? 94 : hr <= 92 ? 98 : 96 }
        for i in 0..<30 {
            let t = now.addingTimeInterval(-Double(30 - i) * 3600 + 34)
            let hr = heartRates[i % heartRates.count]
            TestSupport.insertMeasurement(kind: .spo2, value: spo2(hr), timestamp: t, source: .history, into: context)
            TestSupport.insertMeasurement(kind: .respiratoryRate, value: Double(hr) / 5, timestamp: t, source: .history, into: context)
            TestSupport.insertMeasurement(kind: .heartRate, value: Double(hr), timestamp: t.addingTimeInterval(-5), source: .history, into: context)
        }
        let spot = now.addingTimeInterval(-600)
        TestSupport.insertMeasurement(kind: .spo2, value: 99, timestamp: spot, source: .live, into: context)
        let start = now.addingTimeInterval(-86_400), end = now.addingTimeInterval(1)

        let saved = MetricPrefsStore.shared.settings
        defer { MetricPrefsStore.shared.settings = saved }
        var prefs = saved
        prefs.resolution = .full
        prefs.hideEstimatedSpO2 = true
        MetricPrefsStore.shared.settings = prefs
        XCTAssertEqual(MetricsService.measurementWindow(kind: .spo2, start: start, end: end, range: .twentyFourHours,
                                                        context: context).map(\.timestamp), [spot])
        XCTAssertFalse(MetricsService.spo2Series(start: start, end: end, range: .twentyFourHours, context: context).isEstimated)

        prefs.hideEstimatedSpO2 = false
        MetricPrefsStore.shared.settings = prefs
        let shown = MetricsService.spo2Series(start: start, end: end, range: .twentyFourHours, context: context)
        XCTAssertTrue(shown.isEstimated)
        XCTAssertEqual(shown.samples.count, 25, "24 hourly estimates in the window plus the spot reading")
    }
}
