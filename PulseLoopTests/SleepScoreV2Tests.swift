import XCTest
import SwiftData
@testable import PulseLoop

/// Sleep score v2: five contributors, missing signals leaving the denominator rather than scoring
/// zero, and duration measured as time *asleep* rather than time in bed. Every number here is locked
/// against `docs/project/sleep-score.md`.
@MainActor
final class SleepScoreV2Tests: XCTestCase {

    /// Builds a night directly, so a test states the stage split it means rather than deriving it.
    private func night(
        inBed: Int, deep: Int, light: Int, awake: Int, rem: Int,
        startAt: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> SleepSummary {
        // One block per stage, enough to satisfy the awake-signal and REM-signal probes.
        var blocks: [SleepStageBlock] = []
        var minute = 0
        for (stage, minutes) in [(SleepStage.deep, deep), (.light, light), (.rem, rem), (.awake, awake)]
        where minutes > 0 {
            blocks.append(SleepStageBlock(sessionId: UUID(), startAt: startAt.addingTimeInterval(Double(minute) * 60),
                                          startMinute: minute, durationMinutes: minutes, stage: stage))
            minute += minutes
        }
        return SleepSummary(
            session: SleepSession(date: Calendar.current.startOfDay(for: startAt), startAt: startAt,
                                  endAt: startAt.addingTimeInterval(Double(inBed) * 60), totalMinutes: inBed),
            lightMinutes: light, deepMinutes: deep, awakeMinutes: awake, remMinutes: rem, blocks: blocks
        )
    }

    private func contributor(_ kind: SleepContributor.Kind, in result: SleepScoreResult) -> SleepContributor? {
        result.contributors.first { $0.kind == kind }
    }

    // MARK: - Duration is time asleep, not time in bed

    /// v1 scored `totalMinutes`, which `SleepSegmentation` sets from `end − start` — so 8 h in bed
    /// with 90 min awake was credited as 8 h of sleep.
    func testDurationExcludesAwakeTime() {
        let result = SleepScore.calculate(night(inBed: 480, deep: 90, light: 200, awake: 90, rem: 100))
        XCTAssertEqual(result.asleepMinutes, 390, "480 in bed minus 90 awake")
    }

    /// Without a usable wake signal there is nothing to subtract, so the whole span stands in.
    func testDurationFallsBackToTimeInBedWithoutAWakeSignal() {
        // Blocks cover only 60% of the span, so the 0.95 coverage fallback can't infer zero awake.
        let partial = SleepSummary(
            session: SleepSession(date: Date(), startAt: Date(), endAt: Date().addingTimeInterval(480 * 60),
                                  totalMinutes: 480),
            lightMinutes: 200, deepMinutes: 90, awakeMinutes: 0, remMinutes: 0,
            blocks: [SleepStageBlock(sessionId: UUID(), startAt: Date(), startMinute: 0,
                                     durationMinutes: 290, stage: .light)]
        )
        let result = SleepScore.calculate(partial)
        XCTAssertEqual(result.asleepMinutes, 480)
        XCTAssertNil(result.awakePct)
    }

    // MARK: - Contributors present and absent

    func testFullNightScoresAllFiveContributors() {
        let baseline = BedtimeBaseline(medianMinutesFromMidnight: -60, nights: 14)
        let result = SleepScore.calculate(night(inBed: 480, deep: 90, light: 220, awake: 30, rem: 140),
                                          bedtimeBaseline: baseline)
        XCTAssertEqual(Set(result.contributors.map(\.kind)),
                       [.duration, .deep, .rem, .restfulness, .timing])
        XCTAssertEqual(result.coverage, 1.0, accuracy: 0.001)
    }

    /// A jring has no REM stage. Those 20 points leave the denominator — the night is scored out of
    /// 80, not penalised 20.
    func testRingWithoutRemIsScoredOutOfEighty() {
        let baseline = BedtimeBaseline(medianMinutesFromMidnight: -60, nights: 14)
        let result = SleepScore.calculate(night(inBed: 480, deep: 90, light: 360, awake: 30, rem: 0),
                                          bedtimeBaseline: baseline)
        XCTAssertNil(contributor(.rem, in: result))
        XCTAssertEqual(result.coverage, 0.8, accuracy: 0.001, "100 points less REM's 20")
        XCTAssertNil(result.remPct, "absent, never 0%")
    }

    /// The same stage split scores the same whether or not the ring can see REM, once REM is at its
    /// ideal share — which is the property that makes one number comparable across hardware.
    func testAnIdealNightScoresTheSameWithAndWithoutRemCoverage() {
        let withREM = SleepScore.calculate(night(inBed: 480, deep: 86, light: 268, awake: 22, rem: 104))
        let withoutREM = SleepScore.calculate(night(inBed: 480, deep: 86, light: 372, awake: 22, rem: 0))
        XCTAssertEqual(withREM.score, withoutREM.score, accuracy: 1)
    }

    /// Bedtime consistency needs a week of prior nights; until then its 10 points leave the
    /// denominator rather than being scored as a miss.
    func testTimingIsWithheldUntilTheBaselineIsEstablished() {
        let thin = BedtimeBaseline(medianMinutesFromMidnight: -60, nights: 6)
        let result = SleepScore.calculate(night(inBed: 480, deep: 90, light: 220, awake: 30, rem: 140),
                                          bedtimeBaseline: thin)
        XCTAssertNil(contributor(.timing, in: result))
        XCTAssertEqual(result.coverage, 0.9, accuracy: 0.001)
    }

    /// Light is reported for display but never scored — once deep and REM are both scored it is
    /// their residual, so scoring it would count the same night twice.
    func testLightIsReportedButNotScored() {
        let result = SleepScore.calculate(night(inBed: 480, deep: 90, light: 220, awake: 30, rem: 140))
        XCTAssertEqual(result.lightPct, 46)
        XCTAssertFalse(result.contributors.contains { $0.kind.title.lowercased().contains("light") })
    }

    // MARK: - Thresholds

    func testTimingScoreKnots() {
        XCTAssertEqual(SleepScore.timingScore(driftMinutes: 0, points: 10), 10, accuracy: 0.001)
        XCTAssertEqual(SleepScore.timingScore(driftMinutes: 30, points: 10), 10, accuracy: 0.001,
                       "the 30-minute knot is inclusive")
        XCTAssertEqual(SleepScore.timingScore(driftMinutes: 60, points: 10), 5.5, accuracy: 0.001)
        XCTAssertEqual(SleepScore.timingScore(driftMinutes: 120, points: 10), 0, accuracy: 0.001)
        XCTAssertEqual(SleepScore.timingScore(driftMinutes: 300, points: 10), 0, accuracy: 0.001,
                       "clamped, never negative")
    }

    func testAwakeScoreKnots() {
        XCTAssertEqual(SleepScore.awakeScore(10, points: 15), 15, accuracy: 0.001)
        XCTAssertEqual(SleepScore.awakeScore(20, points: 15), 5.25, accuracy: 0.001)
        XCTAssertEqual(SleepScore.awakeScore(35, points: 15), 0, accuracy: 0.001)
    }

    // MARK: - Bedtime baseline maths

    /// Bedtimes straddle midnight, so they are averaged on a wrapped axis — otherwise 23:40 and
    /// 00:20 would average to noon instead of to midnight.
    func testBedtimeMedianWrapsAroundMidnight() {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        let before = calendar.date(byAdding: .minute, value: -20, to: base)!   // 23:40
        let after = calendar.date(byAdding: .minute, value: 20, to: base)!     // 00:20

        XCTAssertEqual(BedtimeBaseline.minutesFromMidnight(before), -20, accuracy: 0.001)
        XCTAssertEqual(BedtimeBaseline.minutesFromMidnight(after), 20, accuracy: 0.001)

        let baseline = BedtimeBaseline.compute(bedtimes: [before, after])
        XCTAssertEqual(baseline?.medianMinutesFromMidnight ?? .nan, 0, accuracy: 0.001)
    }

    func testBaselineNeedsSevenNights() {
        let bedtimes = (0..<6).map { Date().addingTimeInterval(Double($0) * -86_400) }
        XCTAssertEqual(BedtimeBaseline.compute(bedtimes: bedtimes)?.isEstablished, false)
        XCTAssertEqual(BedtimeBaseline.compute(bedtimes: bedtimes + [Date()])?.isEstablished, true)
        XCTAssertNil(BedtimeBaseline.compute(bedtimes: []))
    }

    /// The baseline must exclude the night being scored — including it would drag the median toward
    /// that night and forgive exactly the drift the contributor exists to catch.
    func testBaselineExcludesTheNightBeingScored() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current

        // Ten prior nights, all starting at 23:00.
        for offset in 1...10 {
            let day = TestSupport.day(-offset)
            let bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: bedtime, stages: Array(repeating: .light, count: 420), into: context)
        }
        // Tonight, three hours late.
        let tonight = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: TestSupport.day(0)) ?? TestSupport.day(0)
        _ = TestSupport.insertSleep(nightStart: tonight, stages: Array(repeating: .light, count: 300), into: context)

        let baseline = try XCTUnwrap(SleepService.bedtimeBaseline(before: TestSupport.day(0), context: context))
        XCTAssertTrue(baseline.isEstablished)
        XCTAssertEqual(baseline.medianMinutesFromMidnight, -60, accuracy: 1,
                       "23:00 on the wrapped axis, unmoved by tonight's 02:00")
    }

    // MARK: - Guard rails

    /// A fragment of a night — nothing but a short duration reading — can't be dressed up as a
    /// score out of 30.
    func testTooLittleCoverageScoresZero() {
        let sparse = SleepSummary(
            session: SleepSession(date: Date(), startAt: Date(), endAt: Date().addingTimeInterval(3600),
                                  totalMinutes: 0),
            lightMinutes: 0, deepMinutes: 0, awakeMinutes: 0, remMinutes: 0, blocks: []
        )
        let result = SleepScore.calculate(sparse)
        XCTAssertEqual(result.score, 0)
        XCTAssertLessThan(result.coverage, 0.5)
    }

    func testVersionIsStamped() {
        XCTAssertEqual(SleepScore.calculate(night(inBed: 480, deep: 90, light: 220, awake: 30, rem: 140)).algorithmVersion,
                       SleepScore.algorithmVersion)
        XCTAssertEqual(SleepScore.algorithmVersion, 2)
    }

    /// Every contributor's points must sum to exactly 100, or `coverage` stops meaning "fraction of
    /// the full picture".
    func testContributorWeightsSumToOneHundred() {
        XCTAssertEqual(SleepContributor.Kind.allCases.reduce(0) { $0 + $1.maxPoints }, 100, accuracy: 0.001)
    }
}
