import XCTest
import SwiftData
@testable import PulseLoop

/// The data and accessibility layer behind the readiness detail screen: history fetching, the
/// missing-contributor list, and the trend chart's VoiceOver descriptor.
///
/// The chart descriptor is worth testing precisely because it's invisible — a broken
/// `AXChartDescriptor` looks perfect on screen and leaves the chart unusable with VoiceOver.
@MainActor
final class ReadinessDetailTests: XCTestCase {

    /// Sleep and HRV only — the other three kinds are deliberately absent.
    private static let partialContributors = #"""
    [{"kindRaw":"sleep","earned":30,"maxPoints":30,"value":92,"detail":"Sleep score 92"},
     {"kindRaw":"hrv","earned":24,"maxPoints":30,"value":47,"baseline":50,"deviation":-6,"detail":"HRV 6% below your baseline"}]
    """#

    private func point(_ dayOffset: Int, _ score: Int) -> ReadinessTrendPoint {
        ReadinessTrendPoint(
            date: TestSupport.day(dayOffset),
            score: score,
            band: ReadinessScore.band(score)
        )
    }

    @discardableResult
    private func insertScore(_ dayOffset: Int, score: Int, into context: ModelContext) -> ReadinessDaily {
        let row = ReadinessDaily(
            date: TestSupport.day(dayOffset),
            score: score,
            band: ReadinessScore.band(score),
            availablePoints: 100,
            contributorsJSON: "[]"
        )
        context.insert(row)
        try? context.save()
        return row
    }

    // MARK: - History fetching

    func testRowsAreReturnedOldestFirstForALeftToRightAxis() throws {
        let context = try TestSupport.makeContext()
        for offset in [0, -2, -5, -1] {
            insertScore(offset, score: 70 + abs(offset), into: context)
        }
        let rows = ReadinessRepository.rows(
            from: TestSupport.day(-6), to: TestSupport.day(0), context: context
        )
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.date), rows.map(\.date).sorted(), "chart axis needs ascending dates")
    }

    func testRowsRespectTheRequestedWindow() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 80, into: context)
        insertScore(-3, score: 70, into: context)
        insertScore(-40, score: 60, into: context)

        let week = ReadinessRepository.rows(
            from: TestSupport.day(-6), to: TestSupport.day(0), context: context
        )
        XCTAssertEqual(week.count, 2, "the 40-day-old score must not appear in a 7-day window")
    }

    func testLatestReturnsTheMostRecentlyScoredMorning() throws {
        let context = try TestSupport.makeContext()
        insertScore(-3, score: 61, into: context)
        insertScore(0, score: 92, into: context)
        insertScore(-1, score: 75, into: context)
        XCTAssertEqual(ReadinessRepository.latest(context: context)?.score, 92)
    }

    // MARK: - Missing contributors

    func testMissingKindsNamesEverySignalWithoutARow() throws {
        let context = try TestSupport.makeContext()
        let row = ReadinessDaily(
            date: TestSupport.day(0), score: 74, band: .ready, availablePoints: 60,
            contributorsJSON: Self.partialContributors
        )
        context.insert(row)
        try? context.save()

        let snapshot = ReadinessSnapshot(row)
        XCTAssertEqual(snapshot.missingKinds, [.restingHeartRate, .skinTemperature, .trainingLoad],
                       "missing kinds must be reported in canonical order")
    }

    func testMissingKindsIsEmptyOnAFullNight() throws {
        let context = try TestSupport.makeContext()
        let all = ReadinessContributor.Kind.allCases.map {
            #"{"kindRaw":"\#($0.rawValue)","earned":1,"maxPoints":1,"value":1,"detail":"x"}"#
        }.joined(separator: ",")
        let row = ReadinessDaily(
            date: TestSupport.day(0), score: 100, band: .primed, availablePoints: 100,
            contributorsJSON: "[\(all)]"
        )
        context.insert(row)
        try? context.save()
        XCTAssertTrue(ReadinessSnapshot(row).missingKinds.isEmpty)
    }

    // MARK: - Chart accessibility

    /// No other chart in this app exposes a descriptor. This one must, or the trend is opaque to
    /// VoiceOver — which for a screen whose whole purpose is explaining a number would be perverse.
    func testChartDescriptorExposesEveryDay() {
        let points = [point(-2, 91), point(-1, 62), point(0, 74)]
        let descriptor = ReadinessTrendChart(points: points).makeChartDescriptor()

        XCTAssertEqual(descriptor.title, "Readiness over time")
        let series = try? XCTUnwrap(descriptor.series.first)
        XCTAssertEqual(series?.dataPoints.count, 3, "every scored day must be reachable by the rotor")
        // Each point is labelled with its band, so the rotor speaks meaning and not just a number.
        XCTAssertEqual(series?.dataPoints.map(\.label), ["Primed", "Moderate", "Ready"])

        // The x axis carries one readable category per day, in chart order.
        let xAxis = descriptor.xAxis as? AXCategoricalDataAxisDescriptor
        XCTAssertEqual(xAxis?.categoryOrder.count, 3)
        for category in xAxis?.categoryOrder ?? [] {
            XCTAssertFalse(category.isEmpty, "each day needs a spoken label")
        }
    }

    func testChartDescriptorSummaryDescribesTheShape() {
        let points = [point(-2, 90), point(-1, 60), point(0, 75)]
        let summary = ReadinessTrendChart(points: points).makeChartDescriptor().summary
        XCTAssertEqual(summary, "3 scored days, averaging 75 out of 100, ranging from 60 to 90.")
    }

    func testChartDescriptorHandlesNoData() {
        let summary = ReadinessTrendChart(points: []).makeChartDescriptor().summary
        XCTAssertEqual(summary, "No readiness scores yet.")
    }

    func testChartYAxisIsPinnedToTheScoreRangeAndBandEdges() {
        let descriptor = ReadinessTrendChart(points: [point(0, 74)]).makeChartDescriptor()
        let yAxis = descriptor.yAxis as? AXNumericDataAxisDescriptor
        XCTAssertEqual(yAxis?.range, 0...100)
        XCTAssertEqual(yAxis?.gridlinePositions, [55, 70, 85], "gridlines should sit on the band edges")
    }

    /// The spoken value for a score must agree with the band the bar is drawn in.
    func testChartAxisValueDescriptionMatchesTheBand() {
        let descriptor = ReadinessTrendChart(points: [point(0, 74)]).makeChartDescriptor()
        let yAxis = try? XCTUnwrap(descriptor.yAxis as? AXNumericDataAxisDescriptor)
        XCTAssertEqual(yAxis?.valueDescriptionProvider(86), "86 out of 100, Primed")
        XCTAssertEqual(yAxis?.valueDescriptionProvider(74), "74 out of 100, Ready")
        XCTAssertEqual(yAxis?.valueDescriptionProvider(40), "40 out of 100, Rest needed")
    }

    /// Regression: the axis description closure is called by the framework with values we don't
    /// control. `Int(someDouble)` traps on infinity and NaN, so an unguarded conversion crashed the
    /// app outright — and only ever for VoiceOver users.
    func testChartAxisValueDescriptionSurvivesNonFiniteInput() {
        let descriptor = ReadinessTrendChart(points: [point(0, 74)]).makeChartDescriptor()
        let yAxis = try? XCTUnwrap(descriptor.yAxis as? AXNumericDataAxisDescriptor)
        for hostile: Double in [.infinity, -.infinity, .nan, .greatestFiniteMagnitude, -1, 1_000_000] {
            let spoken = yAxis?.valueDescriptionProvider(hostile)
            XCTAssertFalse(spoken?.isEmpty ?? true, "no spoken value for \(hostile)")
        }
    }

    // MARK: - Periods

    func testDetailPeriodsCoverTheIntendedWindows() {
        XCTAssertEqual(ReadinessDetailView.DetailPeriod.week.days, 7)
        XCTAssertEqual(ReadinessDetailView.DetailPeriod.month.days, 30)
        XCTAssertEqual(ReadinessDetailView.DetailPeriod.quarter.days, 90)
        XCTAssertEqual(ReadinessDetailView.DetailPeriod.allCases.count, 3)
    }
}
