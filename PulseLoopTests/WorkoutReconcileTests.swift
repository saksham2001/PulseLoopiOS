import XCTest
import SwiftData
@testable import PulseLoop

/// Post-workout ring-log reconcile: finished-session linking window, the history-vs-live gap-fill
/// rule, and `refreshSummary` idempotence (no daily-rollup double counting).
@MainActor
final class WorkoutReconcileTests: XCTestCase {

    private func finishedSession(startedAgo: TimeInterval, endedAgo: TimeInterval, context: ModelContext) -> ActivitySession {
        let session = ActivitySession(
            type: "run",
            status: .finished,
            startedAt: Date().addingTimeInterval(-startedAgo),
            endedAt: Date().addingTimeInterval(-endedAgo),
            useGps: false
        )
        context.insert(session)
        try? context.save()
        return session
    }

    func testHistorySampleLinksToRecentlyFinishedSession() throws {
        let context = try TestSupport.makeContext()
        let session = finishedSession(startedAgo: 1800, endedAgo: 300, context: context)

        let inWindow = ActivityRecorderService.linkSample(
            kind: .heartRate, value: 121, timestamp: Date().addingTimeInterval(-900),
            measurementId: UUID(), source: .history, confidence: .known, context: context
        )
        XCTAssertEqual(inWindow?.sessionId, session.id, "backfill sample inside the window attaches after finish")

        let outsideWindow = ActivityRecorderService.linkSample(
            kind: .heartRate, value: 118, timestamp: Date().addingTimeInterval(-3600),
            measurementId: UUID(), source: .history, confidence: .known, context: context
        )
        XCTAssertNil(outsideWindow, "samples before the session never attach")
    }

    func testStaleFinishedSessionDoesNotAttract() throws {
        let context = try TestSupport.makeContext()
        _ = finishedSession(startedAgo: 4000, endedAgo: 1200, context: context)

        let sample = ActivityRecorderService.linkSample(
            kind: .heartRate, value: 121, timestamp: Date().addingTimeInterval(-2000),
            measurementId: UUID(), source: .history, confidence: .known, context: context
        )
        XCTAssertNil(sample, "sessions finished beyond the backfill window are left alone")
    }

    func testGapFillSkipsHistoryNextToLiveSample() throws {
        let context = try TestSupport.makeContext()
        let session = finishedSession(startedAgo: 1800, endedAgo: 300, context: context)
        let liveAt = Date().addingTimeInterval(-900)
        context.insert(ActivitySample(
            sessionId: session.id, kind: MeasurementKind.heartRate.rawValue, value: 140,
            unit: "bpm", timestamp: liveAt, source: MeasurementSource.live.rawValue, confidence: .known
        ))
        try? context.save()

        let overlapping = ActivityRecorderService.linkSample(
            kind: .heartRate, value: 96, timestamp: liveAt.addingTimeInterval(100),
            measurementId: UUID(), source: .history, confidence: .known, context: context
        )
        XCTAssertNil(overlapping, "ring-log sample within ±150s of a live sample is overlap noise")

        let gapFilling = ActivityRecorderService.linkSample(
            kind: .heartRate, value: 96, timestamp: liveAt.addingTimeInterval(400),
            measurementId: UUID(), source: .history, confidence: .known, context: context
        )
        XCTAssertNotNil(gapFilling, "ring-log sample in a real gap fills it")
    }

    func testRefreshSummaryIsIdempotentAndNeverDoubleCountsDaily() throws {
        let context = try TestSupport.makeContext()
        let start = Date().addingTimeInterval(-3600)
        let end = Date().addingTimeInterval(-60)
        TestSupport.insertMeasurement(kind: .heartRate, value: 120, timestamp: start.addingTimeInterval(600), into: context)

        let session = ActivitySession(type: "run", status: .recording, startedAt: start, useGps: false)
        context.insert(session)
        _ = ActivityService.finishSummary(for: session, endedAt: end, context: context)
        try? context.save()

        let minutesAfterFinish = MetricsRepository.activity(on: start, context: context)?.activeMinutes
        XCTAssertEqual(minutesAfterFinish, 59, "finish credits the day exactly once")
        XCTAssertEqual(session.avgHeartRate, 120)

        // A late ring-log sample lands (well clear of the live one), then the summary refreshes twice.
        TestSupport.insertMeasurement(kind: .heartRate, value: 100, timestamp: start.addingTimeInterval(1800), source: .history, into: context)
        let first = ActivityService.refreshSummary(for: session, context: context)
        let second = ActivityService.refreshSummary(for: session, context: context)

        XCTAssertEqual(first.averageHeartRate, 110)
        XCTAssertEqual(second.averageHeartRate, first.averageHeartRate)
        XCTAssertEqual(second.heartRateSampleCount, 2, "no duplicate samples across refreshes")
        XCTAssertEqual(MetricsRepository.activity(on: start, context: context)?.activeMinutes, 59,
                       "refresh never re-credits the daily rollup")
    }
}
