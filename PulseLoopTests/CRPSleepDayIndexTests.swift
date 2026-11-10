import XCTest
import SwiftData
@testable import PulseLoop

/// Which day `CRPDecoder` files a CRP sleep-history reply (`group 2 / cmd 14`) under, for each shape a
/// waking day's sleep can take around midnight, and on either side of the vendor's 20:00 rollover.
/// Ported from the Android app's `CRPSleepDayIndexTest.kt` and `CRPSleepRolloverGuardTest.kt`.
///
/// Prompted by a Colmi R11 whose first night, waking Sun 2026-09-27, was stored correctly by a morning
/// sync and then again, exactly one day early, by an evening one. The vendor app dates a reply from the
/// moment it syncs: `t3/n.onHistorySleepChange` builds the entity from `new Date()`, `f4/e.e` moves that
/// to tomorrow when `f4/e.h` sees the hour at 20 or later, and `j4/h.b` subtracts the day index. From
/// 20:00 on, day 0 is the night about to begin and last night is day 1. A sleep starting at or after
/// 20:00 therefore belongs to the next waking day.
///
/// Bouts are one minute long; a 60-minute awake run is the shortest gap `CRPDecoder` splits bouts on.
@MainActor
final class CRPSleepDayIndexTests: XCTestCase {
    private let fdd3 = CRPUUIDs.cmdNotifyCBUUID
    private let awake: UInt8 = 0
    private let light: UInt8 = 1

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private var sundayMorning: Date { instant("2026-09-27T09:00:00Z") }
    private var sundayJustBefore8pm: Date { instant("2026-09-27T19:59:00Z") }
    private var sundayEvening: Date { instant("2026-09-27T21:00:00Z") }
    private var sundayLate: Date { instant("2026-09-27T23:30:00Z") }
    private var mondayMorning: Date { instant("2026-09-28T09:00:00Z") }

    /// One vendor `[state, hour, minute]` record: `state` begins at hh:mm.
    private func at(_ state: UInt8, _ hour: UInt8, _ minute: UInt8) -> [UInt8] { [state, hour, minute] }

    private func sleepFrame(_ dayIndex: UInt8, _ records: [UInt8]...) -> Data {
        CRPProtocol.frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryHistorySleep,
                          payload: [dayIndex] + records.flatMap { $0 })
    }

    /// Decoded bout starts, checking none is dated after the sync that reported it.
    private func decodeAt(_ now: Date, _ frame: Data, calendar: Calendar? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> [(start: Date, stages: [SleepStage])] {
        let bouts = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: calendar ?? utc).compactMap { event -> (Date, [SleepStage])? in
            guard case let .sleepTimeline(start, stages) = event else { return nil }
            return (start, stages)
        }
        for bout in bouts {
            XCTAssertLessThanOrEqual(bout.0, now, "bout dated \(bout.0) starts after the \(now) sync that reported it", file: file, line: line)
        }
        return bouts
    }

    private func assertBouts(_ expected: [String], _ bouts: [(start: Date, stages: [SleepStage])],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bouts.map(\.start), expected.map(instant), file: file, line: line)
        XCTAssertTrue(bouts.allSatisfy { $0.stages == [.light] }, file: file, line: line)
    }

    /// One bout either side of midnight: light 23:00–23:01, then light 00:01–00:02.
    private var acrossMidnight: [[UInt8]] { [at(light, 23, 0), at(awake, 23, 1), at(light, 0, 1), at(awake, 0, 2)] }

    private func sleepFrame(_ dayIndex: UInt8, records: [[UInt8]]) -> Data {
        CRPProtocol.frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryHistorySleep,
                          payload: [dayIndex] + records.flatMap { $0 })
    }

    // MARK: - Day index

    func test1_OneBoutBeforeMidnightIsTheEveningBeforeTheWakingDay() {
        assertBouts(["2026-09-26T23:00:00Z"], decodeAt(sundayMorning, sleepFrame(0, at(light, 23, 0), at(awake, 23, 1))))
    }

    func test2_OneBoutAfterMidnightIsOnTheWakingDay() {
        assertBouts(["2026-09-27T01:00:00Z"], decodeAt(sundayMorning, sleepFrame(0, at(light, 1, 0), at(awake, 1, 1))))
    }

    func test3_TwoBoutsBeforeMidnightAreBothTheEveningBeforeTheWakingDay() {
        let bouts = decodeAt(sundayMorning, sleepFrame(0, at(light, 22, 0), at(awake, 22, 1), at(light, 23, 1), at(awake, 23, 2)))
        assertBouts(["2026-09-26T22:00:00Z", "2026-09-26T23:01:00Z"], bouts)
    }

    func test4_TwoBoutsAfterMidnightAreBothOnTheWakingDay() {
        let bouts = decodeAt(sundayMorning, sleepFrame(0, at(light, 1, 0), at(awake, 1, 1), at(light, 2, 1), at(awake, 2, 2)))
        assertBouts(["2026-09-27T01:00:00Z", "2026-09-27T02:01:00Z"], bouts)
    }

    func test5_ABoutBeforeMidnightAndOneAfterStraddleTheMidnightBetweenThem() {
        assertBouts(["2026-09-26T23:00:00Z", "2026-09-27T00:01:00Z"], decodeAt(sundayMorning, sleepFrame(0, records: acrossMidnight)))
    }

    /// The reported bug: after 20:00 the ring reports last night as day 1, and it must still be filed
    /// under the day it was slept, not the day before.
    func test6_LastNightSyncedAfter8pmAsDay1IsTheSameNightTheMorningSyncStoredAsDay0() {
        let morning = decodeAt(sundayMorning, sleepFrame(0, records: acrossMidnight))
        let evening = decodeAt(sundayEvening, sleepFrame(1, records: acrossMidnight))
        assertBouts(["2026-09-26T23:00:00Z", "2026-09-27T00:01:00Z"], morning)
        assertBouts(["2026-09-26T23:00:00Z", "2026-09-27T00:01:00Z"], evening)
    }

    /// The rollover is at 20:00 exactly: a minute earlier, day 0 is still last night.
    func test7_ASyncJustBefore8pmStillReadsDay0AsLastNight() {
        assertBouts(["2026-09-26T23:00:00Z", "2026-09-27T00:01:00Z"], decodeAt(sundayJustBefore8pm, sleepFrame(0, records: acrossMidnight)))
    }

    /// In an older day's reply, an evening record is still the evening before that day. Monday morning,
    /// day 1 is Sunday's sleep day, which runs from Sat 20:00 to Sun 20:00.
    func test8_AnEveningBoutAt2000InAnOlderDaysReplyIsTheEveningBeforeThatDay() {
        assertBouts(["2026-09-26T20:00:00Z"], decodeAt(mondayMorning, sleepFrame(1, at(light, 20, 0), at(awake, 20, 1))))
    }

    /// One minute earlier, the record is still inside the same sleep day, so it stays on that day.
    func test9_ABoutStartingAt1959StaysOnItsOwnDay() {
        assertBouts(["2026-09-27T19:59:00Z"], decodeAt(mondayMorning, sleepFrame(1, at(light, 19, 59), at(awake, 20, 0))))
    }

    /// After 8 PM, day 0 is the night just beginning.
    func test10_After8pmDay0IsTonightsSleep() {
        assertBouts(["2026-09-27T23:00:00Z"], decodeAt(sundayLate, sleepFrame(0, at(light, 23, 0), at(awake, 23, 1))))
    }

    /// Four ordinary syncs, stored the way the app stores them (`EventPersistenceSubscriber`), leave each
    /// night holding only its own sleep. Sunday's record is 02:00–02:01; Monday's starts earlier and ends
    /// later, 01:59–02:02. The ring re-sends each night, by day index, on every sync. Before the 20:00
    /// rule the Monday-evening sync filed Monday's record on Sunday and Sunday's on Saturday.
    func test11_FourSyncsLeaveEachNightHoldingOnlyItsOwnSleep() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let cal = Calendar.current   // persistence keys waking days on the device calendar
        func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        let sundayRecord = [at(light, 2, 0), at(awake, 2, 1)]
        let mondayRecord = [at(light, 1, 59), at(awake, 2, 2)]
        func sync(_ now: Date, _ replies: Data...) {
            for reply in replies {
                for bout in decodeAt(now, reply, calendar: cal) {
                    subscriber.persist(.sleepTimeline(timestamp: bout.start, stages: bout.stages))
                }
            }
        }

        sync(local(27, 9), sleepFrame(0, records: sundayRecord))
        sync(local(28, 9), sleepFrame(0, records: mondayRecord), sleepFrame(1, records: sundayRecord))
        sync(local(28, 21), sleepFrame(1, records: mondayRecord), sleepFrame(2, records: sundayRecord))
        sync(local(29, 9), sleepFrame(1, records: mondayRecord), sleepFrame(2, records: sundayRecord))
        try context.save()

        func night(_ day: Int) -> [String] {
            let dayStart = cal.startOfDay(for: local(day, 12))
            let ids = Set(SleepRepository.sessions(context: context).filter { cal.isDate($0.date, inSameDayAs: dayStart) }.map(\.id))
            let blocks = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []).filter { ids.contains($0.sessionId) }
            return blocks.sorted { $0.startAt < $1.startAt }.map {
                "\(cal.component(.hour, from: $0.startAt)):\(cal.component(.minute, from: $0.startAt)) \($0.durationMinutes)m \($0.stageRaw)"
            }
        }
        XCTAssertEqual(night(26), [], "Sat, before the ring was worn")
        XCTAssertEqual(night(27), ["2:0 1m \(SleepStage.light.rawValue)"])
        XCTAssertEqual(night(28), ["1:59 3m \(SleepStage.light.rawValue)"])
    }

    // MARK: - 20:00 sync guard

    private func pacific(_ hour: Int, _ minute: Int) -> (Date, Calendar) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return (cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: hour, minute: minute, second: 30))!, cal)
    }

    func testTheMinutesAround2000AreGuarded() {
        for (h, m) in [(19, 59), (20, 0), (20, 4), (19, 56)] {
            let (now, cal) = pacific(h, m)
            XCTAssertTrue(CRPDecoder.nearSleepDayRollover(now, calendar: cal), "\(h):\(m)")
        }
    }

    func testTheRestOfTheDayIsNotGuarded() {
        for (h, m) in [(19, 55), (20, 5), (7, 30), (0, 0)] {
            let (now, cal) = pacific(h, m)
            XCTAssertFalse(CRPDecoder.nearSleepDayRollover(now, calendar: cal), "\(h):\(m)")
        }
    }
}
