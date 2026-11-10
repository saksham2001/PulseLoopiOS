import XCTest
@testable import PulseLoop

/// The gaps inside and between ring sleep records (Android #111/#116, `SleepGapsTest` and the
/// placement cases of `YCBTHealthRecordsTest`): how a hole between stage segments is placed, how
/// long a gap between records is, and how the hypnogram draws it.
@MainActor
final class SleepGapsTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Oct 11 2026 UTC wall-clock time.
    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: hour, minute: minute, second: second))!
    }

    private func record(_ start: Date, _ minutes: Int, _ stage: SleepStage = .light) -> [SleepStageBlock] {
        SleepRecords.stageBlocks(start: start, stages: Array(repeating: stage, count: minutes))
    }

    /// Blocks as a stored session holds them: `startMinute` relative to the session's start.
    private func session(_ blocks: [SleepStageBlock]) -> [SleepStageBlock] {
        let start = blocks.map(\.startAt).min()!
        for block in blocks { block.startMinute = Int(block.startAt.timeIntervalSince(start) / 60) }
        return blocks
    }

    // MARK: - The gap is rounded, not truncated

    /// The reporter's Oct 10–11 waking: the first record ended 07:08:53 and the next opened 07:11:00
    /// — 2m07. Its start (00:30:14) plus whole minutes stores the end at 07:09:14, leaving 1m46.
    func testA2m07WakingIsNotLostToTheStoredEndsRounding() {
        let blocks = record(at(0, 30, 14), 399) + record(at(7, 11), 60)
        let runs = SleepRecords.runs(blocks)
        XCTAssertEqual(SleepRecords.betweenRecordAwakeMinutes(runs[0], runs[1]), 2)
        XCTAssertEqual(SleepRecords.awakeMinutes(blocks), 2)
    }

    /// A 52 s get-up between records counts one awake minute: every gap is a waking.
    func testA52SecondGetUpBetweenRecordsCountsOneMinute() {
        let blocks = record(at(0, 30, 9), 243) + record(at(4, 34, 1), 60)   // 04:33:09 → 04:34:01
        let runs = SleepRecords.runs(blocks)
        XCTAssertEqual(SleepRecords.betweenRecordAwakeMinutes(runs[0], runs[1]), 1)
        XCTAssertEqual(SleepRecords.awakeMinutes(blocks), 1)
    }

    /// Ties round down: 90 s is one minute, 91 s two.
    func testGapsRoundWithTiesDown() {
        let a = SleepRecords.runs(record(at(1, 0), 30))[0]
        func gap(_ seconds: Int) -> Int {
            SleepRecords.betweenRecordAwakeMinutes(a, SleepRecords.runs(record(a.endAt.addingTimeInterval(TimeInterval(seconds)), 30))[0])
        }
        XCTAssertEqual(gap(89), 1)
        XCTAssertEqual(gap(90), 1)
        XCTAssertEqual(gap(91), 2)
    }

    /// Records that touch exactly, as a Jring's 15-minute packets do, have no waking between them.
    func testBackToBackRecordsCountNoAwakeTime() {
        let blocks = record(at(2, 0), 15) + record(at(2, 15), 15)
        let runs = SleepRecords.runs(blocks)
        XCTAssertEqual(SleepRecords.betweenRecordAwakeMinutes(runs[0], runs[1]), 0)
        XCTAssertEqual(SleepRecords.awakeMinutes(blocks), 0)
    }

    // MARK: - The hypnogram draws the counted gap

    func testTheHypnogramGetsAnAwakeBlockOverACountedGapForDisplayOnly() {
        let blocks = session(record(at(0, 0), 60, .deep) + record(at(1, 15), 30))
        let drawn = SleepRecords.hypnogramBlocks(blocks)
        let gaps = drawn.filter { block in !blocks.contains { $0 === block } }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].stage, .awake)
        XCTAssertEqual(gaps[0].startMinute, 60)
        XCTAssertEqual(gaps[0].durationMinutes, 15)
        XCTAssertEqual(SleepRecords.awakeMinutes(blocks), 15, "the Awake figure counts the gap itself")
    }

    func testTheHypnogramDrawsNothingBetweenBackToBackRecords() {
        let blocks = session(record(at(0, 0), 60) + record(at(1, 0), 30))
        XCTAssertEqual(SleepRecords.hypnogramBlocks(blocks).count, blocks.count)
    }

    func testTheHypnogramDrawsAOneMinuteGap() {
        let blocks = session(record(at(0, 0), 60) + record(at(1, 1), 30))
        let gaps = SleepRecords.hypnogramBlocks(blocks).filter { block in !blocks.contains { $0 === block } }
        XCTAssertEqual(gaps.map(\.durationMinutes), [1])
    }

    // MARK: - YCBT: segments placed against the header's bounds

    private let base = 0x31def01c

    /// An `af fa` record with the header's start (+4) and end (+8) filled in; each segment carries its
    /// own start: `(tag, startSeconds, seconds)`.
    private func sleepRecord(_ start: Int, _ end: Int, _ segments: [(tag: UInt8, start: Int, seconds: Int)]) -> [UInt8] {
        func le(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * $0)) & 0xff) } }
        var out: [UInt8] = [0xaf, 0xfa] + le(20 + segments.count * 8, 2) + le(start, 4) + le(end, 4)
        out += [UInt8](repeating: 0, count: 8)
        for segment in segments { out += [segment.tag] + le(segment.start, 4) + le(segment.seconds, 3) }
        return out
    }

    /// Contiguous segments from `start`, as a ring writes them.
    private func contiguous(_ start: Int, _ segments: [(UInt8, Int)]) -> [(tag: UInt8, start: Int, seconds: Int)] {
        var at = start
        return segments.map { tag, seconds in defer { at += seconds }; return (tag, at, seconds) }
    }

    private func timelines(_ buffer: [UInt8]) -> [(start: Date, stages: [SleepStage])] {
        YCBTHealthRecords.sleep(buffer).compactMap {
            if case let .sleepTimeline(start, stages) = $0 { return (start, stages) } else { return nil }
        }
    }

    /// The timeline spans exactly the header's declared start and end.
    func testASessionSpansExactlyTheHeadersDeclaredBounds() {
        let record = sleepRecord(base, base + 474 * 60 + 30, contiguous(base, [(0xf2, 200 * 60), (0xf1, 274 * 60)]))
        let timeline = timelines(record)[0]
        XCTAssertEqual(timeline.start, YCBTBytes.date(base))
        XCTAssertEqual(timeline.stages.count, 475)
    }

    /// Two records a minute apart: the first's sub-minute segments round long under concatenation,
    /// which would put its end on the second's start. Placed against the header, the gap survives.
    func testARecordWhoseSegmentsRoundLongStillEndsAtItsDeclaredEnd() {
        let firstEnd = base + 322 * 60
        let secondStart = firstEnd + 60
        let first = sleepRecord(base, firstEnd, contiguous(base, [(0xf2, 320 * 60)] + Array(repeating: (0xf1, 20), count: 4)))
        let second = sleepRecord(secondStart, secondStart + 151 * 60, contiguous(secondStart, [(0xf2, 151 * 60)]))
        let result = timelines(first + second)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].stages.count, 322)
        let firstEndDate = result[0].start.addingTimeInterval(322 * 60)
        XCTAssertEqual(result[1].start.timeIntervalSince(firstEndDate), 60)
    }

    func testMinutesNoSegmentClaimsReadAsAwake() {
        let stages = timelines(sleepRecord(base, base + 60 * 60, contiguous(base, [(0xf2, 30 * 60)])))[0].stages
        XCTAssertEqual(stages.count, 60)
        XCTAssertEqual(stages.filter { $0 == .light }.count, 30)
        XCTAssertEqual(stages.filter { $0 == .awake }.count, 30)
        XCTAssertTrue(stages.prefix(30).allSatisfy { $0 == .light })
    }

    /// A zero-length segment sharing a real segment's start must not shadow it in the de-duplication.
    func testAZeroLengthSegmentDoesNotShadowARealSegmentSharingItsStart() {
        let record = sleepRecord(base, base + 10 * 60, [(0xf2, base, 5 * 60), (0xf1, base + 300, 0), (0xf3, base + 300, 5 * 60)])
        let stages = timelines(record)[0].stages
        XCTAssertEqual(stages.filter { $0 == .light }.count, 5)
        XCTAssertEqual(stages.filter { $0 == .rem }.count, 5)
        XCTAssertFalse(stages.contains(.awake))
    }

    /// The reporter's Oct 8–9 night: LIGHT ends at minute 315.48 (rounds to 315), REM opens at 315.5
    /// (rounds to 316). Minute 315 used to keep the AWAKE filler.
    func testAOneSecondSeamBetweenSegmentsLeavesNoAwakeMinute() {
        let lightStart = base + 303 * 60 + 1
        let remStart = lightStart + 748 + 1
        let record = sleepRecord(base, remStart + 30 * 60, [
            (0xf1, base, 303 * 60 + 1), (0xf2, lightStart, 748), (0xf3, remStart, 30 * 60),
        ])
        XCTAssertFalse(timelines(record)[0].stages.contains(.awake))
    }

    /// The last stage ends 06:58:33 and the record 06:58:34.
    func testAOneSecondSeamBeforeTheRecordsEndLeavesNoAwakeMinute() {
        let start = base + 20
        let record = sleepRecord(start, start + 120 * 60 + 31, [(0xf2, start, 120 * 60 + 30)])
        XCTAssertFalse(timelines(record)[0].stages.contains(.awake))
    }

    /// A hole the ring really left — a minute or more — still reads as wake.
    func testAGapOfAMinuteOrMoreBetweenSegmentsStaysAwake() {
        let record = sleepRecord(base, base + 63 * 60, [(0xf2, base, 30 * 60), (0xf1, base + 33 * 60, 30 * 60)])
        let stages = timelines(record)[0].stages
        XCTAssertEqual(stages.count, 63)
        XCTAssertEqual(stages.filter { $0 == .awake }.count, 3)
    }

    /// A segment nested inside another must not hide the seam to the one that follows.
    func testANestedSegmentDoesNotReopenTheSeamAfterItsContainer() {
        let record = sleepRecord(base, base + 20 * 60, [
            (0xf2, base, 11 * 60 + 29),            // ends at 11.48 min
            (0xf1, base + 100, 100),               // nested inside the first
            (0xf3, base + 11 * 60 + 30, 8 * 60 + 30),
        ])
        XCTAssertFalse(timelines(record)[0].stages.contains(.awake))
    }
}
