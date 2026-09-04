import XCTest
@testable import PulseLoop

/// Pure-algorithm tests for the cycle analyzer: cycle-start derivation, the 3-over-6 rule
/// with both Sensiplan exceptions, disturbed-day handling, predictions, and the status copy.
/// Everything runs on synthetic `CycleDayRecord` arrays — no store, no clock.
@MainActor
final class CycleAnalyzerTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var base = calendar.startOfDay(for: Date())

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base)!
    }

    /// Records for cycle day 1…n (day 1 == offset 0): `temps[i]` maps to day i+1.
    private func records(
        temps: [Double?],
        periodDays: Set<Int> = [1, 2, 3, 4],
        disturbed: Set<Int> = []
    ) -> [CycleDayRecord] {
        temps.enumerated().map { index, temp in
            let dayNumber = index + 1
            return CycleDayRecord(
                date: day(index),
                temperature: temp,
                isPeriod: periodDays.contains(dayNumber),
                isDisturbed: disturbed.contains(dayNumber)
            )
        }
    }

    /// A textbook biphasic cycle: 10 low nights then a sustained rise.
    private func biphasicTemps(lowDays: Int = 10, highDays: Int = 8, low: Double = 36.0, high: Double = 36.5) -> [Double?] {
        Array(repeating: low, count: lowDays) + Array(repeating: high, count: highDays)
    }

    // MARK: - Cycle starts

    func testPeriodStartDerivationSplitsOnGap() {
        var days: [CycleDayRecord] = []
        // Period days 0–4, a spotting gap (day 6 flagged), then a fresh period 28–31.
        for offset in [0, 1, 2, 3, 4, 6, 28, 29, 30, 31] {
            days.append(CycleDayRecord(date: day(offset), temperature: nil, isPeriod: true, isDisturbed: false))
        }
        let starts = CycleAnalyzer.periodStarts(days: days, calendar: calendar)
        // Day 6 is ≤3 days after day 4 → same period; day 28 opens a new cycle.
        XCTAssertEqual(starts, [day(0), day(28)])
    }

    func testNoPeriodLoggedReturnsNil() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: [36.0, 36.1], periodDays: []),
            goal: .understand, today: day(1), calendar: calendar
        )
        XCTAssertNil(analysis)
    }

    // MARK: - Thermal shift detection

    func testIdealCycleConfirmsOvulation() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps()),
            goal: .understand, today: day(17), calendar: calendar
        )!
        guard case let .confirmed(estimated, confirmedOn) = analysis.ovulation else {
            return XCTFail("expected confirmed, got \(analysis.ovulation)")
        }
        // Raw highs start day 11; the 3-day rolling median delays the smoothed rise to day 12,
        // so the estimate lands on day 11 and confirmation on the 3rd smoothed high (day 14).
        XCTAssertEqual(estimated, day(10))
        XCTAssertEqual(confirmedOn, day(13))
        XCTAssertEqual(analysis.coverline, 36.0)
        XCTAssertEqual(analysis.phase, .luteal)
    }

    func testFlatCycleDetectsNothing() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: Array(repeating: 36.0, count: 20)),
            goal: .understand, today: day(19), calendar: calendar
        )!
        XCTAssertEqual(analysis.ovulation, .notDetected)
        XCTAssertNil(analysis.coverline)
    }

    func testTwoRawHighDaysReadAsProbable() {
        // 10 lows + 3 raw highs → 2 smoothed highs: rise underway but unconfirmed.
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps(highDays: 3)),
            goal: .understand, today: day(12), calendar: calendar
        )!
        guard case .probable = analysis.ovulation else {
            return XCTFail("expected probable, got \(analysis.ovulation)")
        }
        XCTAssertEqual(analysis.phase, .fertile)
    }

    func testDisturbedDaysAreSkippedNotFatal() {
        // Fever spike on day 8 is flagged disturbed → the analysis must still confirm.
        var temps = biphasicTemps()
        temps[7] = 37.2
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: temps, disturbed: [8]),
            goal: .understand, today: day(17), calendar: calendar
        )!
        XCTAssertTrue(analysis.ovulation.isConfirmed)
        XCTAssertEqual(analysis.coverline, 36.0)
    }

    func testUnflaggedFeverSuggestsDisturbance() {
        var temps: [Double?] = Array(repeating: 36.0, count: 9)
        temps.append(36.8)   // last night, way above baseline, not excluded
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: temps),
            goal: .understand, today: day(9), calendar: calendar
        )!
        XCTAssertEqual(analysis.disturbanceSuggestion, day(9))
    }

    func testConfirmedLutealHighsAreNotFlaggedAsFever() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps()),
            goal: .understand, today: day(17), calendar: calendar
        )!
        XCTAssertTrue(analysis.ovulation.isConfirmed)
        XCTAssertNil(analysis.disturbanceSuggestion)
    }

    // MARK: - Rise-rule exceptions (tested on the rule directly, past the smoothing)

    private let config = CycleAnalyzerConfig()

    func testRiseRulePlainConfirmation() {
        // 6 reference lows at 36.0, then 3 highs with the 3rd clearing coverline + delta.
        let values: [Double] = [36.0, 36.0, 36.0, 36.0, 36.0, 36.0, 36.1, 36.2, 36.3]
        XCTAssertEqual(
            CycleAnalyzer.evaluateRise(candidate: 6, coverline: 36.0, values: values, config: config),
            .confirmed(finalIndex: 8)
        )
    }

    func testException1WeakThirdRescuedByFourth() {
        // 3rd high is above the line but < delta → a 4th above the line confirms.
        let values: [Double] = [36.0, 36.0, 36.0, 36.0, 36.0, 36.0, 36.1, 36.2, 36.1, 36.1]
        XCTAssertEqual(
            CycleAnalyzer.evaluateRise(candidate: 6, coverline: 36.0, values: values, config: config),
            .confirmed(finalIndex: 9)
        )
    }

    func testException2DipRescuedByFullDeltaCloser() {
        // 2nd value dips to the line → forgiven; the replacement must clear the full delta.
        let values: [Double] = [36.0, 36.0, 36.0, 36.0, 36.0, 36.0, 36.1, 35.95, 36.2, 36.3]
        XCTAssertEqual(
            CycleAnalyzer.evaluateRise(candidate: 6, coverline: 36.0, values: values, config: config),
            .confirmed(finalIndex: 9)
        )
    }

    func testException2CloserBelowDeltaFails() {
        // After a dip the exceptions must not combine: a weak closer fails the candidate.
        let values: [Double] = [36.0, 36.0, 36.0, 36.0, 36.0, 36.0, 36.1, 35.95, 36.2, 36.1, 36.1]
        XCTAssertEqual(
            CycleAnalyzer.evaluateRise(candidate: 6, coverline: 36.0, values: values, config: config),
            .failed
        )
    }

    func testTwoDipsFailTheCandidate() {
        let values: [Double] = [36.0, 36.0, 36.0, 36.0, 36.0, 36.0, 36.1, 35.9, 36.1, 35.9]
        XCTAssertEqual(
            CycleAnalyzer.evaluateRise(candidate: 6, coverline: 36.0, values: values, config: config),
            .failed
        )
    }

    // MARK: - Predictions

    func testFirstCycleWithoutShiftHasNoPrediction() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: Array(repeating: 36.0, count: 12)),
            goal: .understand, today: day(11), calendar: calendar
        )!
        XCTAssertNil(analysis.nextPeriod)
        XCTAssertTrue(analysis.completedCycles.isEmpty)
    }

    func testConfirmedOvulationPredictsPeriodFromLutealLength() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps()),
            goal: .understand, today: day(17), calendar: calendar
        )!
        // No history → default 14-day luteal from the estimated ovulation (day 11).
        XCTAssertEqual(analysis.nextPeriod?.expected, day(10 + 14))
    }

    func testCompletedCyclesDriveTypicalLengthPrediction() {
        // Two completed 28-day cycles (period at days 0 and 28), current start at 56, no temps.
        var days: [CycleDayRecord] = []
        for offset in [0, 28, 56] {
            days.append(CycleDayRecord(date: day(offset), temperature: nil, isPeriod: true, isDisturbed: false))
        }
        let analysis = CycleAnalyzer.analyze(days: days, goal: .understand, today: day(60), calendar: calendar)!
        XCTAssertEqual(analysis.typicalCycleLengthDays, 28)
        XCTAssertEqual(analysis.nextPeriod?.expected, day(56 + 28))
        XCTAssertEqual(analysis.completedCycles.map(\.lengthDays), [28, 28])
    }

    func testAvoidGoalWidensTheFertileWindow() {
        var days: [CycleDayRecord] = []
        for offset in [0, 28] {
            days.append(CycleDayRecord(date: day(offset), temperature: nil, isPeriod: true, isDisturbed: false))
        }
        let today = day(34)
        let standard = CycleAnalyzer.analyze(days: days, goal: .understand, today: today, calendar: calendar)!
        let cautious = CycleAnalyzer.analyze(days: days, goal: .avoid, today: today, calendar: calendar)!
        let standardWindow = standard.fertileWindow!
        let cautiousWindow = cautious.fertileWindow!
        XCTAssertTrue(cautiousWindow.lowerBound < standardWindow.lowerBound)
        XCTAssertTrue(cautiousWindow.upperBound > standardWindow.upperBound)
    }

    // MARK: - Flags

    func testLongHighPlateauFlagsPossiblePregnancy() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps(highDays: 20)),
            goal: .understand, today: day(29), calendar: calendar
        )!
        XCTAssertTrue(analysis.flags.contains(.possiblePregnancy))
    }

    func testLateCycleWithoutShiftFlagsHonestly() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: Array(repeating: 36.0, count: 36)),
            goal: .understand, today: day(35), calendar: calendar
        )!
        XCTAssertTrue(analysis.flags.contains(.noThermalShiftYet))
    }

    func testLongCycleWithoutShiftFlagsLongCycle() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: Array(repeating: 36.0, count: 70)),
            goal: .understand, today: day(69), calendar: calendar
        )!
        XCTAssertEqual(analysis.flags, [.longCycle])
        XCTAssertEqual(CycleCopy.headline(analysis, hormonal: false, today: day(69), calendar: calendar), "Long cycle — waiting for data")
    }

    /// A late first ovulation (postpartum return, PCOS, perimenopause): once the shift is
    /// confirmed the cycle has restarted, so the long-cycle banner must give way to the
    /// confirmation and the period countdown instead of hiding them.
    func testConfirmedShiftClearsTheLongCycleFlag() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps(lowDays: 65, highDays: 4)),
            goal: .understand, today: day(68), calendar: calendar
        )!
        XCTAssertTrue(analysis.ovulation.isConfirmed)
        XCTAssertTrue(analysis.flags.isEmpty)
        XCTAssertNotNil(analysis.nextPeriod)
        XCTAssertEqual(CycleCopy.headline(analysis, hormonal: false, today: day(68), calendar: calendar), "Ovulation likely confirmed")
    }

    func testProbableShiftKeepsTheLongCycleFlag() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: biphasicTemps(lowDays: 65, highDays: 3)),
            goal: .understand, today: day(67), calendar: calendar
        )!
        if case .probable = analysis.ovulation {} else { XCTFail("expected a probable rise, got \(analysis.ovulation)") }
        XCTAssertEqual(analysis.flags, [.longCycle])
    }

    // MARK: - Copy

    func testHeadlinePrioritizesPeriodOverEverything() {
        let analysis = CycleAnalyzer.analyze(
            days: records(temps: [36.0, 36.0], periodDays: [1, 2]),
            goal: .understand, today: day(1), calendar: calendar
        )!
        XCTAssertEqual(CycleCopy.headline(analysis, hormonal: false, today: day(1), calendar: calendar), "Period — day 2")
    }

    func testHeadlineCountsDownToPredictedPeriod() {
        var days: [CycleDayRecord] = []
        for offset in [0, 28] {
            days.append(CycleDayRecord(date: day(offset), temperature: nil, isPeriod: true, isDisturbed: false))
        }
        let analysis = CycleAnalyzer.analyze(days: days, goal: .understand, today: day(52), calendar: calendar)!
        XCTAssertEqual(CycleCopy.headline(analysis, hormonal: false, today: day(52), calendar: calendar), "Period in ~4 days")
    }

    func testPeriodStartButtonOnlyNearPredictedDate() {
        var days: [CycleDayRecord] = []
        for offset in [0, 28] {
            days.append(CycleDayRecord(date: day(offset), temperature: nil, isPeriod: true, isDisturbed: false))
        }
        let midCycle = CycleAnalyzer.analyze(days: days, goal: .understand, today: day(40), calendar: calendar)!
        XCTAssertFalse(CycleCopy.shouldOfferPeriodStart(midCycle, today: day(40), calendar: calendar))
        let nearDue = CycleAnalyzer.analyze(days: days, goal: .understand, today: day(54), calendar: calendar)!
        XCTAssertTrue(CycleCopy.shouldOfferPeriodStart(nearDue, today: day(54), calendar: calendar))
        XCTAssertTrue(CycleCopy.shouldOfferPeriodStart(nil, today: day(0), calendar: calendar))
    }
}
