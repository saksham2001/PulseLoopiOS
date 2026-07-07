import XCTest
@testable import PulseLoop

/// Boundary tests for the medical reference-range engine. These lock the exact thresholds so a future
/// refactor can't silently shift a category. Pure logic — no store/hardware IO.
@MainActor
final class VitalsThresholdEngineTests: XCTestCase {

    private let base = UserPhysiologyProfile.unknown

    private func athlete() -> UserPhysiologyProfile {
        UserPhysiologyProfile(age: 30, sex: .male, athleteMode: true, altitudeMeters: nil,
                              usesBetaBlockers: false, hasKnownLungCondition: false, preferredGlucoseUnit: .mgdl)
    }

    private func betaBlocker() -> UserPhysiologyProfile {
        UserPhysiologyProfile(age: 60, sex: .female, athleteMode: false, altitudeMeters: nil,
                              usesBetaBlockers: true, hasKnownLungCondition: false, preferredGlucoseUnit: .mgdl)
    }

    private func severity(_ value: Double, _ metric: MetricKind, _ profile: UserPhysiologyProfile,
                          context: MetricContext = MetricContext(), baseline: BaselineStats? = nil) -> ZoneSeverity {
        VitalsThresholdEngine.interpret(value: value, metric: metric, profile: profile,
                                        context: context, baseline: baseline).primaryZone.severity
    }

    // MARK: - Heart rate

    func testHeartRateBoundaries() {
        XCTAssertEqual(severity(59, .heartRate, base), .watch, "59 is below the 60 normal floor")
        XCTAssertEqual(severity(60, .heartRate, base), .normal)
        XCTAssertEqual(severity(100, .heartRate, base), .normal)
        XCTAssertEqual(severity(101, .heartRate, base), .watch, "101 is above the 100 normal ceiling")
    }

    func testAthleteLowHeartRateIsOptimal() {
        XCTAssertEqual(severity(48, .heartRate, athlete()), .optimal, "athletes' low resting HR is fine")
    }

    func testBetaBlockerLowHeartRateNotAlarming() {
        // 50 bpm on a beta-blocker should read as expected/normal, not a watch/concern.
        XCTAssertEqual(severity(50, .heartRate, betaBlocker()), .normal)
    }

    // MARK: - SpO₂

    func testSpO2Boundaries() {
        XCTAssertEqual(severity(100, .spo2, base), .normal)
        XCTAssertEqual(severity(95, .spo2, base), .normal)
        XCTAssertEqual(severity(94, .spo2, base), .watch)
        XCTAssertEqual(severity(92, .spo2, base), .high)
        XCTAssertEqual(severity(88, .spo2, base), .critical)
        XCTAssertEqual(severity(87, .spo2, base), .critical)
    }

    // MARK: - Blood pressure (worse-of-two)

    private func bpSeverity(_ sys: Double, _ dia: Double) -> ZoneSeverity {
        VitalsThresholdEngine.interpretBloodPressure(systolic: sys, diastolic: dia, profile: base).primaryZone.severity
    }

    func testBloodPressureCategories() {
        XCTAssertEqual(bpSeverity(119, 79), .normal)
        XCTAssertEqual(bpSeverity(122, 78), .watch, "120–129/<80 is Elevated")
        XCTAssertEqual(bpSeverity(130, 78), .high, "systolic 130 → Stage 1")
        XCTAssertEqual(bpSeverity(118, 85), .high, "diastolic 85 → Stage 1 even with normal systolic")
        XCTAssertEqual(bpSeverity(142, 91), .high, "Stage 2")
        XCTAssertEqual(bpSeverity(181, 100), .critical, "systolic >180 → severe")
        XCTAssertEqual(bpSeverity(88, 58), .watch, "low BP")
    }

    func testBloodPressureIsEstimated() {
        XCTAssertTrue(VitalsThresholdEngine.interpretBloodPressure(systolic: 120, diastolic: 80, profile: base).isEstimated)
    }

    // MARK: - Glucose

    private func glucoseLabel(_ value: Double, _ context: MeasurementContext) -> String {
        VitalsThresholdEngine.interpret(value: value, metric: .glucose, profile: base,
                                        context: MetricContext(measurement: context)).displayLabel
    }

    private func glucoseSeverity(_ value: Double, _ context: MeasurementContext) -> ZoneSeverity {
        severity(value, .glucose, base, context: MetricContext(measurement: context))
    }

    func testFastingGlucoseBoundaries() {
        XCTAssertEqual(glucoseSeverity(69, .fasting), .high, "below 70 is low")
        XCTAssertEqual(glucoseSeverity(70, .fasting), .normal)
        XCTAssertEqual(glucoseSeverity(99, .fasting), .normal)
        XCTAssertEqual(glucoseSeverity(100, .fasting), .watch)
        XCTAssertEqual(glucoseSeverity(126, .fasting), .high)
    }

    func testRandomGlucoseBoundaries() {
        XCTAssertEqual(glucoseSeverity(199, .random), .watch)
        XCTAssertEqual(glucoseSeverity(200, .random), .high)
    }

    func testUnknownGlucoseContextNeverSaysPrediabetes() {
        for value in stride(from: 60.0, through: 260.0, by: 5) {
            let label = glucoseLabel(value, .unknown).lowercased()
            XCTAssertFalse(label.contains("prediabetes"), "unknown context must stay conservative (value \(value))")
            XCTAssertFalse(label.contains("diabetes"), "unknown context must stay conservative (value \(value))")
        }
    }

    func testGlucoseAlwaysEstimated() {
        let interp = VitalsThresholdEngine.interpret(value: 100, metric: .glucose, profile: base,
                                                     context: MetricContext(measurement: .unknown))
        XCTAssertTrue(interp.isEstimated)
    }

    // MARK: - HRV (baseline-relative)

    private func makeBaseline(mean: Double, sd: Double, established: Bool) -> BaselineStats {
        BaselineStats(mean: mean, median: mean, standardDeviation: sd, p25: mean - sd, p75: mean + sd,
                      sampleCount: established ? 50 : 3, spanDays: established ? 14 : 1)
    }

    func testHRVNoBaselineIsBuilding() {
        let interp = VitalsThresholdEngine.interpret(value: 45, metric: .hrv, profile: base, baseline: nil)
        XCTAssertEqual(interp.primaryZone.severity, .unknown)
        XCTAssertEqual(interp.confidenceLabel, "Building baseline")
    }

    func testHRVUnestablishedBaselineIsBuilding() {
        let baseline = makeBaseline(mean: 50, sd: 10, established: false)
        let interp = VitalsThresholdEngine.interpret(value: 50, metric: .hrv, profile: base, baseline: baseline)
        XCTAssertEqual(interp.primaryZone.severity, .unknown)
    }

    func testHRVNearBaseline() {
        let baseline = makeBaseline(mean: 50, sd: 10, established: true)
        // Within ±0.5 sd of mean → near baseline (normal).
        XCTAssertEqual(severity(50, .hrv, base, baseline: baseline), .normal)
    }

    func testHRVWellBelowBaseline() {
        let baseline = makeBaseline(mean: 50, sd: 10, established: true)
        // 20% below mean (40) is more than 1 sd below (mean - sd = 40 boundary) → below baseline.
        XCTAssertEqual(severity(38, .hrv, base, baseline: baseline), .high)
    }

    func testHRVAboveBaseline() {
        let baseline = makeBaseline(mean: 50, sd: 10, established: true)
        // 15% above mean (57.5) is more than 0.5 sd above (55) → above baseline (optimal).
        XCTAssertEqual(severity(57.5, .hrv, base, baseline: baseline), .optimal)
    }

    // MARK: - Stress / Fatigue

    func testStressBoundaries() {
        XCTAssertEqual(severity(25, .stress, base), .optimal)
        XCTAssertEqual(severity(26, .stress, base), .normal)
        XCTAssertEqual(severity(51, .stress, base), .watch)
        XCTAssertEqual(severity(76, .stress, base), .high)
    }

    func testFatigueBoundaries() {
        XCTAssertEqual(severity(24, .fatigue, base), .optimal)
        XCTAssertEqual(severity(25, .fatigue, base), .normal)
        XCTAssertEqual(severity(50, .fatigue, base), .watch)
        XCTAssertEqual(severity(75, .fatigue, base), .high)
    }

    // MARK: - Per-zone color palette

    /// The colorToken the engine assigns to the zone a value lands in.
    private func token(_ value: Double, _ metric: MetricKind, baseline: BaselineStats? = nil) -> VitalColorToken {
        VitalsThresholdEngine.colorToken(forValue: value, metric: metric, profile: base, baseline: baseline)
    }

    func testHeartRateZoneColors() {
        XCTAssertEqual(token(45, .heartRate), .blue)                       // low
        XCTAssertEqual(token(72, .heartRate), .metricAccent(.heartRate))   // normal = pink accent
        XCTAssertEqual(token(110, .heartRate), .amber)                     // elevated
        XCTAssertEqual(token(130, .heartRate), .brightRed)                 // high (deeper red; accent is already reddish)
    }

    func testSpO2ZoneColors() {
        XCTAssertEqual(token(98, .spo2), .cyan)     // normal
        XCTAssertEqual(token(94, .spo2), .amber)    // slightly low
        XCTAssertEqual(token(91, .spo2), .orange)   // low
        XCTAssertEqual(token(86, .spo2), .red)      // very low
    }

    func testHRVZoneColorsUseAccentForNearBaseline() {
        let baseline = makeBaseline(mean: 50, sd: 10, established: true)
        XCTAssertEqual(token(50, .hrv, baseline: baseline), .metricAccent(.hrv)) // near = purple
        XCTAssertEqual(token(58, .hrv, baseline: baseline), .mint)              // above
        XCTAssertEqual(token(38, .hrv, baseline: baseline), .amber)             // below
    }

    func testStressAndFatigueZoneColors() {
        XCTAssertEqual(token(10, .stress), .mint)
        XCTAssertEqual(token(40, .stress), .cyan)
        XCTAssertEqual(token(60, .stress), .amber)
        XCTAssertEqual(token(90, .stress), .red)
        XCTAssertEqual(token(90, .fatigue), .red)
    }

    func testBloodPressureZoneColors() {
        // Via the systolic zones used by the gauge/legend.
        let zones = VitalsThresholdEngine.zones(for: .bloodPressure, profile: base)
        func colorAt(_ v: Double) -> VitalColorToken? { zones.first { $0.contains(v) }?.colorToken }
        XCTAssertEqual(colorAt(110), .mint)    // normal
        XCTAssertEqual(colorAt(125), .amber)   // elevated
        XCTAssertEqual(colorAt(135), .orange)  // stage 1
        XCTAssertEqual(colorAt(150), .red)     // stage 2
    }

    /// The line color at a value MUST equal the color of the zone that value falls in (line ↔ legend
    /// agreement) — including normal values, where the old code diverged by using the accent specially.
    func testLineColorMatchesContainingZoneEverywhere() {
        for value in stride(from: 40.0, through: 160.0, by: 1.0) {
            let zones = VitalsThresholdEngine.zones(for: .heartRate, profile: base)
            let zoneToken = zones.first { $0.contains(value) }?.colorToken
            XCTAssertEqual(token(value, .heartRate), zoneToken, "line vs legend mismatch at HR \(value)")
        }
    }

    func testZoneThresholdsAreSortedBoundaries() {
        let thresholds = VitalsThresholdEngine.zoneThresholds(for: .heartRate, profile: base)
        XCTAssertEqual(thresholds, [60, 101, 120])   // the finite upper bounds, sorted
    }
}
