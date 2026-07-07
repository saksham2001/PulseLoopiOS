import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class MetricsServiceTodayTests: XCTestCase {
    func testTodaySummaryWithSeededData() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 8200, calories: 410, distanceMeters: 6100, activeMinutes: 32, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 68, timestamp: Date(), into: context)
        TestSupport.insertMeasurement(kind: .spo2, value: 98, timestamp: Date(), into: context)

        let summary = MetricsService.buildTodaySummary(context: context)
        XCTAssertEqual(summary.steps, 8200)
        XCTAssertEqual(summary.latestHeartRate?.value, 68)
        XCTAssertEqual(summary.latestSpO2?.value, 98)
    }

    func testEmptyDatabaseStepsAreMissingNotZero() throws {
        let context = try TestSupport.makeContext()
        let summary = MetricsService.buildTodaySummary(context: context)
        XCTAssertNil(summary.steps, "absent data should be nil, not zero")
        XCTAssertNil(summary.latestHeartRate)
    }

    /// Today and Vitals must show the SAME 24h HR samples (same range/graph). Regression for the bug
    /// where a mixed real+mock database made Today treat HR as demo (full history, no window) while
    /// Vitals windowed it per-kind — producing different min/max. Both now go through `rangeSamples`.
    func testTodayAndVitalsHRSamplesMatchInMixedDatabase() throws {
        let context = try TestSupport.makeContext()
        // Real (live) HR: one recent (in the 24h window) with an extreme value, one 2 days ago with a
        // different extreme that must be EXCLUDED by the 24h window.
        TestSupport.insertMeasurement(kind: .heartRate, value: 62, timestamp: Date(), source: .live, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 95, timestamp: Date().addingTimeInterval(-3600), source: .live, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 150, timestamp: TestSupport.day(-2), source: .live, into: context)
        // A mock reading of a DIFFERENT kind flips the summary's global demo flag but not HR's per-kind one.
        TestSupport.insertMeasurement(kind: .stress, value: 30, timestamp: Date(), source: .mock, into: context)

        let todaySamples = MetricsService.buildTodaySummary(context: context).trends.hrSamples24h
        let vitalsSamples = MetricsService.metricRange(metric: .heartRate, range: .twentyFourHours, context: context)

        XCTAssertEqual(todaySamples.map(\.value), vitalsSamples.map(\.value), "Today and Vitals HR samples must match")
        // And the out-of-window 150 must be excluded from both → range max is 95, not 150.
        XCTAssertEqual(todaySamples.map(\.value).max(), 95, "the 2-day-old sample must be windowed out")
    }

    func testRealZeroIsDistinctFromMissing() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 0, into: context)
        let summary = MetricsService.buildTodaySummary(context: context)
        XCTAssertEqual(summary.steps, 0, "a real 0 row should read as 0")
        XCTAssertEqual(summary.metricStates[.steps]?.zeroIsReal, true)
    }

    func testStaleHeartRateHiddenFromToday() throws {
        let context = try TestSupport.makeContext()
        // Non-demo data: a sample from three days ago is stale and must not surface as "latest".
        TestSupport.insertActivity(date: Date(), steps: 5000, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: TestSupport.day(-3), into: context)
        let summary = MetricsService.buildTodaySummary(context: context)
        XCTAssertNil(summary.latestHeartRate)
    }

    func testCalibrationStartsAtDayOne() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 1000, source: "live", into: context)
        let summary = MetricsService.buildTodaySummary(context: context)
        XCTAssertTrue(summary.calibration.isCalibrating)
        XCTAssertEqual(summary.calibration.day, 1)
    }
}
