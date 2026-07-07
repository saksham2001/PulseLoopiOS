import XCTest
@testable import PulseLoop

/// Locks the timestamp-based charting: gap-breaking and the timestamp-not-index regression guard.
final class ChartSampleSegmentTests: XCTestCase {

    private func sample(_ minutesFromNow: Double, _ value: Double) -> ChartSample {
        ChartSample(timestamp: Date(timeIntervalSince1970: minutesFromNow * 60), value: value)
    }

    func testGapBreaksAcrossLargeGap() {
        // Two readings 5 min apart, then a 6h jump, then two more 5 min apart.
        let samples = [
            sample(0, 70), sample(5, 72),
            sample(365, 68), sample(370, 69),   // 360 min == 6h after the previous
        ]
        let maxGap = ChartSampleBuilder.maxGap(for: .twentyFourHours)   // 90 min
        let segments = ChartSampleBuilder.segments(samples, maxGap: maxGap)
        XCTAssertEqual(segments.count, 2, "the 6h gap must split the line into two segments")
        XCTAssertEqual(segments[0].count, 2)
        XCTAssertEqual(segments[1].count, 2)
    }

    func testNoBreakWithinTolerance() {
        // Three readings 30 min apart stay one continuous segment at 24h tolerance.
        let samples = [sample(0, 70), sample(30, 71), sample(60, 72)]
        let segments = ChartSampleBuilder.segments(samples, maxGap: ChartSampleBuilder.maxGap(for: .twentyFourHours))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 3)
    }

    func testSingleSampleIsOneSegment() {
        let segments = ChartSampleBuilder.segments([sample(0, 70)], maxGap: 90 * 60)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 1)
    }

    func testEmptyProducesNoSegments() {
        XCTAssertTrue(ChartSampleBuilder.segments([], maxGap: 90 * 60).isEmpty)
    }

    func testMaxGapPerRange() {
        XCTAssertEqual(ChartSampleBuilder.maxGap(for: .twentyFourHours), 90 * 60)
        XCTAssertEqual(ChartSampleBuilder.maxGap(for: .sevenDays), 36 * 3600)
        XCTAssertEqual(ChartSampleBuilder.maxGap(for: .thirtyDays), 4 * 86_400)
    }

    /// The core correctness guard: charting must be driven by timestamps, not array index. Two samples
    /// 8 hours apart must map to x-positions 8h apart in the time domain — not "one index apart".
    func testChartUsesTimestampSpacingNotIndex() {
        let early = sample(0, 70)
        let late = sample(480, 90)   // 8 hours later
        let chart = ChartSampleBuilder.from([
            MetricSample(timestamp: early.timestamp, value: early.value),
            MetricSample(timestamp: late.timestamp, value: late.value),
        ])
        XCTAssertEqual(chart.count, 2)
        // The x-values are real Dates whose spacing is 8h, not a unit index step.
        let spacing = chart[1].timestamp.timeIntervalSince(chart[0].timestamp)
        XCTAssertEqual(spacing, 8 * 3600, accuracy: 1, "timestamp spacing must reflect real time, not index")
        // And they're ordered ascending in time.
        XCTAssertLessThan(chart[0].timestamp, chart[1].timestamp)
    }

    func testFromSortsByTimestamp() {
        let out = ChartSampleBuilder.from([
            MetricSample(timestamp: Date(timeIntervalSince1970: 100), value: 2),
            MetricSample(timestamp: Date(timeIntervalSince1970: 50), value: 1),
        ])
        XCTAssertEqual(out.map(\.value), [1, 2], "samples must be time-sorted")
    }

    // MARK: - Zone-boundary line splitting

    private func point(_ t: Double, _ v: Double) -> LinePoint {
        LinePoint(time: Date(timeIntervalSince1970: t), value: v)
    }

    func testSplitAcrossSingleThreshold() {
        // 35 → 44 across a 38 threshold splits into two pieces, crossing interpolated at 38.
        let pieces = ZoneLineSplitter.split(point(0, 35), point(100, 44), thresholds: [38])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].0.value, 35)
        XCTAssertEqual(pieces[0].1.value, 38, accuracy: 0.0001)
        XCTAssertEqual(pieces[1].0.value, 38, accuracy: 0.0001)
        XCTAssertEqual(pieces[1].1.value, 44)
        // Crossing time interpolated: (38-35)/(44-35) = 3/9 of the way → t ≈ 33.3s.
        XCTAssertEqual(pieces[0].1.time.timeIntervalSince1970, 100.0 * 3.0 / 9.0, accuracy: 0.001)
    }

    func testWithinZonePairIsOnePiece() {
        let pieces = ZoneLineSplitter.split(point(0, 40), point(100, 41), thresholds: [38, 42, 46])
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].0.value, 40)
        XCTAssertEqual(pieces[0].1.value, 41)
    }

    func testTwoThresholdsYieldThreePieces() {
        // 35 → 50 crossing 38 and 42 → three pieces in order.
        let pieces = ZoneLineSplitter.split(point(0, 35), point(100, 50), thresholds: [38, 42])
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map { $0.1.value }, [38, 42, 50], "split points ascend to the endpoint")
    }

    func testDescendingSegmentSplitsInOrder() {
        // Falling line 50 → 35 crosses the same thresholds, split from high to low.
        let pieces = ZoneLineSplitter.split(point(0, 50), point(100, 35), thresholds: [38, 42])
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map { $0.1.value }, [42, 38, 35], "splits descend along the segment")
    }

    func testThresholdsAtEndpointsAreNotSplit() {
        // A threshold exactly at an endpoint value should not create a zero-length piece.
        let pieces = ZoneLineSplitter.split(point(0, 38), point(100, 44), thresholds: [38])
        XCTAssertEqual(pieces.count, 1)
    }

    // MARK: - Value-space splitter (activity charts, x = minutes)

    func testValueSpaceSplitAcrossHRThreshold() {
        // Activity HR 95→110 over minutes 0→10 crossing the 101 zone boundary → two pieces split at 101.
        let pieces = ZoneLineSplitter.split(x0: 0, v0: 95, x1: 10, v1: 110, thresholds: [101])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].0.value, 95)
        XCTAssertEqual(pieces[0].1.value, 101, accuracy: 0.0001)
        XCTAssertEqual(pieces[1].1.value, 110)
        // x interpolated at the crossing: (101-95)/(110-95) = 6/15 = 0.4 → minute 4.0.
        XCTAssertEqual(pieces[0].1.x, 4.0, accuracy: 0.0001, "crossing x is interpolated in minutes")
    }

    func testValueSpaceWithinZoneIsOnePiece() {
        let pieces = ZoneLineSplitter.split(x0: 0, v0: 70, x1: 5, v1: 80, thresholds: [101, 120])
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].0.x, 0)
        XCTAssertEqual(pieces[0].1.x, 5)
    }

    func testValueAndDateSplittersAgree() {
        // The Date overload delegates to the value-space core → same value splits.
        let dateP = ZoneLineSplitter.split(point(0, 95), point(10, 110), thresholds: [101]).map { $0.1.value }
        let valueP = ZoneLineSplitter.split(x0: 0, v0: 95, x1: 10, v1: 110, thresholds: [101]).map { $0.1.value }
        XCTAssertEqual(dateP, valueP)
    }

    /// Elapsed-minutes mapping used by the activity chart: a sample N minutes after start → x = N.
    func testElapsedMinutesMapping() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let sample = start.addingTimeInterval(8 * 60)   // 8 minutes later
        let minutes = sample.timeIntervalSince(start) / 60
        XCTAssertEqual(minutes, 8.0, accuracy: 0.0001)
    }
}
