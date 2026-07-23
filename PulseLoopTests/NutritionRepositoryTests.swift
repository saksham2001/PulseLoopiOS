import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class NutritionRepositoryTests: XCTestCase {

    private func insertMeal(
        timestamp: Date = Date(),
        name: String = "Test meal",
        mealType: MealType = .lunch,
        calories: Double = 500,
        proteinG: Double = 30,
        carbsG: Double = 50,
        fatG: Double = 15,
        fiberG: Double? = nil,
        into context: ModelContext
    ) -> MealEntry {
        let entry = MealEntry(
            timestamp: timestamp, name: name, mealType: mealType,
            calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG, fiberG: fiberG
        )
        NutritionRepository.insert(entry, context: context)
        return entry
    }

    // MARK: Day bucketing

    func testEntriesAreBucketedByStartOfDay() throws {
        let context = try TestSupport.makeContext()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        _ = insertMeal(timestamp: today, name: "Today meal", into: context)
        _ = insertMeal(timestamp: yesterday, name: "Yesterday meal", into: context)

        let todayEntries = NutritionRepository.entries(on: today, context: context)
        XCTAssertEqual(todayEntries.map(\.name), ["Today meal"])
        let yesterdayEntries = NutritionRepository.entries(on: yesterday, context: context)
        XCTAssertEqual(yesterdayEntries.map(\.name), ["Yesterday meal"])
    }

    func testLateNightEntryStaysOnItsCalendarDay() throws {
        let context = try TestSupport.makeContext()
        // 23:30 tonight belongs to today, not tomorrow.
        let lateTonight = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        _ = insertMeal(timestamp: lateTonight, into: context)
        XCTAssertEqual(NutritionRepository.entries(on: Date(), context: context).count, 1)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertTrue(NutritionRepository.entries(on: tomorrow, context: context).isEmpty)
    }

    func testSetTimestampMovesDayBucket() throws {
        let context = try TestSupport.makeContext()
        let entry = insertMeal(into: context)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        entry.setTimestamp(yesterday)
        NutritionRepository.update(entry, context: context)
        XCTAssertTrue(NutritionRepository.entries(on: Date(), context: context).isEmpty)
        XCTAssertEqual(NutritionRepository.entries(on: yesterday, context: context).count, 1)
    }

    // MARK: Totals

    func testDayTotalsSumMacros() throws {
        let context = try TestSupport.makeContext()
        _ = insertMeal(calories: 400, proteinG: 20, carbsG: 40, fatG: 10, into: context)
        _ = insertMeal(calories: 600, proteinG: 35, carbsG: 55, fatG: 22, into: context)

        let totals = NutritionRepository.dayTotals(on: Date(), context: context)
        XCTAssertEqual(totals.calories, 1000)
        XCTAssertEqual(totals.proteinG, 55)
        XCTAssertEqual(totals.carbsG, 95)
        XCTAssertEqual(totals.fatG, 32)
        XCTAssertEqual(totals.entryCount, 2)
    }

    func testOptionalNutrientsStayNilWhenNoEntryReportsThem() throws {
        let context = try TestSupport.makeContext()
        _ = insertMeal(into: context)
        let totals = NutritionRepository.dayTotals(on: Date(), context: context)
        // Unknown must stay distinct from 0.
        XCTAssertNil(totals.fiberG)
        XCTAssertNil(totals.sugarG)
        XCTAssertNil(totals.sodiumMg)
    }

    func testOptionalNutrientsSumOnlyReportingEntries() throws {
        let context = try TestSupport.makeContext()
        _ = insertMeal(fiberG: 5, into: context)
        _ = insertMeal(fiberG: nil, into: context)
        let totals = NutritionRepository.dayTotals(on: Date(), context: context)
        XCTAssertEqual(totals.fiberG, 5)
    }

    func testEmptyDayTotalsAreZero() throws {
        let context = try TestSupport.makeContext()
        let totals = NutritionRepository.dayTotals(on: Date(), context: context)
        XCTAssertEqual(totals.calories, 0)
        XCTAssertEqual(totals.entryCount, 0)
    }

    // MARK: CRUD

    func testDeleteRemovesEntry() throws {
        let context = try TestSupport.makeContext()
        let entry = insertMeal(into: context)
        NutritionRepository.delete(id: entry.id, context: context)
        XCTAssertNil(NutritionRepository.entry(id: entry.id, context: context))
        XCTAssertFalse(NutritionRepository.hasAnyEntry(context: context))
    }

    func testHasAnyEntryAndLatestUpdate() throws {
        let context = try TestSupport.makeContext()
        XCTAssertFalse(NutritionRepository.hasAnyEntry(context: context))
        XCTAssertNil(NutritionRepository.latestEntryUpdate(context: context))
        _ = insertMeal(into: context)
        XCTAssertTrue(NutritionRepository.hasAnyEntry(context: context))
        XCTAssertNotNil(NutritionRepository.latestEntryUpdate(context: context))
    }

    // MARK: Product cache

    func testProductCacheUpsertTouchAndPrune() throws {
        let context = try TestSupport.makeContext()
        for index in 0..<5 {
            let product = CachedFoodProduct(code: "code-\(index)", name: "Product \(index)", energyKcal100g: 100)
            // All in the past, oldest-first, so a touch below is unambiguously the most recent.
            product.lastUsedAt = Date().addingTimeInterval(Double(index - 60))
            context.insert(product)
        }
        try context.save()

        let cached = NutritionRepository.cachedProduct(code: "code-3", context: context)
        XCTAssertEqual(cached?.name, "Product 3")
        NutritionRepository.touchProduct(cached!)
        XCTAssertEqual(cached?.useCount, 1)
        // touchProduct deliberately doesn't save (callers batch it with the meal insert);
        // fetch sorting only sees saved values, so persist before asserting order.
        try context.save()

        let recents = NutritionRepository.recentProducts(limit: 2, context: context)
        XCTAssertEqual(recents.count, 2)
        XCTAssertEqual(recents.first?.code, "code-3")   // just touched → most recent

        NutritionRepository.pruneProductCache(maxRows: 2, context: context)
        let remaining = NutritionRepository.recentProducts(limit: 10, context: context)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.code)), ["code-3", "code-4"])
    }

    // MARK: TodaySummary integration

    func testTodaySummaryNutritionGatedOnMasterToggle() throws {
        let context = try TestSupport.makeContext()
        _ = insertMeal(calories: 750, into: context)

        let store = NutritionPrefsStore.shared
        let original = store.prefs
        defer { store.prefs = original }

        store.prefs.masterEnabled = false
        XCTAssertNil(MetricsService.buildTodaySummary(context: context).nutrition)

        store.prefs.masterEnabled = true
        let nutrition = MetricsService.buildTodaySummary(context: context).nutrition
        XCTAssertEqual(nutrition?.calories, 750)
    }

    func testGoalsSummaryCarriesIntakeGoals() throws {
        let context = try TestSupport.makeContext()
        let goal = UserGoal()
        goal.intakeCalories = 2200
        goal.intakeProteinG = 140
        context.insert(goal)
        try context.save()

        let goals = MetricsService.buildTodaySummary(context: context).goals
        XCTAssertEqual(goals.intakeCalories, 2200)
        XCTAssertEqual(goals.intakeProteinG, 140)
        XCTAssertNil(goals.intakeCarbsG)
    }
}
