import XCTest
import SwiftData
@testable import PulseLoop

/// Timing windows hung off the user's own schedule. Most of the risk here is date arithmetic around
/// midnight, so that is where the tests concentrate.
@MainActor
final class CircadianWindowsTests: XCTestCase {

    private let calendar = Calendar.current

    private func today(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: Date()))
            ?? Date()
    }

    private func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// An evening bedtime (23:00) and a morning wake (07:00).
    private var eveningSleeper: CircadianBaseline {
        CircadianBaseline(bedtimeMinutesFromMidnight: -60, wakeMinutesFromMidnight: 420, nights: 14)
    }

    /// A past-midnight bedtime (00:30) and a later wake (08:30).
    private var lateSleeper: CircadianBaseline {
        CircadianBaseline(bedtimeMinutesFromMidnight: 30, wakeMinutesFromMidnight: 510, nights: 14)
    }

    // MARK: - Offsets

    func testWindowsHangOffBedtime() throws {
        let windows = try XCTUnwrap(CircadianWindows.build(from: eveningSleeper, now: today(12)))

        XCTAssertEqual(clock(windows.usualBedtime), "23:00")
        XCTAssertEqual(clock(windows.caffeineCutoff), "15:00", "8 hours before bed")
        XCTAssertEqual(clock(windows.lastMealBy), "20:00", "3 hours before bed")
        XCTAssertEqual(clock(windows.windDownFrom), "22:00", "1 hour before bed")
        XCTAssertEqual(clock(windows.morningLightBy), "09:00", "2 hours after wake")
    }

    /// **The midnight case.** Someone who sleeps at 00:30 must get a 16:30 caffeine cutoff *today*,
    /// not 16:30 yesterday — counting back eight hours from a bedtime placed on the wrong day is the
    /// obvious way to get this wrong.
    func testAPastMidnightBedtimeCountsBackIntoToday() throws {
        let now = today(12)
        let windows = try XCTUnwrap(CircadianWindows.build(from: lateSleeper, now: now))

        XCTAssertEqual(clock(windows.usualBedtime), "00:30")
        XCTAssertEqual(clock(windows.caffeineCutoff), "16:30")
        XCTAssertTrue(windows.caffeineCutoff > now, "the cutoff is still ahead of a midday 'now'")
        XCTAssertTrue(windows.usualBedtime > now, "tonight's bedtime, not last night's")
    }

    /// Every window must sit before the bedtime it was derived from, whichever side of midnight the
    /// bedtime falls on.
    func testEveryEveningWindowPrecedesBedtime() throws {
        for baseline in [eveningSleeper, lateSleeper] {
            let windows = try XCTUnwrap(CircadianWindows.build(from: baseline, now: today(12)))
            XCTAssertLessThan(windows.caffeineCutoff, windows.usualBedtime)
            XCTAssertLessThan(windows.lastMealBy, windows.usualBedtime)
            XCTAssertLessThan(windows.windDownFrom, windows.usualBedtime)
            XCTAssertLessThan(windows.morningLightBy, windows.usualBedtime)
        }
    }

    /// A night-shift schedule — asleep at 09:00, up at 17:00 — must still produce a coherent day.
    /// The windows are relative to *their* sleep, which is the whole reason this isn't built on
    /// sunrise.
    func testANightShiftScheduleStillWorks() throws {
        let nightShift = CircadianBaseline(
            bedtimeMinutesFromMidnight: 540, wakeMinutesFromMidnight: 1020 - 24 * 60, nights: 10
        )
        let windows = try XCTUnwrap(CircadianWindows.build(from: nightShift, now: today(12)))
        XCTAssertEqual(clock(windows.usualBedtime), "09:00")
        XCTAssertEqual(clock(windows.caffeineCutoff), "01:00")
        XCTAssertLessThan(windows.caffeineCutoff, windows.usualBedtime)
    }

    // MARK: - Establishment

    func testWindowsNeedAnEstablishedBaseline() {
        let thin = CircadianBaseline(bedtimeMinutesFromMidnight: -60, wakeMinutesFromMidnight: 420, nights: 6)
        XCTAssertFalse(thin.isEstablished)
        XCTAssertNil(CircadianWindows.build(from: thin))
    }

    func testBaselineNeedsMatchingBedtimesAndWakes() {
        XCTAssertNil(CircadianBaseline.compute(bedtimes: [Date()], wakeTimes: []))
        XCTAssertNil(CircadianBaseline.compute(bedtimes: [], wakeTimes: []))
    }

    func testBaselineMediansWrapAroundMidnight() throws {
        let before = today(23, 40)
        let after = today(0, 20)
        let baseline = try XCTUnwrap(
            CircadianBaseline.compute(bedtimes: [before, after], wakeTimes: [today(7), today(7)])
        )
        XCTAssertEqual(baseline.bedtimeMinutesFromMidnight, 0, accuracy: 0.001,
                       "23:40 and 00:20 average to midnight, not noon")
        XCTAssertEqual(baseline.wakeMinutesFromMidnight, 420, accuracy: 0.001)
    }

    // MARK: - Learning the schedule from the store

    func testScheduleIsLearnedFromRecentNights() throws {
        let context = try TestSupport.makeContext()
        // Ten nights, 23:00 to 07:00.
        for offset in 1...10 {
            let day = TestSupport.day(-offset)
            let bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: bedtime, stages: Array(repeating: .light, count: 480), into: context)
        }
        let baseline = try XCTUnwrap(SleepService.circadianBaseline(context: context))

        XCTAssertTrue(baseline.isEstablished)
        XCTAssertEqual(baseline.bedtimeMinutesFromMidnight, -60, accuracy: 1)
        XCTAssertEqual(baseline.wakeMinutesFromMidnight, 420, accuracy: 1)
    }

    /// Naps are not a schedule. A 20-minute afternoon sleep's start and end must not be read as a
    /// bedtime and a wake.
    func testNapsAreExcludedFromTheSchedule() throws {
        let context = try TestSupport.makeContext()
        for offset in 1...10 {
            let day = TestSupport.day(-offset)
            let bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: bedtime, stages: Array(repeating: .light, count: 480), into: context)
            // A short nap the same waking day, well past the segmentation gap.
            let nap = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: nap, stages: Array(repeating: .light, count: 20), into: context)
        }
        let baseline = try XCTUnwrap(SleepService.circadianBaseline(context: context))
        XCTAssertEqual(baseline.bedtimeMinutesFromMidnight, -60, accuracy: 1,
                       "the 14:00 nap doesn't drag the bedtime median")
    }

    func testNoScheduleWithoutAWeekOfNights() throws {
        let context = try TestSupport.makeContext()
        for offset in 1...4 {
            let day = TestSupport.day(-offset)
            let bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: bedtime, stages: Array(repeating: .light, count: 480), into: context)
        }
        XCTAssertEqual(SleepService.circadianBaseline(context: context)?.isEstablished, false)
    }

    // MARK: - Copy

    /// Four times with no explanation would be instructions rather than guidance.
    func testEveryWindowCarriesAReason() {
        for kind in CircadianWindows.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.reason.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
        }
    }

    func testEntriesCoverEveryWindow() throws {
        let windows = try XCTUnwrap(CircadianWindows.build(from: eveningSleeper, now: today(12)))
        XCTAssertEqual(Set(windows.entries().map(\.kind)), Set(CircadianWindows.Kind.allCases))
    }
}
