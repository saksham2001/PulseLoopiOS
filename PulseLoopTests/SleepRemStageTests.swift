import XCTest
import SwiftData
@testable import PulseLoop

/// REM was decoded off the wire by the Colmi (big-data stage `0x04`) and YCBT (tag `3`) drivers and
/// stored as `SleepStageBlock`s, but never reached `SleepSummary` — so the score, the Sleep tab and
/// the coach all behaved as though no ring could see it. These lock the plumbing and the one scoring
/// side-effect it fixes.
@MainActor
final class SleepRemStageTests: XCTestCase {
    private func night(_ dayOffset: Int) -> Date {
        let base = TestSupport.day(dayOffset)
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: base) ?? base
    }

    /// Per-minute stage array: a REM-capable ring's night.
    private func remNight() -> [SleepStage] {
        Array(repeating: SleepStage.light, count: 60)
            + Array(repeating: .deep, count: 20)
            + Array(repeating: .rem, count: 20)
    }

    /// The same night as a jring would report it — its `0x11` timeline has no REM stage, so those
    /// minutes simply arrive tagged light.
    private func noRemNight() -> [SleepStage] {
        Array(repeating: SleepStage.light, count: 80) + Array(repeating: .deep, count: 20)
    }

    // MARK: - Summary plumbing

    func testSummaryCarriesRemMinutes() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.insertSleep(nightStart: night(0), stages: remNight(), into: context)
        let summary = SleepService.summary(for: session, context: context)

        XCTAssertEqual(summary.remMinutes, 20)
        XCTAssertEqual(summary.lightMinutes, 60)
        XCTAssertEqual(summary.deepMinutes, 20)
        XCTAssertTrue(summary.hasRemSignal)
    }

    func testRingWithoutRemReportsNoRemSignal() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.insertSleep(nightStart: night(0), stages: noRemNight(), into: context)
        let summary = SleepService.summary(for: session, context: context)

        XCTAssertEqual(summary.remMinutes, 0)
        XCTAssertFalse(summary.hasRemSignal, "zero REM minutes with no REM block is an absent sensor, not a zero reading")
        XCTAssertNil(SleepScore.calculate(summary).remPct, "REM % must be absent, never 0%, when the ring can't see REM")
    }

    func testRemPercentIsReportedAgainstTotalSleep() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.insertSleep(nightStart: night(0), stages: remNight(), into: context)
        let score = SleepScore.calculate(SleepService.summary(for: session, context: context))

        // 20 REM minutes of a 100-minute night.
        XCTAssertEqual(score.remPct, 20)
    }

    // MARK: - The scoring side-effect

    /// The regression this fixes: `hasAwakeSignal`'s fallback asks whether the stage timeline
    /// accounted for essentially the whole night. REM was excluded from that sum, so a fully
    /// described REM night looked only 80% covered, failed the 0.95 gate, and had its awake reading
    /// discarded as "no signal" — costing it 45% of the 15-point awake sub-score despite the ring
    /// having described every minute.
    func testFullyDescribedRemNightKeepsItsAwakeSignal() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.insertSleep(nightStart: night(0), stages: remNight(), into: context)
        let score = SleepScore.calculate(SleepService.summary(for: session, context: context))

        XCTAssertEqual(score.awakePct, 0, "a night the ring fully described has a real zero-awake reading")
    }

    /// The complement: a night that genuinely is under-described still withholds the awake signal,
    /// so the coverage fix didn't just make the gate unconditionally true.
    func testPartiallyDescribedNightStillWithholdsAwakeSignal() throws {
        let context = try TestSupport.makeContext()
        // 40 minutes of a 100-minute session are untagged, so coverage is 60% — under the 0.95 gate.
        let stages = Array(repeating: SleepStage.light, count: 40) + Array(repeating: .unknown, count: 60)
        let session = TestSupport.insertSleep(nightStart: night(0), stages: stages, into: context)
        let score = SleepScore.calculate(SleepService.summary(for: session, context: context))

        XCTAssertNil(score.awakePct)
    }

    // MARK: - Range averages

    func testAverageStagesOmitsRemWhenNoNightHasIt() throws {
        let context = try TestSupport.makeContext()
        _ = TestSupport.insertSleep(nightStart: night(0), stages: noRemNight(), into: context)
        _ = TestSupport.insertSleep(nightStart: night(-1), stages: noRemNight(), into: context)

        let valid = SleepInsights.validSessions(SleepService.sleepRange(.week, context: context).sessions)
        XCTAssertNil(SleepInsights.averageStages(valid)?.rem)
    }

    func testAverageStagesReportsRemWhenPresent() throws {
        let context = try TestSupport.makeContext()
        _ = TestSupport.insertSleep(nightStart: night(0), stages: remNight(), into: context)
        _ = TestSupport.insertSleep(nightStart: night(-1), stages: remNight(), into: context)

        let valid = SleepInsights.validSessions(SleepService.sleepRange(.week, context: context).sessions)
        XCTAssertEqual(SleepInsights.averageStages(valid)?.rem, 20)
    }

    func testCollapsedDaySumsRemAcrossNightAndNap() throws {
        let context = try TestSupport.makeContext()
        let start = night(0)
        _ = TestSupport.insertSleep(nightStart: start, stages: remNight(), into: context)
        // A nap the same waking day, well past the 60-minute segmentation gap.
        let napStart = Calendar.current.date(byAdding: .hour, value: 10, to: start) ?? start
        _ = TestSupport.insertSleep(nightStart: napStart, stages: Array(repeating: .rem, count: 15), into: context)

        let valid = SleepInsights.validSessions(SleepService.sleepRange(.week, context: context).sessions)
        let collapsed = SleepInsights.collapseByDay(valid)
        XCTAssertEqual(collapsed.count, 1, "night + nap collapse onto one waking day")
        XCTAssertEqual(collapsed.first?.remMinutes, 35)
    }

    // MARK: - The coach's caveat

    func testDecoderNoteStopsDenyingRemWhenThePresentNightHasIt() {
        let withREM = DataQualityAnalyzer.sleepDecoderNote(hasREM: true)
        let withoutREM = DataQualityAnalyzer.sleepDecoderNote(hasREM: false)

        XCTAssertFalse(withREM.contains("no REM"), "a night with REM must not be described as having none")
        XCTAssertTrue(withoutREM.contains("no REM"), "a jring night is still honestly disclaimed")
        XCTAssertNotEqual(withREM, withoutREM)
    }

    func testWarningsCarryTheMatchingCaveat() {
        let inputs = DataQualityAnalyzer.Inputs(
            profileCompleteness: "complete", daysAvailable: 30,
            hasSleep: true, sleepHasREM: true, lastSyncAt: Date(), isDemo: false
        )
        XCTAssertTrue(DataQualityAnalyzer.warnings(inputs).contains(DataQualityAnalyzer.sleepDecoderNoteWithREM))
    }
}
