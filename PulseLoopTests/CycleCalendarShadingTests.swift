import XCTest
@testable import PulseLoop

/// Classification tests for the month calendar's day shading: which tint a day gets, and in what
/// order the rules win. Fixtures run through `CycleAnalyzer.analyze` over synthetic
/// `CycleDayRecord`s — the pipeline `CycleService` uses at runtime — so the expectations track
/// the real analysis instead of a hand-written stub.
@MainActor
final class CycleCalendarShadingTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var base = calendar.startOfDay(for: Date())

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base)!
    }

    /// Records for cycle day 1…n (day 1 == offset 0): `temps[i]` maps to day i+1.
    private func records(temps: [Double?], periodDays: Set<Int> = [1, 2, 3, 4]) -> [CycleDayRecord] {
        temps.enumerated().map { index, temp in
            CycleDayRecord(
                date: day(index),
                temperature: temp,
                isPeriod: periodDays.contains(index + 1),
                isDisturbed: false
            )
        }
    }

    /// A textbook biphasic cycle: low nights then a sustained rise.
    private func biphasicTemps(lowDays: Int = 10, highDays: Int = 8, low: Double = 36.0, high: Double = 36.5) -> [Double?] {
        Array(repeating: low, count: lowDays) + Array(repeating: high, count: highDays)
    }

    /// The overview the calendar receives: analysis plus logged facts, both off the same records.
    private func makeOverview(_ records: [CycleDayRecord], today: Date, goal: CycleGoal = .understand) -> CycleOverview {
        var facts: [String: CycleOverview.CycleDayFacts] = [:]
        for record in records {
            facts[CycleDay.key(for: record.date)] = CycleOverview.CycleDayFacts(
                isPeriod: record.isPeriod, isDisturbed: record.isDisturbed, hasNote: false
            )
        }
        return CycleOverview(
            analysis: CycleAnalyzer.analyze(days: records, goal: goal, today: today, calendar: calendar),
            chartDays: [],
            loggedDays: facts
        )
    }

    /// The cycle most tests read: period on days 1–4, 10 low nights, then a sustained rise.
    /// Ovulation lands on day(9) and is confirmed on day(13) — see `testReferenceCycleAnchors`.
    private func idealCycle(today: Date) -> CycleOverview {
        makeOverview(records(temps: biphasicTemps()), today: today)
    }

    private func shading(_ overview: CycleOverview, _ day: Date, today: Date) -> CycleCalendarShading {
        CycleCalendarShading.shading(for: day, overview: overview, today: today, calendar: calendar)
    }

    // MARK: - Fixture anchors

    func testReferenceCycleAnchors() {
        let today = day(17)
        let analysis = idealCycle(today: today).analysis!
        guard case let .confirmed(estimated, confirmedOn) = analysis.ovulation else {
            return XCTFail("expected confirmed, got \(analysis.ovulation)")
        }
        XCTAssertEqual(estimated, day(9))
        XCTAssertEqual(confirmedOn, day(13))
        // Default 14-day luteal from the estimate: the period is expected on day(23), so the
        // luteal band the calendar draws runs day(14)…day(22).
        XCTAssertEqual(analysis.nextPeriod?.expected, day(23))
        XCTAssertEqual(analysis.drawnFertileWindow(calendar: calendar), day(5)...day(13))
    }

    // MARK: - Logged period

    func testLoggedPeriodDaysShadeAsPeriod() {
        let today = day(17)
        let overview = idealCycle(today: today)
        for offset in 0...3 {
            XCTAssertEqual(shading(overview, day(offset), today: today), .period, "day(\(offset))")
        }
        XCTAssertNotEqual(shading(overview, day(4), today: today), .period)
    }

    // MARK: - Predicted period

    func testPredictedPeriodCoversExpectedStartPlusFlowDays() {
        let today = day(17)
        let overview = idealCycle(today: today)
        XCTAssertEqual(shading(overview, day(22), today: today), .luteal)      // day before the prediction
        XCTAssertEqual(shading(overview, day(23), today: today), .predictedPeriod)
        XCTAssertEqual(shading(overview, day(27), today: today), .predictedPeriod)
        XCTAssertEqual(shading(overview, day(28), today: today), .none)
    }

    func testExpectedPeriodDueTodayShadesTodayAndTheFlowDays() {
        // The day the headline reads "Period due today": the flow is drawn from today on, not
        // skipped for landing on the boundary.
        let today = day(23)
        let overview = idealCycle(today: today)
        XCTAssertEqual(overview.analysis?.nextPeriod?.expected, today)
        XCTAssertEqual(shading(overview, day(22), today: today), .luteal)      // day before the prediction
        for offset in 23...27 {
            XCTAssertEqual(shading(overview, day(offset), today: today), .predictedPeriod, "day(\(offset))")
        }
        XCTAssertEqual(shading(overview, day(28), today: today), .none)
    }

    func testExpectedPeriodAlreadyInThePastIsNotShaded() {
        // The period is late: past days show what was logged, not what was forecast.
        let today = day(30)
        let overview = idealCycle(today: today)
        XCTAssertEqual(overview.analysis?.nextPeriod?.expected, day(23))
        XCTAssertEqual(shading(overview, day(23), today: today), .none)
        XCTAssertEqual(shading(overview, day(22), today: today), .luteal)
    }

    // MARK: - Fertile window

    func testFertileWindowDaysShadeAsFertile() {
        let today = day(17)
        let overview = idealCycle(today: today)
        XCTAssertEqual(shading(overview, day(4), today: today), .none)         // just before the window
        XCTAssertEqual(shading(overview, day(5), today: today), .fertile)
        XCTAssertEqual(shading(overview, day(13), today: today), .fertile)     // the confirming high closes it
        XCTAssertEqual(shading(overview, day(14), today: today), .luteal)
    }

    // MARK: - Luteal phase

    func testConfirmedShiftShadesLutealBeforeAndAfterToday() {
        let today = day(17)
        let overview = idealCycle(today: today)
        XCTAssertEqual(shading(overview, day(14), today: today), .luteal)      // past
        XCTAssertEqual(shading(overview, day(17), today: today), .luteal)      // today
        XCTAssertEqual(shading(overview, day(20), today: today), .luteal)      // future
        XCTAssertEqual(shading(overview, day(22), today: today), .luteal)      // last day before the prediction
    }

    func testProbableShiftDrawsNoLuteal() {
        // Three raw highs only: the rise is underway but unconfirmed, so those days stay fertile
        // or plain — the luteal phase is the *infertile* reading and must not be claimed early.
        let today = day(12)
        let overview = makeOverview(records(temps: biphasicTemps(highDays: 3)), today: today)
        guard case .probable = overview.analysis?.ovulation ?? .notDetected else {
            return XCTFail("expected probable, got \(String(describing: overview.analysis?.ovulation))")
        }
        XCTAssertEqual(shading(overview, day(10), today: today), .fertile)
        XCTAssertEqual(shading(overview, day(11), today: today), .none)
        XCTAssertEqual(shading(overview, day(12), today: today), .none)
    }

    func testCompletedCycleLutealRangeIsShaded() {
        // A closed 28-day cycle (biphasic, ovulation on index 9) followed by a fresh period on
        // day(28): the calendar keeps drawing the old cycle's luteal half in the month grid.
        let temps: [Double?] = Array(repeating: 36.0, count: 10)
            + Array(repeating: 36.5, count: 18)
            + Array(repeating: 36.0, count: 12)
        let today = day(35)
        let overview = makeOverview(records(temps: temps, periodDays: [1, 2, 3, 4, 29, 30, 31, 32]), today: today)
        let completed = overview.analysis!.completedCycles
        XCTAssertEqual(completed.map(\.lengthDays), [28])
        XCTAssertEqual(completed.first?.ovulationDayIndex, 9)

        XCTAssertEqual(shading(overview, day(9), today: today), .none)         // the estimate itself
        XCTAssertEqual(shading(overview, day(10), today: today), .luteal)
        XCTAssertEqual(shading(overview, day(27), today: today), .luteal)      // day before the next period
        XCTAssertEqual(shading(overview, day(28), today: today), .period)
    }

    // MARK: - Precedence

    func testLoggedPeriodWinsOverLuteal() {
        // The analyzer would open a new cycle on a flow day this late, so the fact is injected
        // straight into the overview: what is under test is the precedence rule, not the fixture.
        let today = day(17)
        var overview = idealCycle(today: today)
        XCTAssertEqual(shading(overview, day(16), today: today), .luteal)
        overview.loggedDays[CycleDay.key(for: day(16))] = CycleOverview.CycleDayFacts(
            isPeriod: true, isDisturbed: false, hasNote: false
        )
        XCTAssertEqual(shading(overview, day(16), today: today), .period)
    }

    // MARK: - No analysis

    func testWithoutAnalysisEveryDayIsPlain() {
        let today = day(17)
        let empty = CycleOverview(analysis: nil, chartDays: [], loggedDays: [:])
        XCTAssertEqual(shading(empty, day(0), today: today), .none)
        XCTAssertEqual(shading(empty, day(20), today: today), .none)
    }
}
