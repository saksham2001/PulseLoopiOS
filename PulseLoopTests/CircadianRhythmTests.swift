import SwiftData
import XCTest
@testable import PulseLoop

/// Pure-logic coverage for the circadian tile: clock math, the usual-vs-period engine, Smart
/// inclusion, the headline copy, formatting, prefs, and the dial's time → angle mapping.
@MainActor
final class CircadianRhythmTests: XCTestCase {
    // A fixed calendar and reference day keep every case independent of the machine's clock/zone.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Day 0 — the day (or the last day of the range) being viewed.
    private var today: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 20))! }

    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day(dayOffset))!
    }

    /// A night keyed on waking day `offset`. An evening bedtime (hour >= 12) falls on the day before.
    private func night(_ offset: Int, bed: (Int, Int) = (23, 0), wake: (Int, Int) = (7, 0)) -> CircadianSleepSample {
        let start = at(bed.0 >= 12 ? offset - 1 : offset, bed.0, bed.1)
        let end = at(offset, wake.0, wake.1)
        return CircadianSleepSample(day: day(offset), start: start, end: end, minutes: Int(end.timeIntervalSince(start) / 60))
    }

    private func meal(_ offset: Int, _ kind: CircadianAnchorKind, _ hour: Int, _ minute: Int) -> CircadianMealSample {
        CircadianMealSample(day: day(offset), time: at(offset, hour, minute), kind: kind)
    }

    private func workout(_ offset: Int, _ hour: Int = 18, minutes: Double = 45,
                         _ category: CircadianWorkoutCategory = .cardio) -> CircadianWorkoutSample {
        CircadianWorkoutSample(start: at(offset, hour, 0), durationMinutes: minutes, category: category, label: "Run")
    }

    private var dayPeriod: CircadianPeriod { CircadianPeriod(scope: .day, start: today, end: today) }

    private func snapshot(
        period: CircadianPeriod? = nil,
        sleep: [CircadianSleepSample] = [],
        meals: [CircadianMealSample] = [],
        workouts: [CircadianWorkoutSample] = [],
        prefs: CircadianPrefs? = nil,
        nutritionEnabled: Bool = true
    ) -> CircadianSnapshot {
        CircadianEngine.snapshot(
            period: period ?? dayPeriod, sleep: sleep, meals: meals, workouts: workouts,
            prefs: prefs ?? .default, nutritionEnabled: nutritionEnabled, calendar: cal)
    }

    /// `count` consecutive baseline nights ending yesterday, all at the same times.
    private func baseline(_ count: Int = 10, bed: (Int, Int) = (23, 0), wake: (Int, Int) = (7, 0)) -> [CircadianSleepSample] {
        (1...count).map { night(-$0, bed: bed, wake: wake) }
    }

    // MARK: Clock math

    func testCircularMeanAveragesAcrossMidnight() throws {
        let mean = try XCTUnwrap(CircadianMath.circularMean([1410.0, 30.0]))
        XCTAssertEqual(CircadianMath.signedDelta(mean, from: 0), 0, accuracy: 0.01)
    }

    func testCircularMeanIsNilWithoutACentre() {
        XCTAssertNil(CircadianMath.circularMean([]))
        XCTAssertNil(CircadianMath.circularMean([0, 720]))
    }

    func testSignedDeltaTakesTheShortWayRound() {
        XCTAssertEqual(CircadianMath.signedDelta(10, from: 1430), 20, accuracy: 0.001)
        XCTAssertEqual(CircadianMath.signedDelta(1430, from: 10), -20, accuracy: 0.001)
        XCTAssertEqual(CircadianMath.signedDelta(450, from: 420), 30, accuracy: 0.001)
    }

    // MARK: Sleep anchors

    func testDayDriftIsMeasuredAgainstThePreviousThirtyDays() throws {
        let snap = snapshot(sleep: baseline() + [night(0, bed: (23, 30), wake: (6, 30))])
        let wake = try XCTUnwrap(snap.anchor(.wake))
        let bed = try XCTUnwrap(snap.anchor(.bed))
        XCTAssertEqual(try XCTUnwrap(wake.usualMinutes), 420, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(wake.deltaMinutes), -30, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bed.usualMinutes), 1380, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bed.deltaMinutes), 30, accuracy: 0.01)
        XCTAssertFalse(snap.isLearning)
    }

    func testTheSelectedDayIsNotPartOfItsOwnBaseline() throws {
        // If today counted toward "usual", a late night would pull the average toward itself.
        let snap = snapshot(sleep: baseline(5) + [night(0, bed: (1, 0), wake: (9, 0))])
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.usualMinutes), 420, accuracy: 0.01)
    }

    func testNapsNeverMoveTheAnchors() throws {
        let nap = CircadianSleepSample(day: today, start: at(0, 14, 0), end: at(0, 14, 45), minutes: 45)
        let snap = snapshot(sleep: baseline() + [night(0), nap])
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.periodMinutes), 420, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.bed)?.periodMinutes), 1380, accuracy: 0.01)
    }

    func testALoneNapIsNotTreatedAsTheNight() throws {
        let nap = CircadianSleepSample(day: today, start: at(0, 14, 0), end: at(0, 14, 45), minutes: 45)
        let snap = snapshot(sleep: baseline() + [nap])
        let wake = try XCTUnwrap(snap.anchor(.wake))
        XCTAssertNil(wake.periodMinutes)
        XCTAssertNotNil(wake.usualMinutes)
    }

    func testAMissedNightStillShowsTheUsualDay() throws {
        let snap = snapshot(sleep: baseline())
        XCTAssertFalse(snap.isEmpty)
        XCTAssertNotNil(snap.anchor(.wake)?.usualMinutes)
        XCTAssertNil(snap.anchor(.wake)?.deltaMinutes)
        XCTAssertEqual(snap.headline, "Your usual day")
    }

    func testGapsInTheBaselineAreTolerated() throws {
        // Every other night missing: 15 of 30 nights is still a usual.
        let sparse = stride(from: -1, through: -29, by: -2).map { night($0) }
        let snap = snapshot(sleep: sparse + [night(0, wake: (7, 40))])
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.deltaMinutes), 40, accuracy: 0.01)
    }

    func testBaselineUsesWhateverHistoryExistsDownToFiveNights() throws {
        XCTAssertNotNil(snapshot(sleep: baseline(5) + [night(0)]).anchor(.wake)?.usualMinutes)
        let four = snapshot(sleep: baseline(4) + [night(0)])
        XCTAssertNil(four.anchor(.wake)?.usualMinutes)
        XCTAssertTrue(four.isLearning)
        XCTAssertEqual(four.headline, "Learning your rhythm")
        XCTAssertEqual(four.subline, "Needs 1 more night")
    }

    func testNightsOlderThanThirtyDaysDoNotCount() throws {
        let old = (35...44).map { night(-$0, bed: (2, 0), wake: (10, 0)) }
        let snap = snapshot(sleep: old + baseline(6) + [night(0)])
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.usualMinutes), 420, accuracy: 0.01)
    }

    func testNothingAtAllIsEmpty() {
        XCTAssertTrue(snapshot().isEmpty)
    }

    // MARK: Meals

    func testSmartMealsNeedTenOfTwentyEightDays() {
        // Spread so no 7-day window holds four of them: only the 28-day rule can apply.
        let nine = stride(from: -3, through: -27, by: -3).map { meal($0, .breakfast, 8, 0) }
        XCTAssertEqual(nine.count, 9)
        XCTAssertNil(snapshot(sleep: baseline(), meals: nine).anchor(.breakfast))
        let ten = nine + [meal(-1, .breakfast, 8, 0)]
        XCTAssertNotNil(snapshot(sleep: baseline(), meals: ten).anchor(.breakfast))
    }

    func testSmartMealsPickUpANewHabitWithinAWeek() {
        let four = [0, -1, -2, -3].map { meal($0, .lunch, 12, 30) }
        XCTAssertNotNil(snapshot(sleep: baseline(), meals: four).anchor(.lunch))
        XCTAssertNil(snapshot(sleep: baseline(), meals: Array(four.prefix(3))).anchor(.lunch))
    }

    func testAnEstablishedMealSurvivesAMissedWeek() throws {
        // Logged daily until a week ago, nothing since: still a habit, and still has a usual.
        let lapsed = (8...27).map { meal(-$0, .dinner, 19, 0) }
        let snap = snapshot(sleep: baseline(), meals: lapsed)
        let dinner = try XCTUnwrap(snap.anchor(.dinner))
        XCTAssertEqual(try XCTUnwrap(dinner.usualMinutes), 1140.0, accuracy: 0.01)
        XCTAssertNil(dinner.periodMinutes)
    }

    func testManualMealChoiceOverridesHowOftenTheyAreLogged() throws {
        var prefs = CircadianPrefs.default
        prefs.mealSelection = .manual
        prefs.showLunch = false
        let daily = (0...20).flatMap { [meal(-$0, .lunch, 12, 30)] }
        let fewBreakfasts = [meal(0, .breakfast, 8, 30)]
        let snap = snapshot(sleep: baseline(), meals: daily + fewBreakfasts, prefs: prefs)
        XCTAssertNil(snap.anchor(.lunch))
        // Chosen by hand but with no usual yet: it sits at today's time with no drift.
        let breakfast = try XCTUnwrap(snap.anchor(.breakfast))
        XCTAssertNil(breakfast.usualMinutes)
        XCTAssertNil(breakfast.deltaMinutes)
        XCTAssertEqual(breakfast.displayMinutes, 510.0, accuracy: 0.01)
    }

    func testMealsHideWhenNutritionOrTheMealSwitchIsOff() {
        let daily = (0...20).map { meal(-$0, .dinner, 19, 0) }
        XCTAssertNil(snapshot(sleep: baseline(), meals: daily, nutritionEnabled: false).anchor(.dinner))
        var prefs = CircadianPrefs.default
        prefs.showMeals = false
        XCTAssertNil(snapshot(sleep: baseline(), meals: daily, prefs: prefs).anchor(.dinner))
    }

    func testAMealUsesTheFirstEntryOfItsTypeThatDay() throws {
        let history = (1...12).map { meal(-$0, .dinner, 19, 0) }
        let today = [meal(0, .dinner, 21, 0), meal(0, .dinner, 19, 45)]
        let snap = snapshot(sleep: baseline(), meals: history + today)
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.dinner)?.deltaMinutes), 45, accuracy: 0.01)
    }

    func testSnacksHaveNoAnchor() {
        XCTAssertNil(CircadianAnchorKind(mealType: .snack))
        XCTAssertEqual(CircadianAnchorKind(mealType: .dinner), .dinner)
    }

    func testAnchorsComeBackInDayOrder() {
        let meals = (0...12).flatMap { [meal(-$0, .dinner, 19, 0), meal(-$0, .breakfast, 8, 0), meal(-$0, .lunch, 13, 0)] }
        let kinds = snapshot(sleep: baseline() + [night(0)], meals: meals).anchors.map(\.kind)
        XCTAssertEqual(kinds, [.wake, .breakfast, .lunch, .dinner, .bed])
    }

    // MARK: Workouts

    func testSmartWorkoutsOnlyShowWhenRegular() {
        let rare = [workout(0), workout(-9), workout(-20)]
        XCTAssertTrue(snapshot(sleep: baseline(), workouts: rare).workouts.isEmpty)
        let regular = [workout(0), workout(-1), workout(-3), workout(-5)]
        XCTAssertEqual(snapshot(sleep: baseline(), workouts: regular).workouts.count, 1)
    }

    func testManualWorkoutsAlwaysShowAndTheSwitchHidesThem() throws {
        var prefs = CircadianPrefs.default
        prefs.workoutSelection = .manual
        let snap = snapshot(sleep: baseline(), workouts: [workout(0, 18, minutes: 45, .strength)], prefs: prefs)
        let span = try XCTUnwrap(snap.workouts.first)
        XCTAssertEqual(span.startMinutes, 1080.0, accuracy: 0.01)
        XCTAssertEqual(span.durationMinutes, 45, accuracy: 0.01)
        XCTAssertEqual(span.category, .strength)
        XCTAssertFalse(span.isTypical)

        prefs.showWorkouts = false
        XCTAssertTrue(snapshot(sleep: baseline(), workouts: [workout(0)], prefs: prefs).workouts.isEmpty)
    }

    func testOnlyTheSelectedDaysWorkoutsAreDrawnAndBlipsAreDropped() {
        var prefs = CircadianPrefs.default
        prefs.workoutSelection = .manual
        let all = [workout(0, 7), workout(0, 18), workout(-1, 18), workout(0, 12, minutes: 2)]
        let spans = snapshot(sleep: baseline(), workouts: all, prefs: prefs).workouts
        XCTAssertEqual(spans.map(\.startMinutes), [420.0, 1080.0])
    }

    func testARangeShowsOneTypicalWorkout() throws {
        let week = CircadianPeriod(scope: .week, start: day(-6), end: today)
        let sessions = [
            workout(0, 18, minutes: 40, .strength), workout(-2, 18, minutes: 50, .strength),
            workout(-4, 18, minutes: 60), workout(-5, 18)
        ]
        let span = try XCTUnwrap(snapshot(period: week, sleep: baseline(20), workouts: sessions).workouts.first)
        XCTAssertTrue(span.isTypical)
        XCTAssertEqual(span.startMinutes, 1080.0, accuracy: 0.01)
        XCTAssertEqual(span.durationMinutes, 48.75, accuracy: 0.01)   // mean of 40, 50, 60, 45
    }

    func testWorkoutTypesMapToTwoIcons() {
        XCTAssertEqual(CircadianWorkoutCategory.from(type: "gym"), .strength)
        XCTAssertEqual(CircadianWorkoutCategory.from(type: "strength"), .strength)
        XCTAssertEqual(CircadianWorkoutCategory.from(type: "run"), .cardio)
        XCTAssertEqual(CircadianWorkoutCategory.from(type: "yoga"), .cardio)
        XCTAssertEqual(CircadianWorkoutCategory.from(type: "something_new"), .cardio)
        XCTAssertEqual(CircadianWorkoutCategory.strength.symbol, "dumbbell.fill")
        XCTAssertEqual(CircadianWorkoutCategory.cardio.symbol, "figure.run")
    }

    // MARK: Ranges

    func testAWeekIsComparedToTheThirtyDaysBeforeIt() throws {
        let week = CircadianPeriod(scope: .week, start: day(-6), end: today)
        let before = (7...30).map { night(-$0) }
        let during = (0...6).map { night(-$0, bed: (23, 40)) }
        let snap = snapshot(period: week, sleep: before + during)
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.bed)?.deltaMinutes), 40, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.deltaMinutes), 0, accuracy: 0.01)
        XCTAssertEqual(snap.headline, "Bedtime ran late")
    }

    func testAWeekWithMissedNightsStillAverages() throws {
        let week = CircadianPeriod(scope: .week, start: day(-6), end: today)
        let before = (7...30).map { night(-$0) }
        let snap = snapshot(period: week, sleep: before + [night(-1, wake: (7, 20)), night(-4, wake: (7, 40))])
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.deltaMinutes), 30, accuracy: 0.01)
    }

    func testARangeWithNoEarlierHistoryShowsItsTypicalDay() throws {
        let month = CircadianPeriod(scope: .month, start: day(-29), end: today)
        let snap = snapshot(period: month, sleep: (0...29).map { night(-$0) })
        XCTAssertFalse(snap.isLearning)
        XCTAssertFalse(snap.hasDrift)
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.displayMinutes), 420, accuracy: 0.01)
        XCTAssertEqual(snap.headline, "Your typical day")
        XCTAssertEqual(snap.subline, "No earlier baseline yet")

        let year = CircadianPeriod(scope: .year, start: day(-364), end: today)
        XCTAssertEqual(snapshot(period: year, sleep: (0...40).map { night(-$0) }).subline, "Past year's average")
    }

    func testAThinRangeIsStillLearning() {
        let week = CircadianPeriod(scope: .week, start: day(-6), end: today)
        let snap = snapshot(period: week, sleep: [night(0), night(-1), night(-2)])
        XCTAssertTrue(snap.isLearning)
        XCTAssertEqual(snap.subline, "Needs 2 more nights")
    }

    // MARK: Headlines

    private func headline(_ deltas: [(CircadianAnchorKind, Double)], scope: CircadianScope = .day) -> (String, String) {
        let anchors = deltas.map { CircadianAnchor(kind: $0.0, usualMinutes: 600, periodMinutes: 600 + $0.1) }
        let copy = CircadianEngine.summary(scope: scope, anchors: anchors, isLearning: false, nightsNeeded: 1)
        return (copy.headline, copy.subline)
    }

    func testHeadlines() {
        XCTAssertEqual(headline([(.wake, -22), (.bed, 14)]).0, "On rhythm")
        XCTAssertEqual(headline([(.wake, -22), (.bed, 14)]).1, "All 2 within 30 min")

        let mealsLate = headline([(.wake, -22), (.breakfast, -15), (.lunch, 50), (.dinner, 60), (.bed, 14)])
        XCTAssertEqual(mealsLate.0, "Meals ran late")
        XCTAssertEqual(mealsLate.1, "Sleep held steady")

        XCTAssertEqual(headline([(.breakfast, -45), (.dinner, 50), (.wake, 5)]).0, "Meals off schedule")
        XCTAssertEqual(headline([(.wake, 40), (.bed, 5), (.lunch, -5)]).0, "Wake-up ran late")
        XCTAssertEqual(headline([(.wake, 40), (.bed, 5), (.lunch, -5)]).1, "Meals held steady")
        XCTAssertEqual(headline([(.wake, 45), (.bed, -50)]).0, "Sleep off schedule")
        XCTAssertEqual(headline([(.wake, 45), (.lunch, -40)]).0, "Off rhythm")
        XCTAssertEqual(headline([(.wake, 45), (.lunch, -40), (.bed, 3)]).1, "1 of 3 within 30 min")

        let late = headline([(.wake, 35), (.lunch, 40), (.bed, 45)])
        XCTAssertEqual(late.0, "Running late")
        XCTAssertEqual(late.1, "About 40m later")
        XCTAssertEqual(headline([(.wake, 18), (.lunch, 10), (.bed, 62)], scope: .week).0, "Shifted later")
        XCTAssertEqual(headline([(.wake, -35), (.bed, -45)]).0, "Running early")

        // Every line has to fit inside the dial.
        for copy in [mealsLate, late, headline([(.wake, 45), (.lunch, -40)]), headline([(.wake, -22), (.bed, 14)])] {
            XCTAssertLessThanOrEqual(copy.1.count, 24, copy.1)
        }
    }

    // MARK: Formatting

    func testFormatting() {
        XCTAssertEqual(CircadianFormat.duration(22), "22m")
        XCTAssertEqual(CircadianFormat.duration(60), "1h")
        XCTAssertEqual(CircadianFormat.duration(65), "1h 5m")
        XCTAssertEqual(CircadianFormat.signed(50), "+50m")
        XCTAssertEqual(CircadianFormat.signed(-22), "\u{2212}22m")
        XCTAssertEqual(CircadianFormat.words(-22), "22m earlier")
        XCTAssertEqual(CircadianFormat.words(60), "1h later")
        XCTAssertEqual(CircadianFormat.words(0.2), "On time")
        XCTAssertEqual(CircadianFormat.spoken(-82), "1 hour 22 minutes earlier than usual")
        XCTAssertEqual(CircadianFormat.clock(423), "7:03 AM")
        XCTAssertEqual(CircadianFormat.clock(0), "12:00 AM")
        XCTAssertEqual(CircadianFormat.clock(765.0), "12:45 PM")
        XCTAssertEqual(CircadianFormat.clock(1439.7), "12:00 AM")
    }

    // MARK: Prefs

    func testPrefsDefaultToOnAndSmart() {
        let prefs = CircadianPrefs.default
        XCTAssertTrue(prefs.enabled)
        XCTAssertTrue(prefs.showMeals)
        XCTAssertTrue(prefs.showWorkouts)
        XCTAssertEqual(prefs.mealSelection, .smart)
        XCTAssertEqual(prefs.workoutSelection, .smart)
    }

    func testPrefsDecodeTolerantlyAndPersist() throws {
        let partial = try JSONDecoder().decode(CircadianPrefs.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertFalse(partial.enabled)
        XCTAssertTrue(partial.showMeals)
        XCTAssertEqual(try JSONDecoder().decode(CircadianPrefs.self, from: Data("{}".utf8)), .default)

        let suite = "circadian-prefs-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CircadianPrefsStore(defaults: defaults)
        XCTAssertTrue(store.prefs.enabled)
        store.prefs.enabled = false
        store.prefs.mealSelection = .manual
        store.prefs.showDinner = false
        let reloaded = CircadianPrefsStore(defaults: defaults).prefs
        XCTAssertFalse(reloaded.enabled)
        XCTAssertEqual(reloaded.mealSelection, .manual)
        XCTAssertFalse(reloaded.showDinner)
        XCTAssertFalse(reloaded.includesMeal(.dinner))
        XCTAssertTrue(reloaded.includesMeal(.lunch))
    }

    // MARK: Dial geometry

    func testSemicircleRunsFourAMToFourAMLeftToRight() {
        let dial = CircadianDialGeometry(shape: .semicircle)
        let center = CGPoint(x: 100, y: 100)
        let start = dial.point(240.0, radius: 50, center: center)
        XCTAssertEqual(start.x, 50, accuracy: 0.01)
        XCTAssertEqual(start.y, 100, accuracy: 0.01)
        let apex = dial.point(960.0, radius: 50, center: center)   // 4 PM, halfway through the day
        XCTAssertEqual(apex.x, 100, accuracy: 0.01)
        XCTAssertEqual(apex.y, 50, accuracy: 0.01)
        let late = dial.point(239.0, radius: 50, center: center)
        XCTAssertGreaterThan(late.x, 149.9)
        // Nothing ever lands below the baseline.
        for minute in stride(from: 0.0, to: 1440, by: 30) {
            XCTAssertLessThanOrEqual(dial.point(minute, radius: 50, center: center).y, 100.01)
        }
    }

    func testFullDialPutsNoonOnTopAndMidnightAtTheBottom() {
        let dial = CircadianDialGeometry(shape: .full)
        let center = CGPoint(x: 100, y: 100)
        XCTAssertEqual(dial.point(720.0, radius: 50, center: center).y, 50, accuracy: 0.01)
        XCTAssertEqual(dial.point(0, radius: 50, center: center).y, 150, accuracy: 0.01)
        XCTAssertEqual(dial.point(1080.0, radius: 50, center: center).x, 150, accuracy: 0.01)
        XCTAssertEqual(dial.point(360.0, radius: 50, center: center).x, 50, accuracy: 0.01)
    }

    func testOvernightSleepSplitsAtTheSemicircleSeam() {
        let bed = 22.0 * 60 + 48, wake = 7.0 * 60 + 3
        let semi = CircadianDialGeometry(shape: .semicircle)
        let pieces = semi.arcs(from: bed, to: wake)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.sweep).reduce(0, +), 495 * semi.sweepPerMinute, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].startAngle, .pi, accuracy: 1e-9)   // resumes at the left foot

        let full = CircadianDialGeometry(shape: .full)
        XCTAssertEqual(full.arcs(from: bed, to: wake).count, 1)
        XCTAssertEqual(full.arcs(from: bed, to: wake)[0].sweep, 495 * full.sweepPerMinute, accuracy: 1e-9)
        XCTAssertEqual(semi.arcs(from: 1080.0, to: 1125.0).count, 1)
        XCTAssertTrue(semi.arcs(from: 600, to: 600).isEmpty)
    }

    func testSpreadSeparatesCloseMarkersWithoutReordering() {
        let input = [7.0 * 60, 7.0 * 60 + 30, 13.0 * 60, 23.0 * 60]
        let out = CircadianDialGeometry.spread(input, minGap: 80)
        XCTAssertEqual(out[1] - out[0], 80, accuracy: 0.1)
        XCTAssertEqual((out[0] + out[1]) / 2, (input[0] + input[1]) / 2, accuracy: 0.1)   // pushed symmetrically
        XCTAssertEqual(out[2], input[2], accuracy: 0.01)
        XCTAssertEqual(out[3], input[3], accuracy: 0.01)
        XCTAssertEqual(CircadianDialGeometry.spread([600], minGap: 80), [600])
    }

    func testOverlappingLabelsAreDroppedInPriorityOrder() {
        let a = CGRect(x: 0, y: 0, width: 30, height: 14)
        let b = CGRect(x: 20, y: 5, width: 30, height: 14)
        let c = CGRect(x: 100, y: 0, width: 30, height: 14)
        XCTAssertEqual(CircadianDialGeometry.keepLabels([a, b, c]), [true, false, true])
    }

    // MARK: Coach hand-off

    func testCoachPromptsAndContext() {
        let meals = (0...12).map { meal(-$0, .dinner, $0 == 0 ? 20 : 19, 0) }
        let snap = snapshot(sleep: baseline() + [night(0)], meals: meals)
        XCTAssertEqual(snap.coachPrompts.count, 3)
        XCTAssertEqual(snap.coachPrompts.first, "How does eating later than usual affect my sleep?")
        XCTAssertTrue(snap.coachContext.contains("dinner 8:00 PM (usual 7:00 PM, 1h later)"))
        XCTAssertTrue(snap.coachContext.contains("wake 7:00 AM"))
        XCTAssertEqual(snapshot(sleep: [night(0)]).coachPrompts.count, 3)
    }

    // MARK: Store integration

    func testServiceReadsSleepMealsAndWorkoutsFromTheStore() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func moment(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        for offset in 0...12 {
            let wakeDay = calendar.date(byAdding: .day, value: -offset, to: today)!
            let late = offset == 0
            context.insert(SleepSession(
                date: wakeDay, startAt: moment(-offset - 1, 23), endAt: moment(-offset, late ? 8 : 7), totalMinutes: late ? 540 : 480))
            context.insert(MealEntry(timestamp: moment(-offset, 19), name: "Dinner", mealType: .dinner, calories: 600))
            context.insert(MealEntry(timestamp: moment(-offset, 16), name: "Snack", mealType: .snack, calories: 100))
        }
        for offset in [0, 1, 2, 4] {
            context.insert(ActivitySession(
                type: "gym", status: .finished, startedAt: moment(-offset, 18), endedAt: moment(-offset, 18, 45)))
        }
        // Still recording: must not appear.
        context.insert(ActivitySession(type: "run", status: .recording, startedAt: moment(0, 6)))
        try context.save()

        let period = CircadianPeriod(scope: .day, start: today, end: today)
        let snap = CircadianService.snapshot(period: period, context: context, prefs: .default, nutritionEnabled: true)
        XCTAssertEqual(snap.anchors.map(\.kind), [.wake, .dinner, .bed])
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.wake)?.deltaMinutes), 60, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(snap.anchor(.dinner)?.deltaMinutes), 0, accuracy: 0.5)
        XCTAssertEqual(snap.workouts.count, 1)
        XCTAssertEqual(snap.workouts.first?.category, .strength)
        XCTAssertEqual(try XCTUnwrap(snap.workouts.first?.durationMinutes), 45, accuracy: 0.5)
        XCTAssertEqual(snap.headline, "Wake-up ran late")

        let withoutNutrition = CircadianService.snapshot(period: period, context: context, prefs: .default, nutritionEnabled: false)
        XCTAssertEqual(withoutNutrition.anchors.map(\.kind), [.wake, .bed])
    }
}
