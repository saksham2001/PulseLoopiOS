import XCTest
import SwiftData
@testable import PulseLoop

/// Post-finish editing (`ActivityService.applyEdit`): limited to type + time window, but every
/// derived value must follow — calories per the new type, samples re-sliced to the new window
/// (pulling all-day ring data on expansion), GPS distance windowed, and the daily rollup moved
/// without drift. Also covers the coach executor now routing through the same service.
@MainActor
final class ActivityEditTests: XCTestCase {

    @discardableResult
    private func makeFinished(
        type: String = "run",
        start: Date,
        end: Date,
        useGps: Bool = false,
        context: ModelContext
    ) -> ActivitySession {
        let session = ActivitySession(type: type, status: .recording, startedAt: start, useGps: useGps)
        context.insert(session)
        _ = ActivityService.finishSummary(for: session, endedAt: end, context: context)
        try? context.save()
        return session
    }

    func testTypeChangeRecomputesCalories() throws {
        let context = try TestSupport.makeContext()
        let start = Date().addingTimeInterval(-7200)
        let session = makeFinished(type: "run", start: start, end: start.addingTimeInterval(1800), context: context)
        // MET path, no profile: run 9.8 × 70 kg × 0.5 h.
        XCTAssertEqual(session.calories ?? 0, 343, accuracy: 1)

        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "yoga",
            newStartedAt: start, newEndedAt: start.addingTimeInterval(1800), context: context
        ))
        XCTAssertEqual(session.type, "yoga")
        XCTAssertEqual(session.calories ?? 0, 87.5, accuracy: 1, "calories follow the new type's MET")
    }

    func testWindowShrinkPrunesSamplesAndReexpandBackfills() throws {
        let context = try TestSupport.makeContext()
        let start = Date().addingTimeInterval(-7200)
        let end = start.addingTimeInterval(3600)
        TestSupport.insertMeasurement(kind: .heartRate, value: 100, timestamp: start.addingTimeInterval(300), into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 160, timestamp: start.addingTimeInterval(2700), into: context)
        let session = makeFinished(start: start, end: end, context: context)
        XCTAssertEqual(session.avgHeartRate ?? 0, 130, accuracy: 0.1)

        // Shrink to the first half: the 45-min sample is pruned and excluded from aggregates.
        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: start, newEndedAt: start.addingTimeInterval(1800), context: context
        ))
        XCTAssertEqual(session.avgHeartRate ?? 0, 100, accuracy: 0.1)
        XCTAssertEqual(ActivityRepository.samples(sessionId: session.id, context: context).count, 1)

        // Re-expand: the backfill re-links the pruned measurement from the all-day store.
        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: start, newEndedAt: end, context: context
        ))
        XCTAssertEqual(session.avgHeartRate ?? 0, 130, accuracy: 0.1)
        XCTAssertEqual(ActivityRepository.samples(sessionId: session.id, context: context).count, 2)
    }

    func testWindowExpandPullsRingLogData() throws {
        let context = try TestSupport.makeContext()
        let start = Date().addingTimeInterval(-7200)
        TestSupport.insertMeasurement(kind: .heartRate, value: 100, timestamp: start.addingTimeInterval(300), into: context)
        // All-day ring-log reading past the recorded end — the "regular ring data" case.
        TestSupport.insertMeasurement(kind: .heartRate, value: 150, timestamp: start.addingTimeInterval(4200), source: .history, into: context)
        let session = makeFinished(start: start, end: start.addingTimeInterval(3600), context: context)
        XCTAssertEqual(session.avgHeartRate ?? 0, 100, accuracy: 0.1)

        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: start, newEndedAt: start.addingTimeInterval(4800), context: context
        ))
        XCTAssertEqual(session.avgHeartRate ?? 0, 125, accuracy: 0.1, "extended window pulls the ring-log sample in")
    }

    func testDailyRollupMovesWithTheWindowWithoutDrift() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let yesterday10 = calendar.date(byAdding: .hour, value: 10, to: TestSupport.day(-1))!
        let twoDaysAgo10 = calendar.date(byAdding: .hour, value: 10, to: TestSupport.day(-2))!
        let session = makeFinished(start: yesterday10, end: yesterday10.addingTimeInterval(1800), context: context)
        XCTAssertEqual(MetricsRepository.activity(on: yesterday10, context: context)?.activeMinutes, 30)

        // Move the whole window one day back: yesterday debited, two-days-ago credited.
        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: twoDaysAgo10, newEndedAt: twoDaysAgo10.addingTimeInterval(1800), context: context
        ))
        XCTAssertEqual(MetricsRepository.activity(on: yesterday10, context: context)?.activeMinutes, 0)
        XCTAssertEqual(MetricsRepository.activity(on: twoDaysAgo10, context: context)?.activeMinutes, 30)

        // Identical edit again: reverse+credit must be a no-op net (no drift).
        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: twoDaysAgo10, newEndedAt: twoDaysAgo10.addingTimeInterval(1800), context: context
        ))
        XCTAssertEqual(MetricsRepository.activity(on: twoDaysAgo10, context: context)?.activeMinutes, 30)
    }

    func testGpsDistanceFollowsTheWindow() throws {
        let context = try TestSupport.makeContext()
        let start = Date().addingTimeInterval(-3600)
        let degPerMeter = 180.0 / (.pi * 6_371_000.0)
        let session = ActivitySession(type: "walk", status: .recording, startedAt: start, useGps: true)
        context.insert(session)
        // 21 points heading north: 10 m / 10 s apart → 200 m over 200 s.
        for i in 0..<21 {
            context.insert(ActivityGpsPoint(
                sessionId: session.id,
                latitude: 37.0 + Double(i) * 10 * degPerMeter,
                longitude: -122.0,
                timestamp: start.addingTimeInterval(Double(i) * 10)
            ))
        }
        _ = ActivityService.finishSummary(for: session, endedAt: start.addingTimeInterval(200), context: context)
        XCTAssertEqual(session.distanceMeters ?? 0, 200, accuracy: 2)

        // Halve the window: only the first 11 points count.
        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "walk",
            newStartedAt: start, newEndedAt: start.addingTimeInterval(100), context: context
        ))
        XCTAssertEqual(session.distanceMeters ?? 0, 100, accuracy: 2)

        // Restore: the excluded points come back (rows were never deleted).
        XCTAssertTrue(ActivityService.applyEdit(
            session: session, newType: "walk",
            newStartedAt: start, newEndedAt: start.addingTimeInterval(200), context: context
        ))
        XCTAssertEqual(session.distanceMeters ?? 0, 200, accuracy: 2)
    }

    func testInvalidEditsAreRejected() throws {
        let context = try TestSupport.makeContext()
        let start = Date().addingTimeInterval(-7200)
        let session = makeFinished(start: start, end: start.addingTimeInterval(1800), context: context)

        XCTAssertFalse(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: start, newEndedAt: Date().addingTimeInterval(600), context: context
        ), "future end time rejected")
        XCTAssertFalse(ActivityService.applyEdit(
            session: session, newType: "run",
            newStartedAt: start, newEndedAt: start, context: context
        ), "empty window rejected")
        XCTAssertEqual(session.endedAt, start.addingTimeInterval(1800), "session untouched by rejected edits")
    }

    func testCoachExecutorEditKeepsAggregatesConsistent() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let yesterday10 = calendar.date(byAdding: .hour, value: 10, to: TestSupport.day(-1))!
        let session = makeFinished(type: "run", start: yesterday10, end: yesterday10.addingTimeInterval(1800), context: context)
        XCTAssertEqual(MetricsRepository.activity(on: yesterday10, context: context)?.activeMinutes, 30)

        let action = PendingAction(
            kind: .updateActivitySession,
            activityId: session.id.uuidString,
            summary: "",
            confirmLabel: "",
            updates: ActivityUpdates(type: "yoga", notes: nil, distanceKm: nil, durationMin: 60, perceivedEffort: nil, startTime: nil)
        )
        _ = PendingActionExecutor.execute(action, context: context)

        XCTAssertEqual(session.type, "yoga")
        XCTAssertEqual(session.endedAt, yesterday10.addingTimeInterval(3600))
        // Previously the executor set fields directly and left all of these stale.
        XCTAssertEqual(session.calories ?? 0, 175, accuracy: 1, "yoga MET × 1 h recomputed")
        XCTAssertEqual(MetricsRepository.activity(on: yesterday10, context: context)?.activeMinutes, 60,
                       "daily rollup follows the new duration")
    }
}
