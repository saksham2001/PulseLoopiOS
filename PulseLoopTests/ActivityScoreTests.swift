import XCTest
import SwiftData
@testable import PulseLoop

/// The daily movement score: goal-relative contributors, no penalty for exceeding a goal, and the
/// same missing-data-leaves-the-denominator rule the sleep score follows.
@MainActor
final class ActivityScoreTests: XCTestCase {

    private func inputs(
        steps: Int? = 10000, activeMinutes: Int? = 45, energy: Double? = 500,
        activeHours: Int? = 10, observableHours: Int? = 10
    ) -> ActivityScoreInputs {
        ActivityScoreInputs(
            steps: steps, activeMinutes: activeMinutes, activeEnergyKcal: energy,
            activeHours: activeHours, observableHours: observableHours,
            stepsGoal: 10000, activeMinutesGoal: 45, energyGoal: 500
        )
    }

    private func contributor(_ kind: ActivityContributor.Kind, in result: ActivityScoreResult) -> ActivityContributor? {
        result.contributors.first { $0.kind == kind }
    }

    // MARK: - Goal curve

    func testGoalScoreKnots() {
        XCTAssertEqual(ActivityScore.goalScore(actual: 100, goal: 100, points: 35), 35, accuracy: 0.001)
        XCTAssertEqual(ActivityScore.goalScore(actual: 60, goal: 100, points: 35), 22.75, accuracy: 0.001,
                       "65% of the points at 60% of the goal")
        XCTAssertEqual(ActivityScore.goalScore(actual: 0, goal: 100, points: 35), 0, accuracy: 0.001)
        XCTAssertEqual(ActivityScore.goalScore(actual: 30, goal: 100, points: 35), 11.375, accuracy: 0.001,
                       "linear below the soft knot")
    }

    /// Overreaching is what training load is for. A movement score that docked a long hike would be
    /// actively misleading.
    func testExceedingAGoalIsNeverPenalised() {
        XCTAssertEqual(ActivityScore.goalScore(actual: 250, goal: 100, points: 35), 35, accuracy: 0.001)
        XCTAssertEqual(ActivityScore.calculate(inputs(steps: 40000)).score, 100)
    }

    func testZeroGoalCannotDivideByZero() {
        XCTAssertEqual(ActivityScore.goalScore(actual: 5000, goal: 0, points: 35), 0, accuracy: 0.001)
    }

    // MARK: - Contributors

    func testAllFourContributorsScoreAFullDay() {
        let result = ActivityScore.calculate(inputs())
        XCTAssertEqual(Set(result.contributors.map(\.kind)), [.steps, .activeMinutes, .energy, .regularity])
        XCTAssertEqual(result.coverage, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.band, .veryActive)
    }

    /// A ring-history day carries no trustworthy calorie figure, so energy drops out — the day is
    /// scored out of 80 rather than docked 20 for a number the app doesn't stand behind.
    func testMissingEnergyLeavesTheDenominator() {
        let result = ActivityScore.calculate(inputs(energy: nil))
        XCTAssertNil(contributor(.energy, in: result))
        XCTAssertEqual(result.coverage, 0.8, accuracy: 0.001)
        XCTAssertEqual(result.score, 100, "a full day is still a full day on 80 available points")
    }

    /// A ring that reports only a daily total can't answer the regularity question.
    func testMissingIntradayBucketsDropRegularity() {
        let result = ActivityScore.calculate(inputs(activeHours: nil, observableHours: nil))
        XCTAssertNil(contributor(.regularity, in: result))
        XCTAssertEqual(result.coverage, 0.85, accuracy: 0.001)
    }

    /// Regularity is judged against the hours the ring actually observed, so a ring taken off at
    /// lunchtime isn't scored for the afternoon it never saw.
    func testRegularityIsRelativeToObservedHours() {
        let halfDay = ActivityScore.calculate(inputs(activeHours: 5, observableHours: 5))
        XCTAssertEqual(contributor(.regularity, in: halfDay)?.earned ?? 0, 15, accuracy: 0.001)

        let sedentary = ActivityScore.calculate(inputs(activeHours: 2, observableHours: 10))
        XCTAssertLessThan(contributor(.regularity, in: sedentary)?.earned ?? 99, 8)
    }

    /// Two days can hit the same step count and score differently: one moved throughout, the other
    /// sat still around a single session.
    func testRegularityDistinguishesOneBigSessionFromAMovingDay() {
        let spread = ActivityScore.calculate(inputs(activeHours: 10, observableHours: 10))
        let oneBurst = ActivityScore.calculate(inputs(activeHours: 2, observableHours: 10))
        XCTAssertGreaterThan(spread.score, oneBurst.score)
    }

    func testTooFewSignalsScoresZero() {
        let sparse = ActivityScoreInputs(
            steps: 8000, activeMinutes: nil, activeEnergyKcal: nil,
            activeHours: nil, observableHours: nil,
            stepsGoal: 10000, activeMinutesGoal: 45, energyGoal: 500
        )
        let result = ActivityScore.calculate(sparse)
        XCTAssertEqual(result.score, 0, "35 available points can't be dressed up as a score out of 100")
        XCTAssertLessThan(result.coverage, 0.5)
    }

    // MARK: - Invariants

    func testContributorWeightsSumToOneHundred() {
        XCTAssertEqual(ActivityContributor.Kind.allCases.reduce(0) { $0 + $1.maxPoints }, 100, accuracy: 0.001)
    }

    func testBands() {
        XCTAssertEqual(ActivityBand(score: 100), .veryActive)
        XCTAssertEqual(ActivityBand(score: 85), .veryActive)
        XCTAssertEqual(ActivityBand(score: 84), .active)
        XCTAssertEqual(ActivityBand(score: 70), .active)
        XCTAssertEqual(ActivityBand(score: 69), .light)
        XCTAssertEqual(ActivityBand(score: 45), .light)
        XCTAssertEqual(ActivityBand(score: 44), .restful)
    }

    // MARK: - Regularity from the store

    func testMovementRegularityCountsHoursOverTheStepFloor() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let day = TestSupport.day(0)

        // Three hours inside the window: two busy, one barely moving.
        for (hour, steps) in [(9, 400), (13, 60), (17, 900)] {
            let ts = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            context.insert(ActivityBucketSample(timestamp: ts, steps: steps, distanceMeters: 0))
        }
        // And one at 03:00, outside the waking window — must not count either way.
        let night = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: day) ?? day
        context.insert(ActivityBucketSample(timestamp: night, steps: 900, distanceMeters: 0))
        try? context.save()

        let regularity = try XCTUnwrap(ActivityScoreService.movementRegularity(on: day, context: context))
        XCTAssertEqual(regularity.observableHours, 3, "03:00 is outside 08:00–22:00")
        XCTAssertEqual(regularity.activeHours, 2, "the 60-step hour is under the 250 floor")
    }

    func testMovementRegularityIsNilWithoutBuckets() throws {
        let context = try TestSupport.makeContext()
        XCTAssertNil(ActivityScoreService.movementRegularity(on: TestSupport.day(0), context: context))
    }

    func testScoreIsNilWithoutAnActivityRow() throws {
        let context = try TestSupport.makeContext()
        XCTAssertNil(ActivityScoreService.score(on: TestSupport.day(0), context: context))
    }
}
