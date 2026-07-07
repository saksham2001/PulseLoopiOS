import XCTest
@testable import PulseLoop

/// Trend computation: direction from dense/sparse series and the HRV-vs-baseline path.
final class TrendSummaryTests: XCTestCase {

    private func samples(_ values: [Double], spacingMinutes: Double = 30) -> [ChartSample] {
        values.enumerated().map { index, value in
            ChartSample(timestamp: Date(timeIntervalSince1970: Double(index) * spacingMinutes * 60), value: value)
        }
    }

    func testInsufficientDataUnderThreeSamples() {
        let trend = TrendSummary.compute(samples: samples([70, 72]), metric: .heartRate)
        XCTAssertEqual(trend.direction, .insufficientData)
    }

    func testSparseRising() {
        // Three points, last > previous → rising.
        let trend = TrendSummary.compute(samples: samples([70, 71, 78]), metric: .heartRate, unitLabel: "bpm")
        XCTAssertEqual(trend.direction, .rising)
        XCTAssertNotNil(trend.deltaText)
    }

    func testSparseFalling() {
        let trend = TrendSummary.compute(samples: samples([80, 79, 70]), metric: .heartRate, unitLabel: "bpm")
        XCTAssertEqual(trend.direction, .falling)
    }

    func testStableWhenFlat() {
        let trend = TrendSummary.compute(samples: samples([70, 70, 70]), metric: .heartRate)
        XCTAssertEqual(trend.direction, .stable)
    }

    func testDenseComparesHalfWindows() {
        // 10 points: first half ~60, second half ~80 → rising via half-window means.
        let values = [60.0, 61, 59, 60, 62, 80, 81, 79, 82, 80]
        let trend = TrendSummary.compute(samples: samples(values), metric: .heartRate, unitLabel: "bpm")
        XCTAssertEqual(trend.direction, .rising)
    }

    func testHRVUsesBaseline() {
        let baseline = BaselineStats(mean: 50, median: 50, standardDeviation: 10, p25: 42, p75: 58,
                                     sampleCount: 50, spanDays: 14)
        // Latest value (42) is below the baseline mean → falling vs baseline.
        let trend = TrendSummary.compute(samples: samples([48, 45, 42]), metric: .hrv, baseline: baseline, unitLabel: "ms")
        XCTAssertEqual(trend.direction, .falling)
        XCTAssertEqual(trend.deltaText?.contains("baseline"), true)
    }
}
