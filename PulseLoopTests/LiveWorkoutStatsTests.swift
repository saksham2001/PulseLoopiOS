import Foundation
import XCTest
@testable import PulseLoop

/// Rules for the live screen's rolling stats: ring-log HR only fills when live HR is absent or
/// stale, SpO₂ keeps the newest value, and seeding from persisted rows matches an event replay.
@MainActor
final class LiveWorkoutStatsTests: XCTestCase {
    private let sessionId = UUID()
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeStats() -> LiveWorkoutStats {
        LiveWorkoutStats(sessionId: sessionId, startedAt: start, activityType: "run", useGps: true, splitMeters: 1000)
    }

    func testLiveHRAlwaysWins() {
        let stats = makeStats()
        stats.recordHR(140, at: Date(), source: .live)
        XCTAssertEqual(stats.lastHR?.value, 140)
        stats.recordHR(150, at: Date(), source: .live)
        XCTAssertEqual(stats.lastHR?.value, 150)
    }

    func testRingLogFillsWhenNoLiveSample() {
        let stats = makeStats()
        stats.recordHR(88, at: Date().addingTimeInterval(-60), source: .ringLog)
        XCTAssertEqual(stats.lastHR?.value, 88)
        if case .ringLog = stats.lastHR!.source {} else { XCTFail("expected ringLog source") }
    }

    func testRingLogDoesNotOverwriteFreshLiveSample() {
        let stats = makeStats()
        stats.recordHR(150, at: Date(), source: .live)
        stats.recordHR(88, at: Date().addingTimeInterval(1), source: .ringLog)
        XCTAssertEqual(stats.lastHR?.value, 150, "coarse ring-log must not clobber a working stream")
    }

    func testRingLogReplacesStaleLiveSample() {
        let stats = makeStats()
        stats.recordHR(150, at: Date().addingTimeInterval(-300), source: .live)   // stream died 5 min ago
        stats.recordHR(96, at: Date().addingTimeInterval(-60), source: .ringLog)
        XCTAssertEqual(stats.lastHR?.value, 96)
    }

    func testRingLogIgnoresOlderSampleThanCurrent() {
        let stats = makeStats()
        stats.recordHR(96, at: Date().addingTimeInterval(-60), source: .ringLog)
        stats.recordHR(80, at: Date().addingTimeInterval(-600), source: .ringLog)
        XCTAssertEqual(stats.lastHR?.value, 96)
    }

    func testSpO2KeepsNewestValue() {
        let stats = makeStats()
        stats.recordSpO2(97, at: Date().addingTimeInterval(-30))
        stats.recordSpO2(95, at: Date().addingTimeInterval(-3600))
        XCTAssertEqual(stats.lastSpO2?.value, 97, "older ring-log value must not replace a newer one")
        stats.recordSpO2(98, at: Date())
        XCTAssertEqual(stats.lastSpO2?.value, 98)
    }

    func testSeedFromPersistedRowsMatchesEventReplay() {
        let degPerMeter = 180.0 / (.pi * 6_371_000.0)
        let points = (0..<50).map { i in
            ActivityGpsPoint(
                sessionId: sessionId,
                latitude: 37.0 + Double(i) * 10 * degPerMeter,
                longitude: -122.0,
                horizontalAccuracy: 5,
                timestamp: start.addingTimeInterval(Double(i) * 5),
                accepted: i % 10 != 9   // sprinkle rejected fixes; seeding must skip them
            )
        }

        let replayed = makeStats()
        for p in points where p.accepted {
            replayed.addFix(latitude: p.latitude, longitude: p.longitude,
                            horizontalAccuracy: p.horizontalAccuracy, timestamp: p.timestamp)
        }

        let seeded = makeStats()
        seeded.seed(points: points.shuffled(), lastHRSample: nil, lastSpO2Sample: nil)

        XCTAssertEqual(seeded.distanceMeters, replayed.distanceMeters, accuracy: 0.001)
        XCTAssertEqual(seeded.coordinates.count, replayed.coordinates.count)
        XCTAssertEqual(seeded.acceptedPointCount, replayed.acceptedPointCount)
        XCTAssertEqual(seeded.splits.completedSeconds, replayed.splits.completedSeconds)
    }

    func testSeedMapsSampleSources() {
        let stats = makeStats()
        let liveSample = ActivitySample(
            sessionId: sessionId, kind: "hr", value: 132, unit: "bpm",
            timestamp: start.addingTimeInterval(60), source: MeasurementSource.live.rawValue
        )
        let spo2Sample = ActivitySample(
            sessionId: sessionId, kind: "spo2", value: 97, unit: "%",
            timestamp: start.addingTimeInterval(30), source: MeasurementSource.history.rawValue
        )
        stats.seed(points: [], lastHRSample: liveSample, lastSpO2Sample: spo2Sample)
        XCTAssertEqual(stats.lastHR?.value, 132)
        if case .live = stats.lastHR!.source {} else { XCTFail("expected live source") }
        XCTAssertEqual(stats.lastSpO2?.value, 97)
    }

    func testPauseFlag() {
        let stats = makeStats()
        XCTAssertNil(stats.pausedAt)
        let pausedAt = Date()
        stats.setPaused(pausedAt)
        XCTAssertEqual(stats.pausedAt, pausedAt)
        stats.setPaused(nil)
        XCTAssertNil(stats.pausedAt)
    }
}
