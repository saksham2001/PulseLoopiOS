import XCTest
@testable import PulseLoop

@MainActor
final class OnboardingSupportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingSupportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testProgressStoreRoundTripsExactRouteAndClears() {
        let store = OnboardingProgressStore(defaults: defaults)
        let route: [OnboardingStep] = [.welcome, .ring, .profile, .goals]

        store.savePath(route)
        XCTAssertEqual(store.loadPath(), route)

        store.clear()
        XCTAssertEqual(store.loadPath(), [.welcome])
    }

    func testProgressStoreRejectsRouteThatDoesNotStartAtWelcome() {
        defaults.set([OnboardingStep.profile.rawValue], forKey: OnboardingProgressStore.storageKey)
        XCTAssertEqual(OnboardingProgressStore(defaults: defaults).loadPath(), [.welcome])
    }

    func testProfileDraftUsesLocaleForNewProfileAndPreservesExistingUnits() {
        XCTAssertEqual(ProfileDraft(locale: Locale(identifier: "en_US")).units, .imperial)
        XCTAssertEqual(ProfileDraft(locale: Locale(identifier: "fr_FR")).units, .metric)

        let existing = UserProfile(units: .metric)
        XCTAssertEqual(ProfileDraft(profile: existing, locale: Locale(identifier: "en_US")).units, .metric)
    }

    func testUntouchedProfileFieldsRemainUnset() {
        var draft = ProfileDraft(locale: Locale(identifier: "en_US"))
        draft.name = "   "
        let profile = UserProfile(age: 44, sex: "male", heightCm: 180, weightKg: 82)

        draft.apply(to: profile)

        XCTAssertNil(profile.name)
        XCTAssertNil(profile.age)
        XCTAssertNil(profile.sex)
        XCTAssertNil(profile.heightCm)
        XCTAssertNil(profile.weightKg)
        XCTAssertEqual(profile.units, .imperial)
    }

    func testProfileDisplayConversionsRoundTrip() {
        var draft = ProfileDraft(locale: Locale(identifier: "en_US"))
        draft.units = .imperial
        draft.setHeight(displayValue: 70)
        draft.setWeight(displayValue: 165)

        XCTAssertEqual(draft.heightCm ?? 0, 177.8, accuracy: 0.01)
        XCTAssertEqual(draft.weightKg ?? 0, 74.84, accuracy: 0.02)
        XCTAssertEqual(draft.heightDisplayValue, 70)
        XCTAssertEqual(draft.weightDisplayValue, 165)

        draft.setHeight(displayValue: nil)
        draft.setWeight(displayValue: nil)
        XCTAssertNil(draft.heightCm)
        XCTAssertNil(draft.weightKg)
    }

    func testWeightInputAcceptsCommaAndPeriodDecimalSeparators() {
        let europeanLocale = Locale(identifier: "de_DE")
        let usLocale = Locale(identifier: "en_US")

        XCTAssertEqual(LocalizedDecimalInput.parse("72,5", locale: europeanLocale), 72.5)
        XCTAssertEqual(LocalizedDecimalInput.parse("72.5", locale: europeanLocale), 72.5)
        XCTAssertEqual(LocalizedDecimalInput.parse("72,5", locale: usLocale), 72.5)
        XCTAssertEqual(LocalizedDecimalInput.parse("72.5", locale: usLocale), 72.5)
    }

    func testDecimalWeightRoundTripsThroughProfileDraft() {
        var draft = ProfileDraft(locale: Locale(identifier: "de_DE"))
        draft.units = .metric
        draft.setWeight(displayValue: LocalizedDecimalInput.parse("72,5", locale: Locale(identifier: "de_DE")))

        XCTAssertEqual(draft.weightKg ?? 0, 72.5, accuracy: 0.001)
        XCTAssertEqual(draft.weightDisplayValue ?? 0, 72.5, accuracy: 0.001)
    }

    func testGoalDraftUsesCanonicalRecommendationsInBothUnitSystems() {
        let metric = GoalDraft(units: .metric)
        let imperial = GoalDraft(units: .imperial)

        XCTAssertEqual(metric.steps, 10_000)
        XCTAssertEqual(metric.distance, 8)
        XCTAssertEqual(metric.calories, 500)
        XCTAssertEqual(metric.activeMinutes, 45)
        XCTAssertEqual(metric.sleepHours, 8)
        XCTAssertEqual(imperial.distance, 5, accuracy: 0.01)
    }

    func testOnboardingGoalSavePreservesWeeklyWorkoutTarget() {
        var draft = GoalDraft(units: .metric)
        draft.steps = 12_000
        draft.distance = 10
        draft.workouts = 7
        let goal = UserGoal(workoutsPerWeek: 3)

        draft.apply(to: goal, units: .metric, includeWeeklyWorkouts: false)

        XCTAssertEqual(goal.steps, 12_000)
        XCTAssertEqual(goal.distanceMeters, 10_000, accuracy: 0.01)
        XCTAssertEqual(goal.workoutsPerWeek, 3)
    }
}
