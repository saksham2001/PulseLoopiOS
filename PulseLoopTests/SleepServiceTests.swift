import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class SleepServiceTests: XCTestCase {
    private func night(_ dayOffset: Int) -> Date {
        let base = TestSupport.day(dayOffset)
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: base) ?? base
    }

    /// A fixed "now" at noon today — past the 4 AM day-reference flip — so `.day`-range
    /// assertions don't depend on the wall-clock time the suite happens to run at.
    private func noonToday() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: TestSupport.day(0)) ?? Date()
    }

    func testStaleSleepHiddenFromLatest() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-3), stages: Array(repeating: .light, count: 60), into: context)
        XCTAssertNil(SleepService.latestSleep(context: context), "a 3-day-old session is stale")
    }

    func testRecentSleepShown() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(0), stages: Array(repeating: .deep, count: 90), into: context)
        let latest = SleepService.latestSleep(context: context)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.deepMinutes, 90)
    }

    func testStaleSleepHiddenFromToday() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-4), stages: Array(repeating: .light, count: 30), into: context)
        XCTAssertNil(MetricsService.buildTodaySummary(context: context).sleep)
    }

    func testSummaryStageMinutes() throws {
        let context = try TestSupport.makeContext()
        let stages = Array(repeating: SleepStage.light, count: 40) + Array(repeating: .deep, count: 20) + Array(repeating: .awake, count: 5)
        let session = TestSupport.insertSleep(nightStart: night(0), stages: stages, into: context)
        let summary = SleepService.summary(for: session, context: context)
        XCTAssertEqual(summary.lightMinutes, 40)
        XCTAssertEqual(summary.deepMinutes, 20)
        XCTAssertEqual(summary.awakeMinutes, 5)
    }

    func testExpectedNightsPerRange() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(0), stages: Array(repeating: .light, count: 60), into: context)
        XCTAssertEqual(SleepService.sleepRange(.day, context: context).expectedNights, 1)
        XCTAssertEqual(SleepService.sleepRange(.week, context: context).expectedNights, 7)
        XCTAssertEqual(SleepService.sleepRange(.month, context: context).expectedNights, 30)
        XCTAssertEqual(SleepService.sleepRange(.year, context: context).expectedNights, 365)
    }

    func testWeekRangeWindowsSessions() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(0), stages: Array(repeating: .light, count: 60), into: context)
        TestSupport.insertSleep(nightStart: night(-2), stages: Array(repeating: .deep, count: 60), into: context)
        TestSupport.insertSleep(nightStart: night(-20), stages: Array(repeating: .light, count: 60), into: context)
        let week = SleepService.sleepRange(.week, context: context)
        XCTAssertEqual(week.sessions.count, 2, "only sessions within the 7-night window")
    }

    func testBlocksOnlyForDayRange() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(0), stages: Array(repeating: .light, count: 60), into: context)
        // Pin `now` to noon today so the Day window resolves to today regardless of when the suite runs
        // (before 4 AM the reference night is yesterday, which would exclude tonight's session).
        XCTAssertFalse(SleepService.sleepRange(.day, context: context, now: noonToday()).sessions.first?.blocks.isEmpty ?? true)
        XCTAssertTrue(SleepService.sleepRange(.week, context: context).sessions.first?.blocks.isEmpty ?? false)
    }

    /// The Day view used to show the last recorded sleep even when "last night"
    /// had no data — so a 3-day-old session masqueraded as last night. Now the
    /// day anchor is "today's reference night", so an old session is excluded.
    func testDayRangeShowsNoDataWhenLastNightMissing() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-3), stages: Array(repeating: .light, count: 60), into: context)
        XCTAssertTrue(SleepService.sleepRange(.day, context: context).sessions.isEmpty)
        // But the week view still surfaces it.
        XCTAssertFalse(SleepService.sleepRange(.week, context: context).sessions.isEmpty)
    }

    func testDayReferenceNightFlipsAt4AM() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let at3am = cal.date(bySettingHour: 3, minute: 0, second: 0, of: today)!
        let at4am = cal.date(bySettingHour: 4, minute: 0, second: 0, of: today)!
        XCTAssertEqual(SleepService.dayReferenceNight(now: at3am), yesterday, "before 4 AM, still last night")
        XCTAssertEqual(SleepService.dayReferenceNight(now: at4am), today, "from 4 AM, flip to today")
    }
}
