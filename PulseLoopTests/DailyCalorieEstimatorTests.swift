import XCTest
import SwiftData
@testable import PulseLoop

/// The daily calorie model: Mifflin BMR, cadence-tiered step energy, FLEX-gated all-day Keytel,
/// workout proration/netting, single-attribution overlap rules, and the read-time device-vs-estimate
/// selection on `ActivityDaily`.
final class DailyCalorieEstimatorTests: XCTestCase {
    /// A fixed midnight-aligned day start so bucket/HR timestamps are deterministic.
    private let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))

    private let maleProfile = MetricsProfileValues(sex: "male", age: 30, weightKg: 70, heightCm: 175)

    private func inputs(
        steps: Int = 0,
        buckets: [DayStepBucket] = [],
        workouts: [DayWorkoutWindow] = [],
        hrSamples: [(timestamp: Date, bpm: Double)] = [],
        profile: MetricsProfileValues = MetricsProfileValues()
    ) -> DayEstimateInputs {
        DayEstimateInputs(dayStart: dayStart, dayTotalSteps: steps, buckets: buckets,
                          workouts: workouts, hrSamples: hrSamples, profile: profile)
    }

    // MARK: Mifflin-St Jeor

    func testMifflinKnownValues() {
        // Male 70 kg / 175 cm / 30 y: 700 + 1093.75 − 150 + 5 = 1648.75.
        XCTAssertEqual(DailyCalorieMath.mifflinBMR(profile: maleProfile), 1648.75, accuracy: 0.01)
        // Female 60 kg / 165 cm / 30 y: 600 + 1031.25 − 150 − 161 = 1320.25.
        let female = MetricsProfileValues(sex: "female", age: 30, weightKg: 60, heightCm: 165)
        XCTAssertEqual(DailyCalorieMath.mifflinBMR(profile: female), 1320.25, accuracy: 0.01)
        // Empty profile falls back to 70 kg / 170 cm / 35 y with the sex-neutral constant (−78):
        // 700 + 1062.5 − 175 − 78 = 1509.5. Never suppressed.
        XCTAssertEqual(DailyCalorieMath.mifflinBMR(profile: MetricsProfileValues()), 1509.5, accuracy: 0.01)
    }

    // MARK: Step energy

    func testResidualStepsOnlyMatchesIntermittentWalkMath() {
        // 10k steps, no buckets/workouts/HR, default profile: net (3.0 − 1) MET × 70 kg over
        // 10000/100 = 100 walking minutes → 2 × 70 × 100/60 ≈ 233 kcal.
        let kcal = DailyCalorieMath.estimateNetActive(inputs(steps: 10_000))
        XCTAssertEqual(kcal, 233.3, accuracy: 1)
    }

    func testCadenceTiers() {
        // Brisk bucket: 1500 steps / 15 min = 100 spm → MET 3.5 over the whole bucket:
        // 2.5 × 70 × 15/60 = 43.75.
        let brisk = DailyCalorieMath.estimateNetActive(inputs(
            steps: 1500, buckets: [DayStepBucket(start: dayStart, steps: 1500)]))
        XCTAssertEqual(brisk, 43.75, accuracy: 0.5)

        // Run bucket: 2000 steps / 15 min ≈ 133 spm → MET 8.3: 7.3 × 70 × 0.25 = 127.75.
        let run = DailyCalorieMath.estimateNetActive(inputs(
            steps: 2000, buckets: [DayStepBucket(start: dayStart, steps: 2000)]))
        XCTAssertEqual(run, 127.75, accuracy: 0.5)

        // Sparse bucket: 300 steps → intermittent walking, 3 active minutes at MET 3.0 (no height):
        // 2 × 70 × 3/60 = 7.0.
        let sparse = DailyCalorieMath.estimateNetActive(inputs(
            steps: 300, buckets: [DayStepBucket(start: dayStart, steps: 300)]))
        XCTAssertEqual(sparse, 7.0, accuracy: 0.2)
    }

    func testHeightRefinesIntermittentWalkMET() {
        // 175 cm → stride 0.72 m → ~1.21 m/s at 100 spm → MET 3.5 tier (vs 3.0 default).
        XCTAssertEqual(DailyCalorieMath.intermittentWalkMET(heightCm: 175), 3.5, accuracy: 0.01)
        XCTAssertEqual(DailyCalorieMath.intermittentWalkMET(heightCm: nil), 3.0, accuracy: 0.01)
    }

    // MARK: Workouts

    func testWorkoutIsNettedOfResting() {
        // 60-min workout, 500 kcal gross, default profile (BMR 1509.5 → 1.048 kcal/min resting):
        // net ≈ 500 − 62.9 = 437.1.
        let workout = DayWorkoutWindow(start: dayStart.addingTimeInterval(3600),
                                       end: dayStart.addingTimeInterval(7200), calories: 500)
        let kcal = DailyCalorieMath.estimateNetActive(inputs(workouts: [workout]))
        XCTAssertEqual(kcal, 437.1, accuracy: 1)
    }

    func testMidnightCrossingWorkoutIsProrated() {
        // 23:00–01:00, 600 kcal: this day only gets the first hour — 300 kcal minus resting.
        let workout = DayWorkoutWindow(start: dayStart.addingTimeInterval(23 * 3600),
                                       end: dayStart.addingTimeInterval(25 * 3600), calories: 600)
        let bmrPerMin = DailyCalorieMath.mifflinBMR(profile: MetricsProfileValues()) / 1440
        let kcal = DailyCalorieMath.estimateNetActive(inputs(workouts: [workout]))
        XCTAssertEqual(kcal, 300 - bmrPerMin * 60, accuracy: 1)
    }

    func testBucketInsideWorkoutWindowIsNotDoubleCounted() {
        // A brisk bucket entirely inside the workout window contributes nothing on top of the
        // workout's own calories (single attribution per interval).
        let workout = DayWorkoutWindow(start: dayStart, end: dayStart.addingTimeInterval(3600), calories: 400)
        let withBucket = DailyCalorieMath.estimateNetActive(inputs(
            steps: 1500, buckets: [DayStepBucket(start: dayStart, steps: 1500)], workouts: [workout]))
        let withoutBucket = DailyCalorieMath.estimateNetActive(inputs(workouts: [workout]))
        XCTAssertEqual(withBucket, withoutBucket, accuracy: 0.01)
    }

    func testLiveOnlyDayDeductsWorkoutStepsFromResidual() {
        // No buckets (live-only day): a 60-min workout window earns a 60 × 100-step allowance, so
        // only 4000 of the 10000 day-total steps are credited as residual walking.
        let workout = DayWorkoutWindow(start: dayStart, end: dayStart.addingTimeInterval(3600), calories: 400)
        let bmrPerMin = DailyCalorieMath.mifflinBMR(profile: MetricsProfileValues()) / 1440
        let kcal = DailyCalorieMath.estimateNetActive(inputs(steps: 10_000, workouts: [workout]))
        let expectedWorkout = 400 - bmrPerMin * 60
        let expectedResidual = 2.0 * 70 * (4000.0 / 100.0) / 60
        XCTAssertEqual(kcal, expectedWorkout + expectedResidual, accuracy: 1)
    }

    // MARK: All-day HR (FLEX-gated Keytel)

    func testHRAboveFlexEarnsKeytelNetOfResting() {
        // Male 30 y → FLEX = 0.6 × 190 = 114 bpm. Six samples at 120 bpm, 5 min apart, bounded by
        // a below-FLEX sample → 30 covered minutes at the Keytel(120) rate minus resting.
        var samples: [(timestamp: Date, bpm: Double)] = (0..<6).map {
            (timestamp: dayStart.addingTimeInterval(Double($0) * 300), bpm: 120)
        }
        samples.append((timestamp: dayStart.addingTimeInterval(1800), bpm: 70))
        let rate = WorkoutMetricsEngine.keytelRate(hr: 120, male: true, age: 30, weightKg: 70)
        let bmrPerMin = DailyCalorieMath.mifflinBMR(profile: maleProfile) / 1440
        let kcal = DailyCalorieMath.estimateNetActive(inputs(hrSamples: samples, profile: maleProfile))
        XCTAssertEqual(kcal, (rate - bmrPerMin) * 30, accuracy: 1)
    }

    func testHRBelowFlexContributesNothing() {
        // 90 bpm all day is below FLEX (114) — stress/caffeine elevation never adds calories.
        let samples = (0..<12).map { (timestamp: dayStart.addingTimeInterval(Double($0) * 300), bpm: 90.0) }
        XCTAssertEqual(DailyCalorieMath.estimateNetActive(inputs(hrSamples: samples, profile: maleProfile)), 0, accuracy: 0.01)
    }

    func testHRWithoutCompleteProfileContributesNothing() {
        // The Keytel path needs sex/age/weight (same guard as the workout engine); steps still count.
        let samples = (0..<6).map { (timestamp: dayStart.addingTimeInterval(Double($0) * 300), bpm: 150.0) }
        let kcal = DailyCalorieMath.estimateNetActive(inputs(steps: 1000, hrSamples: samples))
        XCTAssertEqual(kcal, 2.0 * 70 * (1000.0 / 100.0) / 60, accuracy: 0.5)
    }

    func testHRInsideWorkoutWindowIsNotDoubleCounted() {
        // Elevated samples inside the workout window are already covered by the workout's calories.
        // A below-FLEX sample at the workout end bounds the last elevated sample's coverage, so the
        // segments lie entirely inside the window and contribute exactly nothing extra.
        let workout = DayWorkoutWindow(start: dayStart, end: dayStart.addingTimeInterval(1800), calories: 300)
        var samples = (0..<6).map { (timestamp: dayStart.addingTimeInterval(Double($0) * 300), bpm: 150.0) }
        samples.append((timestamp: dayStart.addingTimeInterval(1800), bpm: 70))
        let withHR = DailyCalorieMath.estimateNetActive(inputs(workouts: [workout], hrSamples: samples, profile: maleProfile))
        let withoutHR = DailyCalorieMath.estimateNetActive(inputs(workouts: [workout], profile: maleProfile))
        XCTAssertEqual(withHR, withoutHR, accuracy: 0.01)
    }

    func testEstimateIsDeterministic() {
        let mixed = inputs(
            steps: 8000,
            buckets: [DayStepBucket(start: dayStart.addingTimeInterval(3600), steps: 1500)],
            workouts: [DayWorkoutWindow(start: dayStart.addingTimeInterval(7200),
                                        end: dayStart.addingTimeInterval(9000), calories: 250)],
            hrSamples: [(timestamp: dayStart.addingTimeInterval(10_800), bpm: 130)],
            profile: maleProfile
        )
        XCTAssertEqual(DailyCalorieMath.estimateNetActive(mixed), DailyCalorieMath.estimateNetActive(mixed))
    }

    // MARK: Read-time selection (device wins; estimate = BMR-elapsed + active)

    @MainActor
    func testEffectiveCaloriesPrefersDeviceValue() throws {
        let context = try TestSupport.makeContext()
        let row = TestSupport.insertActivity(date: TestSupport.day(-1), steps: 5000, calories: 320,
                                             source: "live", into: context)
        row.estimatedActiveCalories = 150
        XCTAssertEqual(row.effectiveCalories(profile: MetricsProfileValues()), 320)
        XCTAssertEqual(row.effectiveActiveCalories, 320)
    }

    @MainActor
    func testEffectiveCaloriesFallsBackToEstimatedTotalOnHistoryDays() throws {
        let context = try TestSupport.makeContext()
        // Ring-history day: any stored calorie value is untrusted → estimate path.
        let row = TestSupport.insertActivity(date: TestSupport.day(-1), steps: 5000, calories: 320,
                                             source: ActivityService.ringHistorySource, into: context)
        row.estimatedActiveCalories = 150
        // A completed past day accrues the full BMR.
        let expected = DailyCalorieMath.mifflinBMR(profile: MetricsProfileValues()) + 150
        XCTAssertEqual(row.effectiveCalories(profile: MetricsProfileValues()) ?? 0, expected, accuracy: 0.5)
        XCTAssertEqual(row.effectiveActiveCalories, 150)
        // Without an estimate the day renders "—".
        row.estimatedActiveCalories = nil
        XCTAssertNil(row.effectiveCalories(profile: MetricsProfileValues()))
    }

    @MainActor
    func testEffectiveCaloriesTodayAccruesBMRForElapsedMinutesOnly() throws {
        let context = try TestSupport.makeContext()
        let row = TestSupport.insertActivity(date: Date(), steps: 2000, calories: 0,
                                             source: ActivityService.ringHistorySource, into: context)
        row.estimatedActiveCalories = 100
        let bmr = DailyCalorieMath.mifflinBMR(profile: MetricsProfileValues())
        // Noon: half the daily BMR has accrued.
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        XCTAssertEqual(row.effectiveCalories(profile: MetricsProfileValues(), now: noon) ?? 0,
                       bmr / 2 + 100, accuracy: 0.5)
    }

    // MARK: Orchestrator (in-memory store)

    @MainActor
    func testRecomputeWritesEstimateFromBucketsAndIsIdempotent() throws {
        let context = try TestSupport.makeContext()
        let day = TestSupport.day(-1)
        // Two history buckets → daily row via the real ingest path (also marks the day dirty).
        ActivityService.applyActivityBucket(date: day.addingTimeInterval(9 * 3600), steps: 1500, distanceMeters: 1000, context: context)
        ActivityService.applyActivityBucket(date: day.addingTimeInterval(10 * 3600), steps: 500, distanceMeters: 300, context: context)
        try context.save()

        XCTAssertTrue(DailyCalorieEstimator.dirtyDays.contains(day))
        DailyCalorieEstimator.flushDirty(context: context)
        XCTAssertTrue(DailyCalorieEstimator.dirtyDays.isEmpty)

        let row = try XCTUnwrap(MetricsRepository.activity(on: day, context: context))
        let first = try XCTUnwrap(row.estimatedActiveCalories)
        XCTAssertGreaterThan(first, 0)

        // Re-syncing the same buckets converges to the same estimate.
        ActivityService.applyActivityBucket(date: day.addingTimeInterval(9 * 3600), steps: 1500, distanceMeters: 1000, context: context)
        DailyCalorieEstimator.flushDirty(context: context)
        XCTAssertEqual(row.estimatedActiveCalories ?? 0, first, accuracy: 0.01)
    }

    @MainActor
    func testWorkoutFinishAndDeleteUpdateDayEstimate() throws {
        let context = try TestSupport.makeContext()
        let session = ActivityRecorderService.start(type: "run", useGps: false, notes: nil, context: context)
        session.startedAt = Date().addingTimeInterval(-1800)
        ActivityRecorderService.finish(session, context: context)

        let day = Calendar.current.startOfDay(for: session.startedAt)
        let row = try XCTUnwrap(MetricsRepository.activity(on: day, context: context))
        let withWorkout = try XCTUnwrap(row.estimatedActiveCalories)
        XCTAssertGreaterThan(withWorkout, 0)

        ActivityRecorderService.delete(session, context: context)
        XCTAssertEqual(row.estimatedActiveCalories ?? -1, 0, accuracy: 0.01)
    }

    @MainActor
    func testBuildTodaySummaryUsesEstimateOnHistoryDaysAndDeviceValueOnLiveDays() throws {
        let historyContext = try TestSupport.makeContext()
        let historyRow = TestSupport.insertActivity(date: Date(), steps: 6000, calories: 0,
                                                    source: ActivityService.ringHistorySource, into: historyContext)
        DailyCalorieEstimator.recompute(day: Date(), context: historyContext)
        let historySummary = MetricsService.buildTodaySummary(context: historyContext)
        let active = try XCTUnwrap(historyRow.estimatedActiveCalories)
        XCTAssertEqual(historySummary.activeCalories ?? 0, active, accuracy: 0.01)
        // Displayed total = active + BMR accrued so far today (bounded by the full-day BMR).
        let total = try XCTUnwrap(historySummary.calories)
        XCTAssertGreaterThanOrEqual(total + 0.01, active)
        XCTAssertLessThanOrEqual(total, active + DailyCalorieMath.mifflinBMR(profile: MetricsProfileValues()))

        let liveContext = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 6000, calories: 410, source: "live", into: liveContext)
        let liveSummary = MetricsService.buildTodaySummary(context: liveContext)
        XCTAssertEqual(liveSummary.calories, 410)
        XCTAssertEqual(liveSummary.activeCalories, 410)
    }
}
