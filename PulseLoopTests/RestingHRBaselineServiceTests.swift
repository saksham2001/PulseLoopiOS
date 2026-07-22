import XCTest
import SwiftData
@testable import PulseLoop

/// Tests for the resting-HR baseline learner that feeds the auto HR zone mode: the establishment
/// gate, the p10 computation, the 6-hour throttle, and the "only bump updatedAt on change" rule
/// that keeps the VitalsStore signature from churning.
@MainActor
final class RestingHRBaselineServiceTests: XCTestCase {

    private func makeProfile(in context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        context.insert(profile)
        try? context.save()
        return profile
    }

    /// Insert `count` HR samples spread evenly across `days` days, values cycling through `values`.
    private func insertHR(values: [Double], days: Double, now: Date, into context: ModelContext) {
        let step = days * 86_400 / Double(values.count)
        for (index, value) in values.enumerated() {
            TestSupport.insertMeasurement(
                kind: .heartRate, value: value,
                timestamp: now.addingTimeInterval(-days * 86_400 + Double(index) * step),
                into: context
            )
        }
    }

    func testTooFewSamplesLeavesBaselineNil() throws {
        let context = try TestSupport.makeContext()
        let profile = makeProfile(in: context)
        let now = Date()
        insertHR(values: Array(repeating: 65, count: 10), days: 10, now: now, into: context)

        RestingHRBaselineService.refreshIfStale(context: context, now: now)

        XCTAssertNil(profile.hrRestingBaseline)
        XCTAssertNotNil(profile.hrRestingBaselineUpdatedAt, "refresh time is stamped even when not established")
    }

    func testShortSpanLeavesBaselineNil() throws {
        let context = try TestSupport.makeContext()
        let profile = makeProfile(in: context)
        let now = Date()
        // Plenty of samples but only 2 days of wear — under the 7-day establishment gate.
        insertHR(values: Array(repeating: 65, count: 40), days: 2, now: now, into: context)

        RestingHRBaselineService.refreshIfStale(context: context, now: now)

        XCTAssertNil(profile.hrRestingBaseline)
    }

    func testEstablishedBaselineWritesP10AndBumpsUpdatedAt() throws {
        let context = try TestSupport.makeContext()
        let profile = makeProfile(in: context)
        let before = profile.updatedAt
        let now = Date()
        // 30 samples over 10 days: values 51...80 → p10 of 51...80 ≈ 53.9.
        insertHR(values: (51...80).map(Double.init), days: 10, now: now, into: context)

        RestingHRBaselineService.refreshIfStale(context: context, now: now)

        let baseline = try XCTUnwrap(profile.hrRestingBaseline)
        XCTAssertEqual(baseline, 53.9, accuracy: 0.11)
        XCTAssertGreaterThan(profile.updatedAt, before, "a new baseline must invalidate the vitals signature")
    }

    func testThrottleSkipsRecentRefresh() throws {
        let context = try TestSupport.makeContext()
        let profile = makeProfile(in: context)
        let now = Date()
        insertHR(values: (51...80).map(Double.init), days: 10, now: now, into: context)

        RestingHRBaselineService.refreshIfStale(context: context, now: now)
        let first = try XCTUnwrap(profile.hrRestingBaseline)

        // New, very different data lands — but within the 6h throttle window nothing recomputes.
        insertHR(values: Array(repeating: 100, count: 30), days: 5, now: now, into: context)
        RestingHRBaselineService.refreshIfStale(context: context, now: now.addingTimeInterval(3600))
        XCTAssertEqual(profile.hrRestingBaseline, first)

        // Past the throttle the same call does recompute.
        RestingHRBaselineService.refreshIfStale(context: context, now: now.addingTimeInterval(7 * 3600))
        XCTAssertNotEqual(profile.hrRestingBaseline, first)
    }

    func testUnchangedBaselineDoesNotBumpUpdatedAt() throws {
        let context = try TestSupport.makeContext()
        let profile = makeProfile(in: context)
        let now = Date()
        insertHR(values: (51...80).map(Double.init), days: 10, now: now, into: context)

        RestingHRBaselineService.refreshIfStale(context: context, now: now)
        let stamped = profile.updatedAt

        // Same data, past the throttle → same rounded baseline → updatedAt untouched.
        RestingHRBaselineService.refreshIfStale(context: context, now: now.addingTimeInterval(7 * 3600))
        XCTAssertEqual(profile.updatedAt, stamped, "an unchanged baseline must not churn the vitals signature")
    }
}
