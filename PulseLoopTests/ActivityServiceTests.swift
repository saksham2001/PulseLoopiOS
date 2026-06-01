import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class ActivityServiceTests: XCTestCase {
    func testRatchetOnlyIncreases() throws {
        let context = try TestSupport.makeContext()
        let date = Date()
        ActivityService.applyActivityUpdate(ActivityDailyUpdate(date: date, steps: 5000, source: "live"), context: context)
        ActivityService.applyActivityUpdate(ActivityDailyUpdate(date: date, steps: 3000, source: "live"), context: context) // stale/lower
        ActivityService.applyActivityUpdate(ActivityDailyUpdate(date: date, steps: 6000, source: "live"), context: context)
        let row = MetricsRepository.activity(on: date, context: context)
        XCTAssertEqual(row?.steps, 6000, "counters only ratchet upward")
    }

    func testHRActiveMinutesLiveDense() throws {
        let context = try TestSupport.makeContext()
        // 6 dense live samples in one minute, all above the active threshold (>=100 bpm floor).
        let base = Calendar.current.date(bySettingHour: 10, minute: 5, second: 0, of: Date()) ?? Date()
        for index in 0..<6 {
            TestSupport.insertMeasurement(kind: .heartRate, value: 140, timestamp: base.addingTimeInterval(Double(index)), source: .live, into: context)
        }
        let result = ActivityService.computeActiveMinutes(for: Date(), context: context)
        XCTAssertEqual(result.source, "hr_live")
        XCTAssertGreaterThan(result.minutes, 0)
    }

    func testHRActiveMinutesBucketCredit() throws {
        let context = try TestSupport.makeContext()
        // Sparse (below live density) but high mean → 30-minute bucket credit.
        let base = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        TestSupport.insertMeasurement(kind: .heartRate, value: 150, timestamp: base, source: .live, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 150, timestamp: base.addingTimeInterval(60), source: .live, into: context)
        let result = ActivityService.computeActiveMinutes(for: Date(), context: context)
        XCTAssertEqual(result.source, "hr_buckets")
        XCTAssertEqual(result.minutes, 30)
    }

    func testHRActiveMinutesBelowThresholdIsZero() throws {
        let context = try TestSupport.makeContext()
        let base = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        TestSupport.insertMeasurement(kind: .heartRate, value: 62, timestamp: base, source: .live, into: context)
        let result = ActivityService.computeActiveMinutes(for: Date(), context: context)
        XCTAssertEqual(result.minutes, 0)
    }

    func testWorkoutFinishSummary() throws {
        let context = try TestSupport.makeContext()
        let session = ActivityRecorderService.start(type: "outdoor_run", useGps: false, notes: nil, context: context)
        // Sensor samples within the session window get backfilled at finish.
        let t0 = session.startedAt.addingTimeInterval(30)
        TestSupport.insertMeasurement(kind: .heartRate, value: 120, timestamp: t0, source: .live, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 160, timestamp: t0.addingTimeInterval(10), source: .live, into: context)
        TestSupport.insertMeasurement(kind: .spo2, value: 97, timestamp: t0.addingTimeInterval(20), source: .live, into: context)

        let endedAt = session.startedAt.addingTimeInterval(20 * 60)
        let summary = ActivityService.finishSummary(for: session, endedAt: endedAt, context: context)
        XCTAssertEqual(summary.minHeartRate, 120)
        XCTAssertEqual(summary.maxHeartRate, 160)
        XCTAssertEqual(summary.averageHeartRate, 140)
        XCTAssertEqual(summary.latestSpO2, 97)
        XCTAssertEqual(summary.durationSeconds, 20 * 60)
        XCTAssertEqual(session.status, .finished)
    }
}
