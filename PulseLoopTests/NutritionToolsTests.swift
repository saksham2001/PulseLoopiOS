import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// Stub food-database client for tool tests.
private struct StubFoodClient: FoodDatabaseClient {
    var products: [FoodProduct] = []
    var searchError: Error?
    nonisolated(unsafe) static var searchCalls = 0

    func product(barcode: String) async throws -> FoodProduct? {
        products.first { $0.code == barcode }
    }

    func search(query: String, pageSize: Int) async throws -> [FoodProduct] {
        Self.searchCalls += 1
        if let searchError { throw searchError }
        return products
    }
}

@MainActor
final class NutritionToolsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubFoodClient.searchCalls = 0
    }

    private func flags(write: Bool = true, share: Bool = true) -> CoachFeatureFlags {
        var s = CoachSettings.default
        s.coachMasterEnabled = true
        s.enableWriteTools = write
        var n = NutritionPrefs.default
        n.masterEnabled = true
        n.shareWithCoach = share
        return CoachFeatureFlags(settings: s, hasAPIKey: true, nutritionPrefs: n)
    }

    private func ctx(_ c: ModelContext, client: FoodDatabaseClient? = nil, write: Bool = true) -> ToolExecutionContext {
        ToolExecutionContext(modelContext: c, flags: flags(write: write), foodClient: client)
    }

    private func tool(_ name: String, write: Bool = true) throws -> AnyCoachTool {
        try XCTUnwrap(ToolRegistry(flags: flags(write: write)).tool(named: name))
    }

    private func parse(_ result: ToolResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any])
    }

    private let sampleProduct = FoodProduct(
        code: "111", name: "Rolled Oats", brand: "Brand",
        energyKcal100g: 379, protein100g: 13, carbs100g: 68, fat100g: 6.5,
        fiber100g: 10, sugars100g: 1, saturatedFat100g: 1.2, sodiumMg100g: 6,
        servingSizeText: "40 g", servingQuantityG: 40
    )

    // MARK: Gating

    func testToolsAbsentWhenFlagsOff() throws {
        // Feature off entirely.
        var s = CoachSettings.default
        s.coachMasterEnabled = true
        s.enableWriteTools = true
        let off = CoachFeatureFlags(settings: s, hasAPIKey: true)   // default prefs = off
        XCTAssertNil(ToolRegistry(flags: off).tool(named: "log_meal"))
        XCTAssertNil(ToolRegistry(flags: off).tool(named: "search_food_database"))

        // Shared but write tools off → read tool only.
        let readOnly = ToolRegistry(flags: flags(write: false))
        XCTAssertNotNil(readOnly.tool(named: "search_food_database"))
        XCTAssertNotNil(readOnly.tool(named: "get_nutrition_log"))
        XCTAssertNil(readOnly.tool(named: "log_meal"))
        XCTAssertNil(readOnly.tool(named: "delete_meal_entry"))
    }

    // MARK: search_food_database

    func testSearchCacheFirstSkipsClient() async throws {
        let c = try TestSupport.makeContext()
        NutritionRepository.upsertCachedProduct(sampleProduct, context: c)
        let result = try await tool("search_food_database").run(
            Data(#"{"query":"oats","max_results":5}"#.utf8),
            ctx(c, client: StubFoodClient(products: [sampleProduct]))
        )
        let parsed = try parse(result)
        XCTAssertEqual(parsed["source"] as? String, "local_cache")
        XCTAssertEqual(StubFoodClient.searchCalls, 0, "warm cache must not hit the API")
    }

    func testSearchFallsThroughToClientAndCaches() async throws {
        let c = try TestSupport.makeContext()
        let result = try await tool("search_food_database").run(
            Data(#"{"query":"oats","max_results":5}"#.utf8),
            ctx(c, client: StubFoodClient(products: [sampleProduct]))
        )
        let parsed = try parse(result)
        XCTAssertEqual(parsed["source"] as? String, "open_food_facts")
        XCTAssertEqual(StubFoodClient.searchCalls, 1)
        XCTAssertNotNil(NutritionRepository.cachedProduct(code: "111", context: c), "results get cached")
    }

    func testSearchFailureInstructsLabeledEstimate() async throws {
        let c = try TestSupport.makeContext()
        let failing = StubFoodClient(products: [], searchError: OpenFoodFactsError.rateLimited)
        let result = try await tool("search_food_database").run(
            Data(#"{"query":"oats","max_results":null}"#.utf8), ctx(c, client: failing)
        )
        let parsed = try parse(result)
        XCTAssertEqual(parsed["ok"] as? Bool, false)
        XCTAssertTrue((parsed["instruction"] as? String ?? "").contains("estimate"),
                      "model must be told to fall back to a labeled estimate")
    }

    // MARK: log_meal

    func testLogMealWritesEntryAndSurfacesCard() async throws {
        let c = try TestSupport.makeContext()
        let context = ctx(c)
        let args = #"{"name":"Chicken salad","meal_type":"lunch","date":"2026-07-23","time":"12:30","#
            + #""calories":520,"protein_g":32,"carbs_g":18,"fat_g":30,"fiber_g":null,"sugar_g":null,"#
            + #""sodium_mg":null,"quantity":null,"serving_description":"1 bowl","source":"estimate","#
            + #""off_product_code":null,"confidence":"medium","notes":null}"#
        let result = try await tool("log_meal").run(Data(args.utf8), context)
        XCTAssertEqual((try parse(result))["ok"] as? Bool, true)

        XCTAssertEqual(context.loggedMealIds.count, 1, "immediate write drives the in-chat card")
        let entry = try XCTUnwrap(NutritionRepository.entry(id: context.loggedMealIds[0], context: c))
        XCTAssertEqual(entry.name, "Chicken salad")
        XCTAssertEqual(entry.calories, 520)
        XCTAssertEqual(entry.mealType, .lunch)
        XCTAssertEqual(entry.source, .llmEstimate)
        XCTAssertTrue(entry.loggedByCoach)
        XCTAssertEqual(Calendar.current.component(.hour, from: entry.timestamp), 12)
    }

    func testLogMealDatabaseSourceMapsToOffSearch() async throws {
        let c = try TestSupport.makeContext()
        let context = ctx(c)
        let args = #"{"name":"Oats","meal_type":"breakfast","date":"2026-07-23","time":null,"#
            + #""calories":152,"protein_g":5,"carbs_g":27,"fat_g":3,"fiber_g":4,"sugar_g":null,"#
            + #""sodium_mg":null,"quantity":1,"serving_description":"40 g","source":"database","#
            + #""off_product_code":"111","confidence":"high","notes":null}"#
        _ = try await tool("log_meal").run(Data(args.utf8), context)
        let entry = try XCTUnwrap(NutritionRepository.entry(id: context.loggedMealIds[0], context: c))
        XCTAssertEqual(entry.source, .offSearch)
        XCTAssertEqual(entry.offProductCode, "111")
    }

    func testLogMealRejectsImplausibleCalories() async throws {
        let c = try TestSupport.makeContext()
        let args = #"{"name":"x","meal_type":"snack","date":"2026-07-23","time":null,"calories":99999,"#
            + #""protein_g":null,"carbs_g":null,"fat_g":null,"fiber_g":null,"sugar_g":null,"#
            + #""sodium_mg":null,"quantity":null,"serving_description":null,"source":"estimate","#
            + #""off_product_code":null,"confidence":"low","notes":null}"#
        let result = try await tool("log_meal").run(Data(args.utf8), ctx(c))
        XCTAssertTrue(result.isError)
    }

    // MARK: update / delete

    func testUpdateTodayImmediateOlderNeedsConfirmation() async throws {
        let c = try TestSupport.makeContext()
        // An estimate entry: a coach correction must flip `userEdited` (manual entries don't).
        let today = MealEntry(timestamp: Date(), name: "Toast", mealType: .breakfast, calories: 200, source: .llmEstimate)
        let older = MealEntry(timestamp: TestSupport.day(-2).addingTimeInterval(12 * 3600), name: "Pasta", mealType: .dinner, calories: 700)
        c.insert(today); c.insert(older)
        try c.save()

        let context = ctx(c)
        let updateToday = #"{"meal_id":"\#(today.id.uuidString)","name":null,"meal_type":null,"calories":250,"protein_g":null,"carbs_g":null,"fat_g":null,"notes":null,"reason":"user corrected"}"#
        let r1 = try await tool("update_meal_entry").run(Data(updateToday.utf8), context)
        XCTAssertEqual((try parse(r1))["updated"] as? Bool, true)
        XCTAssertEqual(today.calories, 250)
        XCTAssertTrue(today.userEdited, "coach correction flips provenance honesty flag")
        XCTAssertEqual(context.loggedMealIds, [today.id])

        let updateOlder = #"{"meal_id":"\#(older.id.uuidString)","name":null,"meal_type":null,"calories":650,"protein_g":null,"carbs_g":null,"fat_g":null,"notes":null,"reason":"user corrected"}"#
        let r2 = try await tool("update_meal_entry").run(Data(updateOlder.utf8), context)
        XCTAssertEqual((try parse(r2))["needs_confirmation"] as? Bool, true)
        XCTAssertEqual(older.calories, 700, "not applied until confirmed")
        XCTAssertEqual(context.pendingActions.count, 1)

        // Confirm → executor applies.
        let outcome = PendingActionExecutor.execute(context.pendingActions[0], context: c)
        XCTAssertTrue(outcome.contains("Updated"))
        XCTAssertEqual(older.calories, 650)
    }

    func testDeleteAlwaysNeedsConfirmationThenExecutorDeletes() async throws {
        let c = try TestSupport.makeContext()
        let entry = MealEntry(timestamp: Date(), name: "Soda", mealType: .snack, calories: 140)
        c.insert(entry)
        try c.save()

        let context = ctx(c)
        let args = #"{"meal_id":"\#(entry.id.uuidString)","reason":"logged twice"}"#
        let result = try await tool("delete_meal_entry").run(Data(args.utf8), context)
        XCTAssertEqual((try parse(result))["needs_confirmation"] as? Bool, true)
        XCTAssertNotNil(NutritionRepository.entry(id: entry.id, context: c), "not deleted yet")

        let outcome = PendingActionExecutor.execute(context.pendingActions[0], context: c)
        XCTAssertTrue(outcome.contains("Deleted"))
        XCTAssertNil(NutritionRepository.entry(id: entry.id, context: c))
    }

    // MARK: get_nutrition_log

    func testGetNutritionLogReturnsDayTotals() async throws {
        let c = try TestSupport.makeContext()
        let entry = MealEntry(timestamp: Date(), name: "Eggs", mealType: .breakfast, calories: 180, proteinG: 12)
        c.insert(entry)
        try c.save()
        let dateString = CoachDataAccess.localDateString(Date())
        let result = try await tool("get_nutrition_log", write: false).run(
            Data(#"{"date":"\#(dateString)"}"#.utf8), ctx(c, write: false)
        )
        let parsed = try parse(result)
        XCTAssertEqual(parsed["entry_count"] as? Int, 1)
        let totals = try XCTUnwrap(parsed["totals"] as? [String: Any])
        XCTAssertEqual(totals["kcal"] as? Double, 180)
    }
}

// MARK: set_goal intake extension

@MainActor
final class SetGoalNutritionTests: XCTestCase {
    private func flags() -> CoachFeatureFlags {
        var s = CoachSettings.default
        s.enableWriteTools = true
        return CoachFeatureFlags(settings: s, hasAPIKey: true)
    }

    func testIntakeGoalTypesWriteUserGoalOptionals() async throws {
        let c = try TestSupport.makeContext()
        let registry = ToolRegistry(flags: flags())
        let tool = try XCTUnwrap(registry.tool(named: "set_goal"))
        let ctx = ToolExecutionContext(modelContext: c, flags: flags())

        for (type, target) in [("calorie_intake", 2200.0), ("protein_g", 140.0), ("carbs_g", 220.0), ("fat_g", 70.0)] {
            _ = try await tool.run(Data(#"{"goal_type":"\#(type)","target":\#(target),"reason":"coach plan"}"#.utf8), ctx)
        }
        let goal = try XCTUnwrap(MetricsRepository.goals(context: c))
        XCTAssertEqual(goal.intakeCalories, 2200)
        XCTAssertEqual(goal.intakeProteinG, 140)
        XCTAssertEqual(goal.intakeCarbsG, 220)
        XCTAssertEqual(goal.intakeFatG, 70)
        // Burn goal untouched.
        XCTAssertEqual(goal.calories, 500)
        // Old types still work.
        _ = try await tool.run(Data(#"{"goal_type":"steps","target":12000,"reason":"x"}"#.utf8), ctx)
        XCTAssertEqual(goal.steps, 12000)
    }
}

// MARK: context injection

@MainActor
final class NutritionContextTests: XCTestCase {

    private func withPrefs(master: Bool, share: Bool = true, _ body: () throws -> Void) rethrows {
        let store = NutritionPrefsStore.shared
        let original = store.prefs
        defer { store.prefs = original }
        store.prefs.masterEnabled = master
        store.prefs.shareWithCoach = share
        try body()
    }

    func testPacketNutritionNilWhenDisabledOrUnshared() throws {
        let c = try TestSupport.makeContext()
        try withPrefs(master: false) {
            XCTAssertNil(CoachContextBuilder.build(context: c).nutrition)
        }
        try withPrefs(master: true, share: false) {
            XCTAssertNil(CoachContextBuilder.build(context: c).nutrition)
        }
        try withPrefs(master: true) {
            XCTAssertNil(CoachContextBuilder.build(context: c, includeNutrition: false).nutrition,
                         "caller opt-out (notification sub-toggle) wins")
        }
    }

    func testPacketNutritionPopulatedAndSnakeCased() throws {
        let c = try TestSupport.makeContext()
        let goal = UserGoal()
        goal.intakeCalories = 2200
        c.insert(goal)
        c.insert(MealEntry(timestamp: Date(), name: "Eggs", mealType: .breakfast, calories: 180, proteinG: 12))
        try c.save()

        try withPrefs(master: true) {
            let packet = CoachContextBuilder.build(context: c)
            let nutrition = try XCTUnwrap(packet.nutrition)
            XCTAssertEqual(nutrition.caloriesConsumed, 180)
            XCTAssertEqual(nutrition.mealsLoggedToday, 1)
            XCTAssertEqual(nutrition.mealsToday.first?.name, "Eggs")
            XCTAssertEqual(packet.goals.calorieIntakeDaily, 2200)

            // Wire shape: snake_case, and the developer message carries the addendum.
            let message = CoachPromptBuilder.developerMessage(packet: packet)
            XCTAssertTrue(message.contains("\"calories_consumed\""))
            XCTAssertTrue(message.contains("calorie_intake_daily"))
            XCTAssertTrue(message.contains("log_meal"), "nutrition addendum appended")
        }
    }

    func testDeveloperMessageOmitsAddendumWithoutNutrition() throws {
        let c = try TestSupport.makeContext()
        try withPrefs(master: false) {
            let packet = CoachContextBuilder.build(context: c)
            let message = CoachPromptBuilder.developerMessage(packet: packet)
            XCTAssertFalse(message.contains("Nutrition tracking is enabled"))
        }
    }
}
