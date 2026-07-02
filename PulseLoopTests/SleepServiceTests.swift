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
        TestSupport.insertSleep(nightStart: night(-1), stages: Array(repeating: .light, count: 60), into: context)
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

    func testWakingDayUsesSevenPMBoundary() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        // Small-hours sleep (2 AM) belongs to today's morning.
        let at2am = cal.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at2am), today, "2 AM is last night, stays on today")

        // A daytime nap (1 PM) stays on today — the whole point of moving the boundary off noon.
        let at1pm = cal.date(bySettingHour: 13, minute: 0, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at1pm), today, "afternoon nap stays on today")

        // 6:59 PM is still today; 7 PM rolls to tomorrow's waking morning.
        let at659pm = cal.date(bySettingHour: 18, minute: 59, second: 0, of: today)!
        let at7pm = cal.date(bySettingHour: 19, minute: 0, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at659pm), today, "just before 7 PM stays on today")
        XCTAssertEqual(cal.wakingDay(forSleepStart: at7pm), tomorrow, "from 7 PM, sleep rolls to next morning")
    }

    func testCrossMidnightSleepMerging() throws {
        let context = try TestSupport.makeContext()
        
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        
        // Use the subscriber directly to persist the sleep timeline packets synchronously:
        let subscriber = EventPersistenceSubscriber(context: context)
        
        // 1. A packet starting at 11:30 PM yesterday (June 22)
        let start1 = cal.date(bySettingHour: 23, minute: 30, second: 0, of: yesterday)!
        subscriber.persist(.sleepTimeline(timestamp: start1, stages: Array(repeating: SleepStage.light, count: 15)))
        
        // 2. A packet starting at 12:15 AM today (June 23)
        let start2 = cal.date(bySettingHour: 0, minute: 15, second: 0, of: today)!
        subscriber.persist(.sleepTimeline(timestamp: start2, stages: Array(repeating: SleepStage.deep, count: 15)))
        
        // There should be only ONE unified session for today
        let sessions = SleepRepository.sessions(context: context)
        XCTAssertEqual(sessions.count, 1)
        
        guard let session = sessions.first else {
            XCTFail("No session was created")
            return
        }
        
        // Verify that the session is dated today (waking morning)
        XCTAssertEqual(cal.startOfDay(for: session.date), today)
        
        // Check that blocks from both packets are present
        let blocks = SleepRepository.blocks(sessionId: session.id, context: context)
        XCTAssertTrue(blocks.contains { $0.startAt == start1 })
        XCTAssertTrue(blocks.contains { $0.startAt == start2 })
    }

    func testMigrateSplitSleepSessions() throws {
        let context = try TestSupport.makeContext()
        // The migration is UserDefaults-gated; clear the flag so it runs in this test.
        UserDefaults.standard.removeObject(forKey: "sleepMidnightMerge.v1")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // Create duplicate sessions like the ones in the bug:
        // Session 1: pre-midnight chunk dated yesterday (duration 45m, start 23:15, end 00:00)
        let start = cal.date(bySettingHour: 23, minute: 15, second: 0, of: yesterday)!
        let end1 = cal.date(bySettingHour: 0, minute: 0, second: 0, of: today)!
        let session1 = SleepSession(date: yesterday, startAt: start, endAt: end1, totalMinutes: 45)
        context.insert(session1)
        context.insert(SleepStageBlock(sessionId: session1.id, startAt: start, startMinute: 0, durationMinutes: 45, stage: .light))

        // Session 2: full night dated today (duration 7h 45m, start 23:15, end 07:00)
        let end2 = cal.date(bySettingHour: 7, minute: 0, second: 0, of: today)!
        let session2 = SleepSession(date: today, startAt: start, endAt: end2, totalMinutes: 465)
        context.insert(session2)
        context.insert(SleepStageBlock(sessionId: session2.id, startAt: start, startMinute: 0, durationMinutes: 465, stage: .deep))

        try context.save()

        // Assert they both exist initially
        XCTAssertEqual(try context.fetch(FetchDescriptor<SleepSession>()).count, 2)

        SleepService.migrateSplitSleepSessionsIfNeeded(context: context)

        // Only one session should remain, and it should be the 465-minute one (7h 45m)
        let sessions = try context.fetch(FetchDescriptor<SleepSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.totalMinutes, 465)
        XCTAssertEqual(SleepService.latestSleep(context: context)?.session.totalMinutes, 465)

        // The orphaned block for the deleted session should be cleaned up
        let blocks = try context.fetch(FetchDescriptor<SleepStageBlock>())
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.sessionId, session2.id)
    }

    func testMigrateTieBreakKeepsRicherSession() throws {
        let context = try TestSupport.makeContext()
        UserDefaults.standard.removeObject(forKey: "sleepMidnightMerge.v1")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 1, minute: 0, second: 0, of: today)!

        // Two sessions on the same waking day with EQUAL totalMinutes — the tie-break should keep
        // the one with more stage blocks (the fuller picture), not an arbitrary UUID winner.
        let sparse = SleepSession(date: today, startAt: start, endAt: start, totalMinutes: 400)
        context.insert(sparse)
        context.insert(SleepStageBlock(sessionId: sparse.id, startAt: start, startMinute: 0, durationMinutes: 400, stage: .light))

        let rich = SleepSession(date: today, startAt: start, endAt: start, totalMinutes: 400)
        context.insert(rich)
        for i in 0..<4 {
            let s = cal.date(byAdding: .minute, value: i * 100, to: start)!
            context.insert(SleepStageBlock(sessionId: rich.id, startAt: s, startMinute: i * 100, durationMinutes: 100, stage: .deep))
        }
        try context.save()

        SleepService.migrateSplitSleepSessionsIfNeeded(context: context)

        let sessions = try context.fetch(FetchDescriptor<SleepSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, rich.id, "tie on totalMinutes should keep the session with more blocks")
    }
}
