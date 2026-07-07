import XCTest
@testable import PulseLoop

/// Pure-logic tests for the shared route distance/splits engine. Tracks are synthetic:
/// northbound latitude steps of known size (1° latitude ≈ 111.32 km everywhere).
final class RouteDistanceEngineTests: XCTestCase {
    private let sessionId = UUID()
    private let start = Date(timeIntervalSince1970: 1_750_000_000)
    /// Degrees of latitude per metre on the engine's sphere (R = 6 371 000 m), so northbound
    /// steps measure exactly their nominal length under the engine's haversine.
    private let degPerMeter = 180.0 / (.pi * 6_371_000.0)

    /// `count` accepted points heading due north, `stepMeters` apart, `stepSeconds` apart.
    private func track(count: Int, stepMeters: Double, stepSeconds: Double,
                       from origin: (lat: Double, lon: Double) = (37.0, -122.0),
                       startAt: Date? = nil, accepted: Bool = true) -> [ActivityGpsPoint] {
        let t0 = startAt ?? start
        return (0..<count).map { i in
            ActivityGpsPoint(
                sessionId: sessionId,
                latitude: origin.lat + Double(i) * stepMeters * degPerMeter,
                longitude: origin.lon,
                timestamp: t0.addingTimeInterval(Double(i) * stepSeconds),
                accepted: accepted
            )
        }
    }

    func testStraightKilometer() {
        // 101 points, 10 m apart, 5 s cadence (2 m/s walk).
        let points = track(count: 101, stepMeters: 10, stepSeconds: 5)
        let distance = RouteDistanceEngine.distanceMeters(points, profile: .profile(for: "walk"))
        XCTAssertEqual(distance, 1000, accuracy: 10)
    }

    func testRejectedPointsExcluded() {
        var points = track(count: 51, stepMeters: 10, stepSeconds: 5)
        // A burst of rejected jitter fixes mid-route must not add distance.
        let jitterStart = start.addingTimeInterval(1000)
        points += track(count: 20, stepMeters: 2, stepSeconds: 1, from: (37.1, -122.0), startAt: jitterStart, accepted: false)
        let distance = RouteDistanceEngine.distanceMeters(points, profile: .profile(for: "walk"))
        XCTAssertEqual(distance, 500, accuracy: 5)
    }

    func testPauseTeleportIsNotCounted() {
        // Walk 200 m, pause 10 minutes while moving 2 km away (drive), walk 200 m more.
        let leg1 = track(count: 21, stepMeters: 10, stepSeconds: 5)
        let resumeAt = leg1.last!.timestamp.addingTimeInterval(600)
        let leg2 = track(count: 21, stepMeters: 10, stepSeconds: 5, from: (37.0 + 2000 * degPerMeter, -122.0), startAt: resumeAt)
        let distance = RouteDistanceEngine.distanceMeters(leg1 + leg2, profile: .profile(for: "walk"))
        // The 2 km teleport spans 600 s (3.3 m/s — plausible walking speed!), so only the gap
        // rule can catch it.
        XCTAssertEqual(distance, 400, accuracy: 5)
    }

    func testSpeedSpikeDropped() {
        var points = track(count: 21, stepMeters: 10, stepSeconds: 5)
        // One glitch fix 300 m off-route 2 s after the last point (150 m/s), then back on route.
        let last = points.last!
        points.append(ActivityGpsPoint(
            sessionId: sessionId,
            latitude: last.latitude + 300 * degPerMeter,
            longitude: last.longitude,
            timestamp: last.timestamp.addingTimeInterval(2)
        ))
        points.append(ActivityGpsPoint(
            sessionId: sessionId,
            latitude: last.latitude + 10 * degPerMeter,
            longitude: last.longitude,
            timestamp: last.timestamp.addingTimeInterval(7)
        ))
        let distance = RouteDistanceEngine.distanceMeters(points, profile: .profile(for: "walk"))
        // Both the 300 m outbound (150 m/s) and 290 m return (58 m/s) segments are dropped.
        XCTAssertEqual(distance, 200, accuracy: 5)
    }

    func testUnsortedInputMatchesSorted() {
        let points = track(count: 51, stepMeters: 10, stepSeconds: 5)
        let profile = ActivityTrackingProfile.profile(for: "run")
        XCTAssertEqual(
            RouteDistanceEngine.distanceMeters(points.shuffled(), profile: profile),
            RouteDistanceEngine.distanceMeters(points, profile: profile),
            accuracy: 0.001
        )
    }

    func testSplitsUseMovingTimeAcrossGap() {
        // 1.04 km at 2 m/s, a 5-minute pause in place, then 1.04 km at 2 m/s: two completed
        // 1 km splits with the same *moving* time; the pause contributes neither time nor
        // distance. Legs overshoot the split mark so float rounding can't miss a completion.
        let leg1 = track(count: 105, stepMeters: 10, stepSeconds: 5)
        let resumeAt = leg1.last!.timestamp.addingTimeInterval(300)
        let leg2 = track(count: 105, stepMeters: 10, stepSeconds: 5, from: (37.0 + 1040 * degPerMeter, -122.0), startAt: resumeAt)
        let splits = RouteDistanceEngine.splits(leg1 + leg2, splitMeters: 1000, profile: .profile(for: "walk"))
        XCTAssertEqual(splits.completedSeconds.count, 2)
        XCTAssertEqual(splits.completedSeconds[0], 500, accuracy: 15)
        XCTAssertEqual(splits.completedSeconds[1], 500, accuracy: 15)
        XCTAssertEqual(splits.partialMeters, 80, accuracy: 15)
    }

    func testProfileLookupFallsBackToDefault() {
        XCTAssertEqual(ActivityTrackingProfile.profile(for: "gym"), .default)
        XCTAssertEqual(ActivityTrackingProfile.profile(for: "cycling").maxSpeedMps, 25, "legacy alias resolves to cycle")
        XCTAssertNotEqual(ActivityTrackingProfile.profile(for: "cycle"), ActivityTrackingProfile.profile(for: "run"))
    }

    // MARK: - Incremental accumulator (live screen) must match the batch engine exactly

    /// Feed points one-by-one and assert distance + splits equal the batch computation.
    private func assertAccumulatorMatchesBatch(_ points: [ActivityGpsPoint], profile: ActivityTrackingProfile,
                                               splitMeters: Double = 1000, file: StaticString = #filePath, line: UInt = #line) {
        var acc = RouteDistanceEngine.Accumulator(profile: profile, splitMeters: splitMeters)
        for p in points.filter(\.accepted).sorted(by: { $0.timestamp < $1.timestamp }) {
            acc.add(latitude: p.latitude, longitude: p.longitude, timestamp: p.timestamp)
        }
        let batchDistance = RouteDistanceEngine.distanceMeters(points, profile: profile)
        let batchSplits = RouteDistanceEngine.splits(points, splitMeters: splitMeters, profile: profile)
        XCTAssertEqual(acc.distanceMeters, batchDistance, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(acc.splits.completedSeconds.count, batchSplits.completedSeconds.count, file: file, line: line)
        for (a, b) in zip(acc.splits.completedSeconds, batchSplits.completedSeconds) {
            XCTAssertEqual(a, b, accuracy: 0.001, file: file, line: line)
        }
        XCTAssertEqual(acc.splits.partialMeters, batchSplits.partialMeters, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(acc.splits.partialSeconds, batchSplits.partialSeconds, accuracy: 0.001, file: file, line: line)
    }

    func testAccumulatorMatchesBatchStraightRoute() {
        assertAccumulatorMatchesBatch(track(count: 250, stepMeters: 10, stepSeconds: 5), profile: .profile(for: "walk"))
    }

    func testAccumulatorMatchesBatchAcrossGap() {
        let leg1 = track(count: 105, stepMeters: 10, stepSeconds: 5)
        let resumeAt = leg1.last!.timestamp.addingTimeInterval(300)
        let leg2 = track(count: 105, stepMeters: 10, stepSeconds: 5, from: (37.0 + 1040 * degPerMeter, -122.0), startAt: resumeAt)
        assertAccumulatorMatchesBatch(leg1 + leg2, profile: .profile(for: "walk"))
    }

    func testAccumulatorMatchesBatchWithSpeedSpike() {
        var points = track(count: 21, stepMeters: 10, stepSeconds: 5)
        let last = points.last!
        points.append(ActivityGpsPoint(
            sessionId: sessionId,
            latitude: last.latitude + 300 * degPerMeter,
            longitude: last.longitude,
            timestamp: last.timestamp.addingTimeInterval(2)
        ))
        points.append(ActivityGpsPoint(
            sessionId: sessionId,
            latitude: last.latitude + 10 * degPerMeter,
            longitude: last.longitude,
            timestamp: last.timestamp.addingTimeInterval(7)
        ))
        assertAccumulatorMatchesBatch(points, profile: .profile(for: "walk"))
    }

    func testAccumulatorSkipsOutOfOrderFix() {
        let points = track(count: 20, stepMeters: 10, stepSeconds: 5)
        var acc = RouteDistanceEngine.Accumulator(profile: .profile(for: "walk"), splitMeters: 1000)
        for p in points {
            acc.add(latitude: p.latitude, longitude: p.longitude, timestamp: p.timestamp)
        }
        let before = acc.distanceMeters
        // A stale fix older than the last one must be ignored, not subtract/teleport.
        acc.add(latitude: 37.0, longitude: -122.0, timestamp: start.addingTimeInterval(-10))
        XCTAssertEqual(acc.distanceMeters, before, accuracy: 0.001)
    }

    func testAccumulatorSeedMatchesIncrementalFeed() {
        let points = track(count: 100, stepMeters: 10, stepSeconds: 5)
        var incremental = RouteDistanceEngine.Accumulator(profile: .profile(for: "run"), splitMeters: 1000)
        for p in points {
            incremental.add(latitude: p.latitude, longitude: p.longitude, timestamp: p.timestamp)
        }
        var seeded = RouteDistanceEngine.Accumulator(profile: .profile(for: "run"), splitMeters: 1000)
        seeded.seed(points.shuffled())   // seed sorts + filters internally
        XCTAssertEqual(seeded.distanceMeters, incremental.distanceMeters, accuracy: 0.001)
        XCTAssertEqual(seeded.splits.completedSeconds, incremental.splits.completedSeconds)
    }
}
