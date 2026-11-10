import XCTest
import SwiftData
@testable import PulseLoop

/// Deleting one ring sleep record from a night (Android #71/#78/#80, `SleepRecordDeletionTest`):
/// how records are recovered from stored blocks, the tombstone the import consults so a delete
/// survives re-sync, and the restate of what remains.
@MainActor
final class SleepRecordDeletionTests: XCTestCase {
    private let calendar = Calendar.current

    /// Local wall-clock time on the morning of Oct 8 2026 (negative hours reach the evening before).
    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        return day.addingTimeInterval(TimeInterval((hour * 60 + minute) * 60 + second))
    }

    private func persist(_ subscriber: EventPersistenceSubscriber, _ start: Date, _ stages: [SleepStage]) {
        subscriber.persist(.sleepTimeline(timestamp: start, stages: stages))
    }

    private func light(_ n: Int) -> [SleepStage] { Array(repeating: .light, count: n) }

    private func sessions(_ context: ModelContext) -> [SleepSession] {
        SleepRepository.sessions(context: context).sorted { $0.startAt < $1.startAt }
    }

    private func edits(_ context: ModelContext) -> [SleepRecordEdit] {
        (try? context.fetch(FetchDescriptor<SleepRecordEdit>())) ?? []
    }

    /// The reported night, three records: 23:08–00:05 (the sofa), 00:25–03:19, 03:26–07:08.
    private func seedReportedNight(_ subscriber: EventPersistenceSubscriber) {
        persist(subscriber, at(-1, 8), light(57))
        persist(subscriber, at(0, 25), light(174))
        persist(subscriber, at(3, 26), light(222))
    }

    // MARK: - Records recovered from stored blocks

    func testImportStampsEveryBlockWithItsRecordAndTheCardSplitsOnIt() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)

        let night = try XCTUnwrap(sessions(context).first)
        XCTAssertEqual(sessions(context).count, 1, "gaps under an hour keep the night one session")
        let blocks = SleepRepository.blocks(sessionId: night.id, context: context)
        XCTAssertTrue(blocks.allSatisfy { $0.recordStartAt != nil })
        let runs = SleepRecords.runs(blocks)
        XCTAssertEqual(runs.map(\.recordStartAt), [at(-1, 8), at(0, 25), at(3, 26)])
        XCTAssertEqual(runs.map(\.asleepMinutes), [57, 174, 222])
    }

    /// A record reopened one minute after the last closed is still its own record: the stamp, not
    /// the gap, decides — and the back-to-back packets of a Jring night are each a record too.
    func testRunsFollowTheStampNotTheGap() {
        let a = SleepRecords.stageBlocks(start: at(2, 0), stages: light(15))
        let b = SleepRecords.stageBlocks(start: at(2, 15), stages: light(15))
        XCTAssertEqual(SleepRecords.runs(a + b).count, 2)
        XCTAssertEqual(SleepRecords.betweenRecordAwakeMinutes(SleepRecords.runs(a + b)[0], SleepRecords.runs(a + b)[1]), 0)
    }

    /// Nights stored before records were stamped fall back to splitting on a 2-minute gap.
    func testUnstampedNightsSplitOnTheGap() {
        let a = SleepRecords.stageBlocks(start: at(0, 0), stages: light(60))
        let b = SleepRecords.stageBlocks(start: at(1, 1), stages: light(30))
        let c = SleepRecords.stageBlocks(start: at(1, 40), stages: light(30))
        for block in a + b + c { block.recordStartAt = nil }
        let runs = SleepRecords.runs(a + b + c)
        XCTAssertEqual(runs.count, 2, "the one-minute seam joins, the 9-minute gap splits")
        XCTAssertEqual(runs[1].recordStartAt, at(1, 40), "an unstamped run is keyed by its first minute")
    }

    /// The Awake figure counts the waking between records, the same minutes the card labels.
    func testAwakeIncludesTheGapsBetweenRecords() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let night = try XCTUnwrap(sessions(context).first)
        let summary = SleepService.summary(for: night, context: context)
        XCTAssertEqual(summary.awakeMinutes, 20 + 7)
    }

    // MARK: - Delete and re-sync

    func testDeletingTheSofaRecordRestatesTheNightOnTheSameRow() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let night = try XCTUnwrap(sessions(context).first)

        XCTAssertTrue(SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(-1, 8), context: context))

        let after = sessions(context)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].id, night.id, "the Day view stays on the same row")
        XCTAssertEqual(after[0].startAt, at(0, 25))
        XCTAssertEqual(after[0].endAt, at(7, 8))
        XCTAssertEqual(SleepRecords.runs(SleepRepository.blocks(sessionId: night.id, context: context)).count, 2)
    }

    /// The contract the feature hangs on: the next sync re-sends the record, and it stays gone —
    /// while its neighbours, re-sent in the same sync, are untouched.
    func testADeletedRecordDoesNotComeBackOnReSync() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let night = try XCTUnwrap(sessions(context).first)
        SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(-1, 8), context: context)

        seedReportedNight(subscriber)
        subscriber.flush()

        let after = sessions(context)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].startAt, at(0, 25), "the deleted sofa record must not be re-imported")
        let runs = SleepRecords.runs(SleepRepository.blocks(sessionId: after[0].id, context: context))
        XCTAssertEqual(runs.map(\.recordStartAt), [at(0, 25), at(3, 26)])
    }

    /// A night stored before stamping: the record's start is a guess, but every block re-sends with
    /// the same start, so the block tombstones hold the delete.
    func testAnUnstampedRecordStaysDeletedThroughItsBlocks() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        persist(subscriber, at(0, 0), light(30) + Array(repeating: .deep, count: 30))
        persist(subscriber, at(1, 10), light(60))
        subscriber.flush()
        for block in (try context.fetch(FetchDescriptor<SleepStageBlock>())) { block.recordStartAt = nil }
        try context.save()
        let night = try XCTUnwrap(sessions(context).first)

        XCTAssertTrue(SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(0, 0), context: context))
        XCTAssertEqual(edits(context).filter { $0.kind == .blockDeleted }.count, 2)

        persist(subscriber, at(0, 0), light(30) + Array(repeating: .deep, count: 30))
        subscriber.flush()
        XCTAssertEqual(sessions(context).first?.startAt, at(1, 10))
    }

    /// Deleting the middle record leaves a 3 h 21 m hole: the restate splits there exactly as the
    /// next sync would, so the hole never reads as hours awake.
    func testDeletingAMiddleRecordPastTheSessionGapSplitsTheNight() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let night = try XCTUnwrap(sessions(context).first)

        SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(0, 25), context: context)

        let after = sessions(context)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.contains { $0.id == night.id }, "one segment keeps the row")
        for row in after {
            XCTAssertEqual(SleepService.summary(for: row, context: context).awakeMinutes, 0)
        }
    }

    func testDeletingEveryRecordLeavesTheDayUnslept() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        persist(subscriber, at(0, 0), light(90))
        let night = try XCTUnwrap(sessions(context).first)

        XCTAssertTrue(SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(0, 0), context: context))
        XCTAssertTrue(sessions(context).isEmpty)
        XCTAssertTrue((try context.fetch(FetchDescriptor<SleepStageBlock>())).isEmpty)
    }

    /// One tombstone per key: the table doesn't grow when the same night is deleted from again.
    func testTombstonesAreNotDuplicated() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        seedReportedNight(subscriber)
        let night = try XCTUnwrap(sessions(context).first)
        SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(-1, 8), context: context)
        let count = edits(context).count
        XCTAssertFalse(SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(-1, 8), context: context),
                       "the record is already gone")
        XCTAssertEqual(edits(context).count, count)
    }

    /// The same clock minute on a different night is different data, not a resurrected record.
    func testATombstoneDoesNotLeakToAnotherNight() {
        let edit = SleepRecordEdit(wakingDay: at(0, 0), recordStartAt: at(-1, 8), kind: .recordDeleted)
        let tombstones = SleepRecordTombstones([edit])
        XCTAssertTrue(tombstones.isRecordDeleted(at(-1, 8)))
        XCTAssertFalse(tombstones.isRecordDeleted(at(-1, 8).addingTimeInterval(86_400)))
        XCTAssertFalse(tombstones.isBlockDeleted(at(-1, 8)), "a record tombstone is not a block tombstone")
    }

    func testDeletingAStoredScoreRecomputesIt() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        persist(subscriber, at(-1, 0), light(60))
        persist(subscriber, at(0, 5), Array(repeating: .deep, count: 120) + light(240))
        let night = try XCTUnwrap(sessions(context).first)
        night.score = 1
        try context.save()

        SleepRecordEditor.delete(sessionId: night.id, recordStartAt: at(-1, 0), context: context)
        let expected = SleepScore.calculate(SleepService.summary(for: night, context: context)).score
        XCTAssertEqual(night.score, expected)
        XCTAssertNotEqual(night.score, 1)
    }
}
