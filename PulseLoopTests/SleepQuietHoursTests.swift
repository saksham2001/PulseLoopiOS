import XCTest
import SwiftData
@testable import PulseLoop

/// The opt-in sleep quiet-hours schedule (Android #79/#80 and the clock half of #105,
/// `QuietHoursPrefsTest` + `SleepGapsTest`): the window arithmetic the import trims by, the bridge
/// that keeps a long waking inside the window from splitting the night, and both end to end.
@MainActor
final class SleepQuietHoursTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SleepQuietHours.storageKey)
        super.tearDown()
    }

    private func store(_ quiet: SleepQuietHours) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(quiet), forKey: SleepQuietHours.storageKey)
    }

    // MARK: - Window arithmetic

    /// The default 22:00 → 07:00 wraps midnight. It *keeps* a 23:08 sofa start, which is why the
    /// settings copy asks for the real bedtime.
    func testTheDefaultWindowWrapsMidnight() {
        XCTAssertTrue(SleepQuietHours.covers(start: 22 * 60, end: 7 * 60, minuteOfDay: 23 * 60 + 8))
        XCTAssertTrue(SleepQuietHours.covers(start: 22 * 60, end: 7 * 60, minuteOfDay: 3 * 60))
        XCTAssertFalse(SleepQuietHours.covers(start: 22 * 60, end: 7 * 60, minuteOfDay: 14 * 60))
    }

    /// Inclusive at the start, exclusive at the end — a 07:00 record belongs to the day.
    func testBoundariesAreStartInclusiveAndEndExclusive() {
        XCTAssertTrue(SleepQuietHours.covers(start: 22 * 60, end: 7 * 60, minuteOfDay: 22 * 60))
        XCTAssertFalse(SleepQuietHours.covers(start: 22 * 60, end: 7 * 60, minuteOfDay: 7 * 60))
        XCTAssertTrue(SleepQuietHours.covers(start: 9 * 60, end: 18 * 60, minuteOfDay: 9 * 60))
        XCTAssertFalse(SleepQuietHours.covers(start: 9 * 60, end: 18 * 60, minuteOfDay: 18 * 60))
    }

    /// A plain daytime window (no wrap) still works — shift workers sleep in the day.
    func testANonWrappingWindowBehaves() {
        XCTAssertTrue(SleepQuietHours.covers(start: 9 * 60, end: 18 * 60, minuteOfDay: 12 * 60))
        XCTAssertFalse(SleepQuietHours.covers(start: 9 * 60, end: 18 * 60, minuteOfDay: 21 * 60))
        XCTAssertFalse(SleepQuietHours.covers(start: 9 * 60, end: 18 * 60, minuteOfDay: 6 * 60))
    }

    /// start == end means the whole day: the schedule is on but filters nothing.
    func testAnEqualWindowCoversTheWholeDay() {
        for minute in [0, 7 * 60, 12 * 60, 23 * 60 + 59] {
            XCTAssertTrue(SleepQuietHours.covers(start: 8 * 60, end: 8 * 60, minuteOfDay: minute))
        }
    }

    func testMinuteOfDayUsesTheLocalWallClock() {
        let date = utc.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 23, minute: 8))!
        XCTAssertEqual(SleepQuietHours.minuteOfDay(date, calendar: utc), 23 * 60 + 8)
    }

    // MARK: - Minute-level trim

    private func sep17(_ h: Int, _ m: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: h, minute: m))!
    }
    private func kept(_ start: Date, _ count: Int, _ from: Int, _ until: Int) -> Range<Int>? {
        SleepQuietHours.keptMinutes(start: start, count: count, startMinutes: from, endMinutes: until, calendar: utc)
    }

    /// The reported night as one unsplit record, 23:08 on the sofa straight through to 07:08: the
    /// sofa minutes before a 00:05 start and the minutes after 07:00 go, and the real night stays.
    func testASofaStartRunningIntoTheNightIsTrimmedNotDropped() {
        XCTAssertEqual(kept(sep17(23, 8), 8 * 60, 5, 7 * 60), 57..<(57 + 6 * 60 + 55))
    }

    func testARecordWhollyOutsideTheWindowIsDropped() {
        XCTAssertNil(kept(sep17(14, 0), 45, 22 * 60, 7 * 60))
    }

    func testARecordWhollyInsideTheWindowIsKeptWhole() {
        XCTAssertEqual(kept(sep17(23, 30), 300, 22 * 60, 7 * 60), 0..<300)
    }

    func testAnEqualWindowKeepsEveryMinute() {
        XCTAssertEqual(kept(sep17(15, 0), 90, 8 * 60, 8 * 60), 0..<90)
    }

    /// A record touching two windows keeps the longer stretch, never both across the hole.
    func testARecordTouchingTwoWindowsKeepsTheLongerStretch() {
        XCTAssertEqual(kept(sep17(12, 30), 24 * 60 - 20, 12 * 60, 13 * 60), 0..<30)
    }

    func testAnEmptyRecordKeepsNothing() {
        XCTAssertNil(kept(sep17(23, 0), 0, 22 * 60, 7 * 60))
    }

    func testTheScheduleOffKeepsTheWholeRecord() {
        let off = SleepQuietHours(enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertEqual(off.keptMinutes(start: sep17(14, 0), count: 45, calendar: utc), 0..<45)
    }

    // MARK: - The bridge (#105, clock window)

    private func oct11(_ h: Int, _ m: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: h, minute: m))!
    }
    private func bridge(_ enabled: Bool, _ from: Int, _ until: Int) -> SleepGapBridge {
        SleepGapBridge.forSchedule(SleepQuietHours(enabled: enabled, startMinutes: from, endMinutes: until), calendar: utc)
    }
    /// The reporter's night: records 00:51–05:44 and 06:56–08:07.
    private var gap: (Date, Date) { (oct11(5, 44), oct11(6, 56)) }

    func testTheClockWindowDecides() {
        XCTAssertTrue(bridge(true, 22 * 60, 7 * 60).bridges(gap.0, gap.1))
        XCTAssertFalse(bridge(true, 22 * 60, 6 * 60).bridges(gap.0, gap.1), "the gap runs past 06:00")
    }

    func testNothingIsBridgedWithTheScheduleOff() {
        XCTAssertFalse(bridge(false, 22 * 60, 7 * 60).bridges(gap.0, gap.1))
    }

    func testANapAfterTheNightIsNotBridged() {
        XCTAssertFalse(bridge(true, 22 * 60, 7 * 60).bridges(oct11(6, 30), oct11(14, 0)))
    }

    /// A window whose start equals its end means "trimming off", not "asleep all day".
    func testAnAllDayWindowBridgesNothing() {
        XCTAssertFalse(bridge(true, 22 * 60, 22 * 60).bridges(oct11(15, 0), oct11(23, 0)))
        XCTAssertFalse(bridge(true, 0, 24 * 60).bridges(oct11(15, 0), oct11(23, 0)))
    }

    /// The bridge and the import gate agree: a gap the bridge keeps inside the night is one the
    /// import would keep whole as a record.
    func testTheBridgeAndTheImportGateAgree() {
        let minutes = Int(gap.1.timeIntervalSince(gap.0) / 60)
        for (enabled, until) in [(false, 7 * 60), (true, 7 * 60), (true, 6 * 60)] {
            let quiet = SleepQuietHours(enabled: enabled, startMinutes: 22 * 60, endMinutes: until)
            let bridged = SleepGapBridge.forSchedule(quiet, calendar: utc).bridges(gap.0, gap.1)
            let keptWhole = enabled && quiet.keptMinutes(start: gap.0, count: minutes, calendar: utc) == 0..<minutes
            XCTAssertEqual(bridged, keptWhole, "enabled=\(enabled) until=\(until)")
        }
    }

    private func blocks(_ start: Date, _ minutes: Int) -> [SleepStageBlock] {
        SleepRecords.stageBlocks(start: start, stages: Array(repeating: .light, count: minutes))
    }

    func testSegmentationKeepsABridgedNightWholeAndCountsTheGapAwake() {
        let night = blocks(oct11(0, 51), 293) + blocks(oct11(6, 56), 71)
        XCTAssertEqual(SleepSegmentation.segment(night).count, 2)
        let whole = SleepSegmentation.segment(night, bridge: bridge(true, 22 * 60, 7 * 60))
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(SleepRecords.awakeMinutes(whole[0]), 72)
    }

    /// A delete or edit long after the night was written keeps the gaps it already held, and judges
    /// a new gap it opens afresh.
    func testARestateKeepsTheGapsTheNightAlreadyHeldAndJudgesNewOnes() {
        let before = blocks(oct11(0, 51), 293) + blocks(oct11(6, 56), 71) + blocks(oct11(8, 30), 30)
        let kept = SleepGapBridge.none.keepingGaps(of: [before])
        XCTAssertTrue(kept.bridges(oct11(5, 44), oct11(6, 56)), "already open")
        XCTAssertFalse(kept.bridges(oct11(5, 44), oct11(8, 30)), "opened by deleting the middle")
        XCTAssertFalse(kept.bridges(oct11(9, 0), oct11(13, 0)), "past the night: a nap's gap is never kept")
    }

    // MARK: - End to end through the import

    private let local = Calendar.current
    private func localAt(_ h: Int, _ m: Int) -> Date {
        local.date(from: DateComponents(year: 2026, month: 10, day: 8))!.addingTimeInterval(TimeInterval((h * 60 + m) * 60))
    }
    private func light(_ n: Int) -> [SleepStage] { Array(repeating: .light, count: n) }

    func testTheImportTrimsASofaStartToTheWindowAndKeepsTheRecordsIdentity() throws {
        try store(SleepQuietHours(enabled: true, startMinutes: 5, endMinutes: 7 * 60))
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.sleepTimeline(timestamp: localAt(-1, 8), stages: light(8 * 60)))   // 23:08 → 07:08

        let night = try XCTUnwrap(SleepRepository.sessions(context: context).first)
        XCTAssertEqual(night.startAt, localAt(0, 5))
        XCTAssertEqual(night.endAt, localAt(7, 0))
        let runs = SleepRecords.runs(SleepRepository.blocks(sessionId: night.id, context: context))
        XCTAssertEqual(runs.map(\.recordStartAt), [localAt(-1, 8)], "the record is still known by its declared start")
    }

    func testTheImportDropsARecordWhollyOutsideTheWindow() throws {
        try store(SleepQuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60))
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.sleepTimeline(timestamp: localAt(14, 0), stages: light(45)))
        XCTAssertTrue(SleepRepository.sessions(context: context).isEmpty)
    }

    private func seedThreeRecordNight(_ subscriber: EventPersistenceSubscriber) {
        subscriber.persist(.sleepTimeline(timestamp: localAt(0, 51), stages: light(293)))   // → 05:44
        subscriber.persist(.sleepTimeline(timestamp: localAt(6, 56), stages: light(71)))    // → 08:07
        subscriber.persist(.sleepTimeline(timestamp: localAt(8, 30), stages: light(30)))    // → 09:00
        subscriber.flush()
    }

    /// The 72-minute waking inside the window stays one night and reads as awake between records.
    func testALongWakingInsideTheWindowDoesNotSplitTheNight() throws {
        try store(SleepQuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 10 * 60))
        let context = try TestSupport.makeContext()
        seedThreeRecordNight(EventPersistenceSubscriber(context: context))

        let sessions = SleepRepository.sessions(context: context)
        XCTAssertEqual(sessions.count, 1)
        let summary = SleepService.summary(for: sessions[0], context: context)
        XCTAssertEqual(summary.awakeMinutes, 72 + 23)
        let runs = SleepRecords.runs(summary.blocks)
        XCTAssertEqual(SleepRecords.betweenRecordAwakeMinutes(runs[0], runs[1]), 72)
    }

    /// Turning the schedule off later doesn't split a night it already holds when a record is
    /// deleted — but a new hour-plus hole the delete opens is judged by today's settings.
    func testADeleteKeepsAGapTheNightAlreadyHeldEvenWithTheScheduleOff() throws {
        try store(SleepQuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 10 * 60))
        let context = try TestSupport.makeContext()
        seedThreeRecordNight(EventPersistenceSubscriber(context: context))
        let night = try XCTUnwrap(SleepRepository.sessions(context: context).first)
        try store(SleepQuietHours(enabled: false, startMinutes: 22 * 60, endMinutes: 10 * 60))

        XCTAssertTrue(SleepRecordEditor.delete(sessionId: night.id, recordStartAt: localAt(8, 30), context: context))
        XCTAssertEqual(SleepRepository.sessions(context: context).count, 1, "the 72-minute gap was already held")

        XCTAssertTrue(SleepRecordEditor.delete(sessionId: night.id, recordStartAt: localAt(6, 56), context: context))
        XCTAssertEqual(SleepRepository.sessions(context: context).count, 1, "only the first record is left")
    }

    func testADeleteThatOpensANewHourPlusHoleSplitsWithTheScheduleOff() throws {
        try store(SleepQuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 10 * 60))
        let context = try TestSupport.makeContext()
        seedThreeRecordNight(EventPersistenceSubscriber(context: context))
        let night = try XCTUnwrap(SleepRepository.sessions(context: context).first)
        try store(SleepQuietHours(enabled: false, startMinutes: 22 * 60, endMinutes: 10 * 60))

        SleepRecordEditor.delete(sessionId: night.id, recordStartAt: localAt(6, 56), context: context)
        XCTAssertEqual(SleepRepository.sessions(context: context).count, 2)
    }
}
