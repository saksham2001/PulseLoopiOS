import XCTest
@testable import PulseLoop

/// Locks the readiness algorithm: band knots, the missing-signal contract, and the exact wording of
/// the contributor explanations. Pure logic — no store, no hardware, no dates.
///
/// The most important test here is `testMissingContributorIsNeverScoredAsZero`. Everything else is
/// arithmetic; that one encodes the design rule the whole feature rests on.
@MainActor
final class ReadinessScoreTests: XCTestCase {

    // MARK: - Fixtures

    /// An established baseline: `isEstablished` needs ≥7 span days and ≥20 samples.
    private func baseline(_ median: Double, established: Bool = true) -> BaselineStats {
        BaselineStats(
            mean: median,
            median: median,
            standardDeviation: median * 0.1,
            p25: median * 0.9,
            p75: median * 1.1,
            sampleCount: established ? 40 : 5,
            spanDays: established ? 30 : 3
        )
    }

    /// Every contributor present and exactly at baseline.
    private func perfectInputs() -> ReadinessInputs {
        ReadinessInputs(
            hrv: 50, hrvBaseline: baseline(50),
            restingHeartRate: 55, restingHeartRateBaseline: 55,
            sleepScore: 90,
            skinTemperature: 36.1, skinTemperatureBaseline: baseline(36.0),
            priorDayLoadMinutes: 45, loadBaselineMinutes: 45
        )
    }

    /// HRV at a given percentage deviation from a 50 ms baseline, paired with sleep so the
    /// 50-point coverage gate is satisfied and the outcome is scoreable.
    private func hrvInputs(deviationPercent: Double, sleepScore: Int = 88) -> ReadinessInputs {
        ReadinessInputs(
            hrv: 50 * (1 + deviationPercent / 100), hrvBaseline: baseline(50),
            sleepScore: sleepScore
        )
    }

    private func scored(_ inputs: ReadinessInputs,
                        file: StaticString = #filePath, line: UInt = #line) throws -> ReadinessResult {
        guard case .scored(let result) = ReadinessScore.evaluate(inputs) else {
            XCTFail("expected a scored outcome, got \(ReadinessScore.evaluate(inputs))", file: file, line: line)
            throw XCTSkip("not scored")
        }
        return result
    }

    private func contributor(_ kind: ReadinessContributor.Kind,
                             in result: ReadinessResult,
                             file: StaticString = #filePath, line: UInt = #line) throws -> ReadinessContributor {
        let match = result.contributors.first { $0.kind == kind }
        return try XCTUnwrap(match, "expected a \(kind.rawValue) contributor", file: file, line: line)
    }

    private func earned(_ kind: ReadinessContributor.Kind, _ inputs: ReadinessInputs) throws -> Double {
        try contributor(kind, in: try scored(inputs)).earned
    }

    // MARK: - Composition

    func testAllContributorsAtBaselineScores100() throws {
        let result = try scored(perfectInputs())
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.band, .primed)
        XCTAssertEqual(result.availablePoints, 100)
        XCTAssertEqual(result.coverage, 1.0)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.contributors.count, 5)
    }

    /// The core invariant. A signal the ring didn't capture must leave the denominator, not drag
    /// the score down. If this ever fails, readiness is punishing users for hardware gaps.
    func testMissingContributorIsNeverScoredAsZero() throws {
        // Sleep (30) + resting HR (25) = 55 available, both perfect.
        let partial = ReadinessInputs(
            restingHeartRate: 55, restingHeartRateBaseline: 55,
            sleepScore: 90
        )
        let partialResult = try scored(partial)
        XCTAssertEqual(partialResult.score, 100, "a night missing HRV is scored out of 55, not out of 100")
        XCTAssertEqual(partialResult.availablePoints, 55)
        XCTAssertEqual(partialResult.coverage, 0.55, accuracy: 0.0001)
        XCTAssertTrue(partialResult.missing.contains(.hrv))

        // The same night, but HRV was captured and is genuinely poor — now it must bite.
        var withPoorHrv = partial
        withPoorHrv.hrv = 30
        withPoorHrv.hrvBaseline = baseline(50)
        let poorResult = try scored(withPoorHrv)
        XCTAssertLessThan(poorResult.score, partialResult.score)
        XCTAssertEqual(poorResult.availablePoints, 85)
    }

    func testCoverageGateReturnsUnavailable() {
        // Sleep alone is 30 points — below the 50-point floor.
        let outcome = ReadinessScore.evaluate(ReadinessInputs(sleepScore: 90))
        XCTAssertEqual(outcome, .unavailable(.insufficientCoverage))
    }

    func testNoSignalsAtAllIsDistinctFromThinCoverage() {
        XCTAssertEqual(ReadinessScore.evaluate(ReadinessInputs()), .unavailable(.noSignals))
    }

    /// Resting HR and temperature qualify recovery; they don't describe it. Without HRV or sleep
    /// there is nothing to qualify.
    func testWithoutCoreSignalIsUnavailableEvenWithEnoughPoints() {
        let outcome = ReadinessScore.evaluate(ReadinessInputs(
            restingHeartRate: 55, restingHeartRateBaseline: 55,
            skinTemperature: 36.0, skinTemperatureBaseline: baseline(36.0),
            priorDayLoadMinutes: 45, loadBaselineMinutes: 45
        ))
        XCTAssertEqual(outcome, .unavailable(.insufficientCoverage))
    }

    /// A signal whose baseline isn't established is missing, not "at baseline" — and it reports the
    /// recoverable reason so the tile can say "still learning" instead of "no data".
    func testUnestablishedBaselineIsTreatedAsMissing() throws {
        let inputs = ReadinessInputs(
            hrv: 50, hrvBaseline: baseline(50, established: false),
            sleepScore: 90
        )
        XCTAssertEqual(ReadinessScore.evaluate(inputs), .unavailable(.baselineLearning))

        // With enough other coverage to score, HRV still stays out of the maths entirely.
        var withRhr = inputs
        withRhr.restingHeartRate = 55
        withRhr.restingHeartRateBaseline = 55
        let result = try scored(withRhr)
        XCTAssertEqual(result.availablePoints, 55, "an unestablished baseline contributes no points")
        XCTAssertTrue(result.missing.contains(.hrv))
        XCTAssertFalse(result.contributors.contains { $0.kind == .hrv })
    }

    // MARK: - Band knots

    func testHrvBandKnots() throws {
        XCTAssertEqual(try earned(.hrv, hrvInputs(deviationPercent: 0)), 30.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.hrv, hrvInputs(deviationPercent: -15)), 16.5, accuracy: 0.001)
        XCTAssertEqual(try earned(.hrv, hrvInputs(deviationPercent: -40)), 0.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.hrv, hrvInputs(deviationPercent: -60)), 0.0, accuracy: 0.001)
    }

    func testHighHrvIsNotPenalized() throws {
        XCTAssertEqual(try earned(.hrv, hrvInputs(deviationPercent: 40)), 30.0, accuracy: 0.001)
    }

    func testRestingHeartRateBandKnots() throws {
        func rhr(_ delta: Double) -> ReadinessInputs {
            ReadinessInputs(restingHeartRate: 55 + delta, restingHeartRateBaseline: 55, sleepScore: 88)
        }
        XCTAssertEqual(try earned(.restingHeartRate, rhr(0)), 25.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.restingHeartRate, rhr(5)), 13.75, accuracy: 0.001)
        XCTAssertEqual(try earned(.restingHeartRate, rhr(12)), 0.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.restingHeartRate, rhr(-6)), 25.0, accuracy: 0.001,
                       "a resting HR below baseline is a good sign, never a penalty")
    }

    func testSleepBandKnots() throws {
        func sleep(_ score: Int) -> ReadinessInputs {
            ReadinessInputs(restingHeartRate: 55, restingHeartRateBaseline: 55, sleepScore: score)
        }
        XCTAssertEqual(try earned(.sleep, sleep(88)), 30.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.sleep, sleep(65)), 16.5, accuracy: 0.001)
        XCTAssertEqual(try earned(.sleep, sleep(30)), 0.0, accuracy: 0.001)
    }

    func testSkinTemperatureIsSymmetric() throws {
        // Resting HR is carried at baseline purely to clear the 50-point coverage gate; it earns
        // full marks, so it never moves the temperature contributor being measured.
        func temp(_ delta: Double) -> ReadinessInputs {
            ReadinessInputs(
                restingHeartRate: 55, restingHeartRateBaseline: 55,
                sleepScore: 88,
                skinTemperature: 36.0 + delta, skinTemperatureBaseline: baseline(36.0)
            )
        }
        let above = try contributor(.skinTemperature, in: try scored(temp(0.9)))
        let below = try contributor(.skinTemperature, in: try scored(temp(-0.9)))
        XCTAssertEqual(above.earned, below.earned, "a deviation is a deviation in either direction")
        XCTAssertEqual(above.detail, "Skin temperature 0.9 °C above your baseline")
        XCTAssertEqual(below.detail, "Skin temperature 0.9 °C below your baseline")

        XCTAssertEqual(try earned(.skinTemperature, temp(0.2)), 10.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.skinTemperature, temp(0.6)), 5.5, accuracy: 0.001)
        XCTAssertEqual(try earned(.skinTemperature, temp(1.2)), 0.0, accuracy: 0.001)
    }

    func testTrainingLoadBandKnots() throws {
        // Resting HR at baseline clears the coverage gate without affecting the load contributor.
        func load(_ ratio: Double) -> ReadinessInputs {
            ReadinessInputs(
                restingHeartRate: 55, restingHeartRateBaseline: 55,
                sleepScore: 88,
                priorDayLoadMinutes: 40 * ratio, loadBaselineMinutes: 40
            )
        }
        XCTAssertEqual(try earned(.trainingLoad, load(1.0)), 5.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.trainingLoad, load(1.2)), 5.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.trainingLoad, load(1.8)), 2.75, accuracy: 0.001)
        XCTAssertEqual(try earned(.trainingLoad, load(3.0)), 0.0, accuracy: 0.001)
        XCTAssertEqual(try earned(.trainingLoad, load(0.2)), 5.0, accuracy: 0.001,
                       "a rest day is never penalized")
    }

    func testBandCutoffs() {
        XCTAssertEqual(ReadinessScore.band(100), .primed)
        XCTAssertEqual(ReadinessScore.band(85), .primed)
        XCTAssertEqual(ReadinessScore.band(84), .ready)
        XCTAssertEqual(ReadinessScore.band(70), .ready)
        XCTAssertEqual(ReadinessScore.band(69), .moderate)
        XCTAssertEqual(ReadinessScore.band(55), .moderate)
        XCTAssertEqual(ReadinessScore.band(54), .restNeeded)
        XCTAssertEqual(ReadinessScore.band(0), .restNeeded)
    }

    // MARK: - Shape

    /// No cliffs, no inversions, no out-of-range scores anywhere across the HRV domain.
    func testScoreIsMonotonicInHrv() throws {
        var previous = Int.max
        for step in stride(from: 20.0, through: -60.0, by: -1.0) {
            let result = try scored(hrvInputs(deviationPercent: step))
            XCTAssertTrue((0...100).contains(result.score), "score \(result.score) out of range at \(step)%")
            XCTAssertLessThanOrEqual(result.score, previous, "score rose as HRV fell, at \(step)%")
            previous = result.score
        }
    }

    func testContributorsSortedByDragDescending() throws {
        let inputs = ReadinessInputs(
            hrv: 30, hrvBaseline: baseline(50),               // −40%, full 30-point drag
            restingHeartRate: 57, restingHeartRateBaseline: 55, // +2 bpm, small drag
            sleepScore: 90,                                     // no drag
            skinTemperature: 36.0, skinTemperatureBaseline: baseline(36.0),
            priorDayLoadMinutes: 45, loadBaselineMinutes: 45
        )
        let result = try scored(inputs)
        let drags = result.contributors.map(\.drag)
        XCTAssertEqual(drags, drags.sorted(by: >))
        XCTAssertEqual(result.contributors.first?.kind, .hrv)
    }

    func testMissingIsReportedInCanonicalOrder() throws {
        let result = try scored(ReadinessInputs(
            hrv: 50, hrvBaseline: baseline(50),
            sleepScore: 90
        ))
        XCTAssertEqual(result.missing, [.restingHeartRate, .skinTemperature, .trainingLoad])
    }

    // MARK: - Explanations

    func testDetailStringsAreDataHonest() throws {
        let result = try scored(ReadinessInputs(
            hrv: 44, hrvBaseline: baseline(50),                 // −12%
            restingHeartRate: 59, restingHeartRateBaseline: 55, // +4 bpm
            sleepScore: 82
        ))
        XCTAssertEqual(try contributor(.hrv, in: result).detail, "HRV 12% below your baseline")
        XCTAssertEqual(try contributor(.restingHeartRate, in: result).detail, "Resting HR 4 bpm above your baseline")
        XCTAssertEqual(try contributor(.sleep, in: result).detail, "Sleep score 82")

        // Nothing describes a signal that wasn't measured.
        XCTAssertFalse(result.contributors.contains { $0.kind == .skinTemperature })
        XCTAssertFalse(result.contributors.contains { $0.detail.localizedCaseInsensitiveContains("temperature") })
        XCTAssertFalse(result.contributors.contains { $0.detail.localizedCaseInsensitiveContains("load") })
    }

    /// A deviation that rounds to zero is reported as "at baseline", not as a finding of zero.
    func testNegligibleDeviationReadsAsAtBaseline() throws {
        let result = try scored(ReadinessInputs(
            hrv: 50.1, hrvBaseline: baseline(50),
            restingHeartRate: 55.1, restingHeartRateBaseline: 55,
            sleepScore: 88
        ))
        XCTAssertEqual(try contributor(.hrv, in: result).detail, "HRV at your baseline")
        XCTAssertEqual(try contributor(.restingHeartRate, in: result).detail, "Resting HR at your baseline")
    }

    func testTrainingLoadDetailOnlyCallsOutRealSpikes() throws {
        func detail(_ ratio: Double) throws -> String {
            try contributor(.trainingLoad, in: try scored(
                ReadinessInputs(
                    restingHeartRate: 55, restingHeartRateBaseline: 55,
                    sleepScore: 88,
                    priorDayLoadMinutes: 40 * ratio, loadBaselineMinutes: 40
                )
            )).detail
        }
        XCTAssertEqual(try detail(1.0), "Yesterday's load in your usual range")
        XCTAssertEqual(try detail(2.1), "Yesterday's load 2.1× your usual")
    }

    // MARK: - Robustness

    /// Garbage in must not produce a crash, a NaN, or a confidently wrong number. The service layer
    /// filters its samples, but scoring must not depend on that.
    func testDegenerateInputsAreSafe() {
        let hostile: [ReadinessInputs] = [
            ReadinessInputs(hrv: .nan, hrvBaseline: baseline(50), sleepScore: 90),
            ReadinessInputs(hrv: .infinity, hrvBaseline: baseline(50), sleepScore: 90),
            ReadinessInputs(hrv: -10, hrvBaseline: baseline(50), sleepScore: 90),
            ReadinessInputs(hrv: 50, hrvBaseline: baseline(0), sleepScore: 90),
            ReadinessInputs(restingHeartRate: 55, restingHeartRateBaseline: 0, sleepScore: 90),
            ReadinessInputs(sleepScore: 0, priorDayLoadMinutes: 45, loadBaselineMinutes: 0),
            ReadinessInputs(sleepScore: -5),
            ReadinessInputs(
                hrv: 50, hrvBaseline: baseline(50),
                sleepScore: 90,
                skinTemperature: .nan, skinTemperatureBaseline: baseline(36.0),
                priorDayLoadMinutes: .infinity, loadBaselineMinutes: 45
            )
        ]

        for inputs in hostile {
            switch ReadinessScore.evaluate(inputs) {
            case .unavailable:
                continue
            case .scored(let result):
                XCTAssertTrue((0...100).contains(result.score), "score \(result.score) out of range")
                XCTAssertGreaterThan(result.availablePoints, 0)
                for c in result.contributors {
                    XCTAssertTrue(c.earned.isFinite, "\(c.kind.rawValue) earned a non-finite score")
                    XCTAssertTrue((0...c.maxPoints).contains(c.earned))
                    XCTAssertFalse(c.detail.isEmpty)
                }
            }
        }
    }

    /// Bumping the version is what invalidates stored rows. Changing weights or knots without
    /// bumping it would leave old scores silently reinterpreted — so this pin is deliberate.
    /// If you changed the algorithm: bump `algorithmVersion`, update `docs/project/readiness.md`,
    /// then update this test.
    func testAlgorithmVersionIsPinned() {
        XCTAssertEqual(ReadinessScore.algorithmVersion, 1)
        XCTAssertEqual(ReadinessScore.minAvailablePoints, 50)
        XCTAssertEqual(ReadinessScore.softFraction, 0.55)
    }

    /// The weights are the contract agreed in the issue thread; they are not incidental.
    func testContributorWeightsSumTo100() {
        let total = ReadinessContributor.Kind.allCases.reduce(0) { $0 + $1.maxPoints }
        XCTAssertEqual(total, 100)
        XCTAssertEqual(ReadinessContributor.Kind.hrv.maxPoints, 30)
        XCTAssertEqual(ReadinessContributor.Kind.restingHeartRate.maxPoints, 25)
        XCTAssertEqual(ReadinessContributor.Kind.sleep.maxPoints, 30)
        XCTAssertEqual(ReadinessContributor.Kind.skinTemperature.maxPoints, 10)
        XCTAssertEqual(ReadinessContributor.Kind.trainingLoad.maxPoints, 5)
    }
}
