import XCTest
import SwiftData
import HealthKit
@testable import PulseLoop

/// Editing a ring sleep record's bounds and extending it over time the ring missed (Android #92 and
/// #130, `SleepRecordExtensionTest` + the edit cases of `SleepRecordDeletionTest`).
///
/// The reporter's night: the ring recorded 12:51–5:44 and 6:56–8:07, they were asleep again from
/// about 5:46. Added minutes are asleep but unstaged — in time asleep, out of the breakdown and the
/// score — and the edit path and the import both go through `editedBlocks`, so a re-sync writes
/// back exactly what the edit did.
@MainActor
final class SleepRecordExtensionTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var wakingDay: Date { utc.date(from: DateComponents(year: 2026, month: 10, day: 8))! }
    private func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        wakingDay.addingTimeInterval(TimeInterval((h * 60 + m) * 60 + s))
    }

    // Records start on :23 s, as a real ring's do — so the grid is not the wall-clock minute.
    private var aStart: Date { at(0, 51, 23) }
    private var bStart: Date { at(6, 56, 23) }
    private let aStages: [SleepStage] = Array(repeating: .light, count: 100) + Array(repeating: .deep, count: 80)
        + Array(repeating: .light, count: 70) + Array(repeating: .rem, count: 43)
    private let bStages: [SleepStage] = Array(repeating: .light, count: 30) + Array(repeating: .deep, count: 20)
        + Array(repeating: .light, count: 21)
    private var a: [SleepStageBlock] { SleepRecords.stageBlocks(start: aStart, stages: aStages) }
    private var b: [SleepStageBlock] { SleepRecords.stageBlocks(start: bStart, stages: bStages) }

    private func end(_ blocks: [SleepStageBlock]) -> Date { blocks.map(\.endAt).max()! }
    private func shape(_ blocks: [SleepStageBlock]) -> [String] {
        blocks.sorted { $0.startAt < $1.startAt }.map {
            "\(SleepRecords.key($0.startAt)):\($0.durationMinutes):\($0.stageRaw):\($0.recordStartAt.map(SleepRecords.key) ?? 0)"
        }
    }
    private func edited(_ blocks: [SleepStageBlock], _ origin: Date, _ start: Date, _ end: Date) -> [SleepStageBlock]? {
        SleepRecordExtension.editedBlocks(blocks, gridOrigin: origin, editStart: start, editEnd: end)
    }

    // MARK: - The shared function

    func testExtendingTheStartAddsOneUnstagedBlockBeforeTheRingsOwn() throws {
        let result = try XCTUnwrap(edited(b, bStart, at(5, 46, 23), end(b)))
        let added = result[0]
        XCTAssertEqual(added.stage, .added)
        XCTAssertEqual(added.startAt, at(5, 46, 23))
        XCTAssertEqual(added.durationMinutes, 70)
        XCTAssertEqual(added.recordStartAt, bStart, "added minutes belong to the ring record")
        XCTAssertEqual(shape(Array(result.dropFirst())), shape(b), "the ring's blocks are untouched")
    }

    func testExtendingTheEndAddsOneUnstagedBlockAfterTheRingsOwn() throws {
        let result = try XCTUnwrap(edited(b, bStart, bStart, at(8, 30, 23)))
        XCTAssertEqual(shape(Array(result.dropLast())), shape(b))
        XCTAssertEqual(result.last?.stage, .added)
        XCTAssertEqual(result.last?.startAt, end(b))
        XCTAssertEqual(result.last?.durationMinutes, 23)
    }

    func testOneEditCanShortenOneSideAndExtendTheOther() throws {
        let result = try XCTUnwrap(edited(b, bStart, bStart.addingTimeInterval(600), at(8, 17, 23)))
        XCTAssertEqual(result.first?.startAt, bStart.addingTimeInterval(600))
        XCTAssertEqual(result.first?.stage, .light)
        XCTAssertEqual(result.first?.durationMinutes, 20)
        XCTAssertEqual(result.last?.stage, .added)
        XCTAssertEqual(result.last?.durationMinutes, 10)
        XCTAssertEqual(SleepRecords.measuredAsleepMinutes(result), 61)
        XCTAssertEqual(SleepRecords.asleepMinutes(result), 71)
    }

    func testShorteningAloneAddsNothing() throws {
        let result = try XCTUnwrap(edited(a, aStart, aStart.addingTimeInterval(30 * 60), end(a).addingTimeInterval(-13 * 60)))
        XCTAssertEqual(SleepRecords.addedMinutes(result), 0)
        XCTAssertEqual(SleepRecords.asleepMinutes(result), 293 - 30 - 13)
    }

    func testAWholeMinutePickSnapsInwardsOntoTheRecordsGrid() throws {
        let result = try XCTUnwrap(edited(b, bStart, at(5, 46), at(8, 30)))
        XCTAssertEqual(result.first?.startAt, at(5, 46, 23), "start rounds up into the picked minute")
        XCTAssertEqual(end(result), at(8, 29, 23), "end rounds down, never past the bound")
    }

    func testAnEditKeepingNoneOfTheRingsMinutesIsRefused() {
        XCTAssertNil(edited(b, bStart, at(5, 0, 23), bStart))
        XCTAssertNil(edited(b, bStart, end(b), at(8, 30, 23)))
    }

    func testEditingBackInsideTheRingsBoundsRemovesTheAddedMinutes() throws {
        let extended = try XCTUnwrap(edited(b, bStart, at(5, 46, 23), end(b)))
        let undone = try XCTUnwrap(edited(extended, bStart, bStart, end(b)))
        XCTAssertEqual(shape(undone), shape(b))
    }

    /// What the edit stores and what the next sync builds from the ring's raw stages are the same
    /// blocks, and re-applying the edit to its own output changes nothing.
    func testReImportingReCreatesTheEditsBlocksExactly() throws {
        let editStart = at(5, 46, 23), editEnd = end(b).addingTimeInterval(-5 * 60)
        let afterEdit = try XCTUnwrap(edited(b, bStart, editStart, editEnd))
        let reimported = try XCTUnwrap(edited(SleepRecords.stageBlocks(start: bStart, stages: bStages), bStart, editStart, editEnd))
        XCTAssertEqual(shape(afterEdit), shape(reimported))
        XCTAssertEqual(shape(try XCTUnwrap(edited(afterEdit, bStart, editStart, editEnd))), shape(afterEdit))
    }

    func testAStoredEditGivesWayToANeighbourRecordAtImport() {
        let night = SleepRecordExtension.nightWindow(wakingDay: wakingDay, calendar: utc)
        let bounds = SleepRecordExtension.clampToNeighbours(
            editStart: at(5, 30, 23), editEnd: end(b), measuredStart: bStart, measuredEnd: end(b), others: a, night: night)
        XCTAssertEqual(bounds.start, end(a))
        XCTAssertEqual(bounds.end, end(b))
    }

    // MARK: - Limits and the sheet's picks

    private func limitsForB() -> RecordEditLimits {
        let runs = SleepRecords.runs(a + b)
        return SleepRecordExtension.limits(run: runs[1], previous: runs[0], next: nil, wakingDay: wakingDay, calendar: utc)
    }

    func testExtendingIntoTheGapStopsAtThePreviousRecordsEnd() {
        let limits = limitsForB()
        XCTAssertEqual(limits.earliestStart, end(a))
        XCTAssertEqual(limits.earliestStartLimit, .previousRecord)

        let pick = SleepRecordExtension.clampStartPick(at(5, 30), limits: limits)
        XCTAssertEqual(pick, ClampedEditPick(at: end(a), limit: .previousRecord))

        // The reporter's pick: 5:46, inside the gap, no message.
        XCTAssertEqual(SleepRecordExtension.clampStartPick(at(5, 46), limits: limits), ClampedEditPick(at: at(5, 46, 23), limit: nil))
    }

    func testExtendingOutwardIsCappedAtTwoHoursPastTheRingsBounds() {
        let limits = limitsForB()
        XCTAssertEqual(limits.latestEndLimit, .outwardCap)
        XCTAssertEqual(limits.latestEnd, end(b).addingTimeInterval(120 * 60))
        XCTAssertEqual(SleepRecordExtension.clampEndPick(at(11, 0), limits: limits),
                       ClampedEditPick(at: end(b).addingTimeInterval(120 * 60), limit: .outwardCap))

        let runs = SleepRecords.runs(a + b)
        let first = SleepRecordExtension.limits(run: runs[0], previous: nil, next: runs[1], wakingDay: wakingDay, calendar: utc)
        XCTAssertEqual(first.earliestStart, aStart.addingTimeInterval(-120 * 60))
        XCTAssertEqual(first.earliestStartLimit, .outwardCap)
        XCTAssertEqual(first.latestEnd, bStart)
        XCTAssertEqual(first.latestEndLimit, .nextRecord)
    }

    func testTheCapCountsFromTheRingsBoundsNotAPreviousExtension() throws {
        let extended = try XCTUnwrap(edited(b, bStart, bStart, end(b).addingTimeInterval(60 * 60)))
        let limits = SleepRecordExtension.limits(run: SleepRecords.runs(extended)[0], previous: nil, next: nil,
                                                 wakingDay: wakingDay, calendar: utc)
        XCTAssertEqual(limits.latestEnd, end(b).addingTimeInterval(120 * 60))
    }

    func testAnExtensionNeverCrossesTheNights7PMTurnover() {
        let start = at(-4, 10, 23)   // 20:10:23 the evening before
        let record = SleepRecords.stageBlocks(start: start, stages: Array(repeating: .light, count: 60))
        let limits = SleepRecordExtension.limits(run: SleepRecords.runs(record)[0], previous: nil, next: nil,
                                                 wakingDay: wakingDay, calendar: utc)
        XCTAssertEqual(limits.earliestStartLimit, .nightBoundary)
        XCTAssertEqual(limits.earliestStart, at(-5, 0, 23), "19:00:23, the first grid point inside")
    }

    func testPickingTheMinuteTheButtonShowsIsNotAChange() {
        let limits = limitsForB()
        XCTAssertEqual(SleepRecordExtension.clampStartPick(at(6, 56), limits: limits), ClampedEditPick(at: bStart, limit: nil))
        XCTAssertEqual(SleepRecordExtension.clampEndPick(at(8, 7), limits: limits), ClampedEditPick(at: end(b), limit: nil))
    }

    func testShorteningMustKeepAMinuteTheRingMeasured() {
        let pick = SleepRecordExtension.clampStartPick(at(9, 0), limits: limitsForB())
        XCTAssertEqual(pick, ClampedEditPick(at: end(b).addingTimeInterval(-60), limit: .ringMinutes))
    }

    func testTheLimitIsNamed() {
        let limits = limitsForB()
        let message = SleepRecordExtension.limitMessage(.outwardCap, isStart: false, at: limits.latestEnd, limits: limits)
        XCTAssertTrue(message.hasPrefix("A record can be extended by up to 2 hours"))
        XCTAssertTrue(SleepRecordExtension.limitMessage(.previousRecord, isStart: true, at: end(a), limits: limits)
            .hasPrefix("The previous record ends at"))
    }

    // MARK: - Picked times across midnight

    func testResolveAdjustedTimeHandlesMidnightCrossover() {
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 8))!
        let end = utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7, minute: 5))!
        func resolve(_ target: Date, _ h: Int, _ m: Int) -> DateComponents {
            utc.dateComponents([.day, .hour, .minute], from: SleepRecordExtension.resolveAdjustedTime(
                target: target, recordStart: start, recordEnd: end, hour: h, minute: m, calendar: utc))
        }
        XCTAssertEqual(resolve(start, 23, 30), DateComponents(day: 1, hour: 23, minute: 30))
        XCTAssertEqual(resolve(start, 0, 15), DateComponents(day: 2, hour: 0, minute: 15))
        XCTAssertEqual(resolve(end, 6, 45), DateComponents(day: 2, hour: 6, minute: 45))
    }

    func testResolveAdjustedTimeRollsAPreMidnightPickBackForAPostMidnightStart() {
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 0, minute: 15))!
        let end = utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 6, minute: 30))!
        let resolved = SleepRecordExtension.resolveAdjustedTime(target: start, recordStart: start, recordEnd: end,
                                                                hour: 23, minute: 45, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.day, .hour, .minute], from: resolved), DateComponents(day: 1, hour: 23, minute: 45))
    }

    func testResolveAdjustedTimePutsAMorningPickNextDayForAnEveningStart() {
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 19, minute: 30))!
        let end = utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 8, minute: 0))!
        let resolved = SleepRecordExtension.resolveAdjustedTime(target: start, recordStart: start, recordEnd: end,
                                                                hour: 7, minute: 45, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.day, .hour, .minute], from: resolved), DateComponents(day: 2, hour: 7, minute: 45))
    }

    // MARK: - Asleep, but unstaged and unscored

    private func summary(_ blocks: [SleepStageBlock], totalMinutes: Int, awake: Int? = nil) -> SleepSummary {
        let session = SleepSession(date: wakingDay, startAt: blocks.map(\.startAt).min()!, endAt: end(blocks), totalMinutes: totalMinutes)
        func sum(_ stage: SleepStage) -> Int { blocks.filter { $0.stage == stage }.reduce(0) { $0 + $1.durationMinutes } }
        return SleepSummary(session: session, lightMinutes: sum(.light), deepMinutes: sum(.deep),
                            awakeMinutes: awake ?? SleepRecords.awakeMinutes(blocks), blocks: blocks)
    }

    func testAddedMinutesCountAsAsleepButNotInTheScoreOrTheStageShares() throws {
        let extended = a + (try XCTUnwrap(edited(b, bStart, end(a), end(b))))
        XCTAssertEqual(SleepRecords.asleepMinutes(extended), SleepRecords.asleepMinutes(a + b) + 72)
        XCTAssertEqual(SleepRecords.measuredAsleepMinutes(extended), SleepRecords.asleepMinutes(a + b))
        XCTAssertEqual(SleepRecords.addedMinutes(extended), 72)

        let span = Int(end(extended).timeIntervalSince(aStart) / 60)
        let withAdded = SleepScore.calculate(summary(extended, totalMinutes: span))
        // The same night as the ring measured it, judged over the same awake time.
        let measuredOnly = SleepScore.calculate(summary(extended.filter { $0.stage != .added }, totalMinutes: span - 72,
                                                        awake: SleepRecords.awakeMinutes(extended)))
        XCTAssertEqual(withAdded.deepPct, measuredOnly.deepPct)
        XCTAssertEqual(withAdded.lightPct, measuredOnly.lightPct)
        XCTAssertEqual(withAdded.score, measuredOnly.score)
    }

    func testCoveringTheGapRemovesItFromAwake() throws {
        XCTAssertEqual(SleepRecords.awakeMinutes(a + b), 72)
        let extended = a + (try XCTUnwrap(edited(b, bStart, end(a), end(b))))
        XCTAssertEqual(SleepRecords.runs(extended).count, 2, "still two records")
        XCTAssertEqual(SleepRecords.awakeMinutes(extended), 0)

        let partial = a + (try XCTUnwrap(edited(b, bStart, at(5, 46, 23), end(b))))
        XCTAssertEqual(SleepRecords.awakeMinutes(partial), 2)
    }

    func testClosingAnHourPlusGapMakesTheTwoRecordsOneNight() throws {
        XCTAssertEqual(SleepSegmentation.segment(a + b).count, 2)
        let extended = a + (try XCTUnwrap(edited(b, bStart, end(a), end(b))))
        XCTAssertEqual(SleepSegmentation.segment(extended).count, 1)
    }

    func testAddedMinutesExportToHealthKitAsAsleepUnspecified() {
        XCTAssertEqual(HealthKitTypeMappings.sleepValue(.added), .asleepUnspecified)
    }

    func testTheHypnogramReadoutNamesAddedMinutes() {
        XCTAssertTrue(SleepHypnogramView.readoutText(stage: .added, startMinute: 0, durationMinutes: 10, startTs: nil)
            .hasPrefix("Added by you · "))
    }

    // MARK: - The edit path and re-sync, end to end

    private let local = Calendar.current
    private func localAt(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        local.date(from: DateComponents(year: 2026, month: 10, day: 8))!.addingTimeInterval(TimeInterval((h * 60 + m) * 60 + s))
    }

    private func night(_ context: ModelContext) throws -> SleepSession {
        try XCTUnwrap(SleepRepository.sessions(context: context).first)
    }

    /// The session holding the record that starts at `recordStart`.
    private func session(holding recordStart: Date, _ context: ModelContext) throws -> SleepSession {
        try XCTUnwrap(SleepRepository.sessions(context: context).first { row in
            SleepRepository.blocks(sessionId: row.id, context: context).contains { $0.recordStartAt == recordStart }
        })
    }

    private func dayBlocks(_ context: ModelContext) -> [SleepStageBlock] {
        ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []).sorted { $0.startAt < $1.startAt }
    }

    private func seedReportedNight(_ subscriber: EventPersistenceSubscriber) {
        subscriber.persist(.sleepTimeline(timestamp: localAt(0, 51, 23), stages: aStages))
        subscriber.persist(.sleepTimeline(timestamp: localAt(6, 56, 23), stages: bStages))
        subscriber.flush()
    }

    func testExtendingIntoTheGapIsStoredAndSurvivesReSync() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        // Without a quiet-hours bridge the 72-minute hole splits the night in two sessions.
        XCTAssertEqual(SleepRepository.sessions(context: context).count, 2)
        let second = try session(holding: localAt(6, 56, 23), context)

        XCTAssertTrue(SleepRecordEditor.edit(sessionId: second.id, recordStartAt: localAt(6, 56, 23),
                                             newStart: localAt(5, 46), newEnd: localAt(8, 7, 23), context: context))
        let afterEdit = shape(dayBlocks(context))
        XCTAssertEqual(SleepRecords.addedMinutes(dayBlocks(context)), 70)
        // Closing all but 2 minutes of the hole makes the two records one night again.
        XCTAssertEqual(SleepRepository.sessions(context: context).count, 1)
        XCTAssertEqual(SleepService.summary(for: try night(context), context: context).awakeMinutes, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SleepRecordEdit>()).first?.kind, .edited)

        seedReportedNight(subscriber)
        XCTAssertEqual(shape(dayBlocks(context)), afterEdit, "a re-sync writes back exactly the edit's blocks")
        XCTAssertEqual(SleepRepository.sessions(context: context).count, 1)
    }

    func testTrimmingIsStoredAndTrimmedMinutesDontComeBack() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let first = try session(holding: localAt(0, 51, 23), context)

        XCTAssertTrue(SleepRecordEditor.edit(sessionId: first.id, recordStartAt: localAt(0, 51, 23),
                                             newStart: localAt(1, 21, 23), newEnd: localAt(5, 44, 23), context: context))
        XCTAssertEqual(try session(holding: localAt(0, 51, 23), context).startAt, localAt(1, 21, 23))
        let afterEdit = shape(dayBlocks(context))

        seedReportedNight(subscriber)
        XCTAssertEqual(shape(dayBlocks(context)), afterEdit)
        XCTAssertEqual(try session(holding: localAt(0, 51, 23), context).startAt, localAt(1, 21, 23))
    }

    func testAnUnchangedEditIsRefused() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let second = try session(holding: localAt(6, 56, 23), context)
        XCTAssertFalse(SleepRecordEditor.edit(sessionId: second.id, recordStartAt: localAt(6, 56, 23),
                                              newStart: localAt(6, 56, 23), newEnd: localAt(8, 7, 23), context: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<SleepRecordEdit>()).isEmpty)
    }

    func testDeletingAnEditedRecordClearsTheEdit() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        XCTAssertTrue(SleepRecordEditor.edit(sessionId: try session(holding: localAt(6, 56, 23), context).id,
                                             recordStartAt: localAt(6, 56, 23),
                                             newStart: localAt(5, 46), newEnd: localAt(8, 7, 23), context: context))
        XCTAssertTrue(SleepRecordEditor.delete(sessionId: try night(context).id, recordStartAt: localAt(6, 56, 23), context: context))

        let kinds = try context.fetch(FetchDescriptor<SleepRecordEdit>()).compactMap(\.kind)
        XCTAssertFalse(kinds.contains(.edited))
        XCTAssertTrue(kinds.contains(.recordDeleted))
        seedReportedNight(subscriber)
        XCTAssertEqual(SleepRecords.runs(dayBlocks(context)).count, 1)
        XCTAssertEqual(SleepRecords.addedMinutes(dayBlocks(context)), 0)
    }

    /// The ring's measurement beats an extension whichever arrives first: a record extended back
    /// over time a neighbour later turns out to have measured gives the neighbour its minutes.
    func testANeighbourArrivingLaterTrimsTheAddedMinutes() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.sleepTimeline(timestamp: localAt(6, 56, 23), stages: bStages))
        subscriber.flush()
        let session = try night(context)
        XCTAssertTrue(SleepRecordEditor.edit(sessionId: session.id, recordStartAt: localAt(6, 56, 23),
                                             newStart: localAt(5, 0), newEnd: localAt(8, 7, 23), context: context))
        XCTAssertEqual(SleepRecords.addedMinutes(dayBlocks(context)), 116)

        seedReportedNight(subscriber)
        let blocks = dayBlocks(context)
        XCTAssertEqual(SleepRecords.addedMinutes(blocks), 72, "only the gap the ring missed stays added")
        XCTAssertEqual(SleepRecords.asleepMinutes(blocks), 293 + 72 + 71)
        seedReportedNight(subscriber)
        XCTAssertEqual(shape(dayBlocks(context)), shape(blocks), "and re-syncing again changes nothing")
    }
}
