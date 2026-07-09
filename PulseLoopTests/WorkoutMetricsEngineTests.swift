import XCTest
@testable import PulseLoop

/// Activity-specific calories: Keytel HR model when coverage + profile allow, MET fallback
/// otherwise, and the per-type metric sets.
final class WorkoutMetricsEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// One HR sample per minute for `minutes` minutes at a constant bpm.
    private func steadySamples(minutes: Int, bpm: Double) -> [(timestamp: Date, bpm: Double)] {
        (0..<minutes).map { (timestamp: start.addingTimeInterval(Double($0) * 60 + 1), bpm: bpm) }
    }

    func testKeytelMaleKnownValue() {
        // Keytel (male): (-55.0969 + 0.6309·140 + 0.1988·70 + 0.2017·30) / 4.184 ≈ 12.71 kcal/min.
        let kcal = WorkoutMetricsEngine.calories(
            type: "run", durationSeconds: 3600, distanceMeters: nil,
            hrSamples: steadySamples(minutes: 60, bpm: 140),
            profile: MetricsProfileValues(sex: "male", age: 30, weightKg: 70)
        )
        XCTAssertEqual(kcal, 762.9, accuracy: 2)
    }

    func testKeytelFemaleKnownValue() {
        // Keytel (female): (-20.4022 + 0.4472·150 − 0.1263·60 + 0.074·30) / 4.184 ≈ 9.88 kcal/min.
        let kcal = WorkoutMetricsEngine.calories(
            type: "run", durationSeconds: 1800, distanceMeters: nil,
            hrSamples: steadySamples(minutes: 30, bpm: 150),
            profile: MetricsProfileValues(sex: "female", age: 30, weightKg: 60)
        )
        XCTAssertEqual(kcal, 9.876 * 30, accuracy: 2)
    }

    func testLowCoverageFallsBackToMET() {
        // Only 10 of 60 minutes covered (< 60%) — MET path: run default 9.8 × 70 kg × 1 h = 686.
        let kcal = WorkoutMetricsEngine.calories(
            type: "run", durationSeconds: 3600, distanceMeters: nil,
            hrSamples: steadySamples(minutes: 10, bpm: 140),
            profile: MetricsProfileValues(sex: "male", age: 30, weightKg: 70)
        )
        XCTAssertEqual(kcal, 686, accuracy: 1)
    }

    func testMissingProfileUsesMETWithDefaultWeight() {
        // Gym 30 min, no profile: 5.0 MET × 70 kg default × 0.5 h = 175.
        let kcal = WorkoutMetricsEngine.calories(
            type: "gym", durationSeconds: 1800, distanceMeters: nil,
            hrSamples: steadySamples(minutes: 30, bpm: 130),
            profile: MetricsProfileValues()
        )
        XCTAssertEqual(kcal, 175, accuracy: 1)
    }

    func testSpeedTieredMETs() {
        XCTAssertEqual(WorkoutMetricsEngine.metValue(for: "cycle", averageSpeedMps: 3.0), 5.8)
        XCTAssertEqual(WorkoutMetricsEngine.metValue(for: "cycle", averageSpeedMps: 7.0), 10.0)
        XCTAssertEqual(WorkoutMetricsEngine.metValue(for: "run", averageSpeedMps: 2.0), 8.3)
        XCTAssertEqual(WorkoutMetricsEngine.metValue(for: "run", averageSpeedMps: 3.5), 12.3)
        XCTAssertEqual(WorkoutMetricsEngine.metValue(for: "yoga", averageSpeedMps: nil), 2.5)
    }

    func testMetricSetsPerType() {
        let cycle = ActivityMetricSet.set(for: "cycle")
        XCTAssertTrue(cycle.showsSpeed)
        XCTAssertFalse(cycle.showsPace)
        XCTAssertTrue(cycle.showsSplits)

        let run = ActivityMetricSet.set(for: "run")
        XCTAssertTrue(run.showsPace)
        XCTAssertFalse(run.showsSpeed)

        let gym = ActivityMetricSet.set(for: "gym")
        XCTAssertFalse(gym.showsDistance)
        XCTAssertFalse(gym.showsSplits)

        XCTAssertEqual(ActivityMetricSet.set(for: "cycling"), cycle, "legacy alias resolves to cycle")
    }
}
