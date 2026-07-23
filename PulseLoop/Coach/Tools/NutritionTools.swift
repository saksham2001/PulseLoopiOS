import Foundation
import SwiftData

/// Nutrition tools. Read tools (grounding) are available whenever nutrition context is shared
/// with the coach; write tools additionally require `enableWriteTools`. Same risk model as
/// `ActionTools`: logging a meal applies immediately (rendered as an in-chat meal card the
/// user can tap to adjust); edits to today's entries apply immediately; edits to older
/// entries and every delete go through a Confirm/Cancel `PendingAction`.
@MainActor
enum NutritionTools {
    static var readTools: [AnyCoachTool] { [searchFoodDatabase, getNutritionLog] }
    static var writeTools: [AnyCoachTool] { [logMeal, updateMealEntry, deleteMealEntry] }

    private static let mealTypeEnum = MealType.allCases.map(\.rawValue)

    // MARK: search_food_database

    private struct SearchArgs: Decodable {
        let query: String, maxResults: Double?
        enum CodingKeys: String, CodingKey { case query, maxResults = "max_results" }
    }

    /// Grounding tool: cache-first, then Open Food Facts. On rate-limit or network failure it
    /// returns a structured error instructing the model to fall back to a *labeled* estimate —
    /// numbers are grounded or flagged, never silently invented.
    private static var searchFoodDatabase: AnyCoachTool {
        .make(
            name: "search_food_database",
            label: "Checking the food database",
            description: "Search Open Food Facts for a food's verified nutrition (per 100 g). "
                + "Use before logging any nameable or packaged food. "
                + "If it errors, estimate instead and say so, with source 'estimate'.",
            parameters: JSONSchema.object([
                "query": JSONSchema.string,
                "max_results": ["type": ["number", "null"]],
            ], required: ["query", "max_results"]),
            argsType: SearchArgs.self
        ) { args, ctx in
            let limit = min(5, max(1, Int(args.maxResults ?? 5)))
            let query = args.query.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { return .error("query too short") }

            // Cache-first: substring match against locally cached products (zero network).
            let cachedMatches = NutritionRepository.recentProducts(limit: 100, context: ctx.modelContext)
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .prefix(limit)
                .map { $0.asFoodProduct() }
            if !cachedMatches.isEmpty {
                return .object(["ok": true, "source": "local_cache", "results": cachedMatches.map(payload)])
            }

            guard let client = ctx.foodClient else {
                return .object(["ok": false, "error": "database_unavailable",
                                "instruction": "Food database unavailable. Estimate nutrition yourself, set source to 'estimate', and tell the user the numbers are estimated."])
            }
            do {
                let results = try await client.search(query: query, pageSize: limit)
                for product in results {
                    NutritionRepository.upsertCachedProduct(product, context: ctx.modelContext)
                }
                return .object(["ok": true, "source": "open_food_facts", "results": results.map(payload)])
            } catch {
                return .object(["ok": false, "error": "lookup_failed",
                                "instruction": "Food database lookup failed. Estimate nutrition yourself, set source to 'estimate', and tell the user the numbers are estimated."])
            }
        }
    }

    private static func payload(_ product: FoodProduct) -> [String: Any] {
        var dict: [String: Any] = [
            "code": product.code,
            "name": product.name,
            "per_100g": [
                "kcal": product.energyKcal100g.rounded(),
                "protein_g": product.protein100g,
                "carbs_g": product.carbs100g,
                "fat_g": product.fat100g,
            ],
        ]
        if let brand = product.brand { dict["brand"] = brand }
        if let serving = product.servingSizeText { dict["serving"] = serving }
        if let grams = product.servingQuantityG { dict["serving_g"] = grams }
        return dict
    }

    // MARK: get_nutrition_log

    private struct LogArgs: Decodable {
        let date: String
    }

    /// Read tool: the day's logged meals + totals, so the coach can answer "what did I eat"
    /// for any day without the packet carrying history.
    private static var getNutritionLog: AnyCoachTool {
        .make(
            name: "get_nutrition_log",
            label: "Reading your food log",
            description: "Get the user's logged meals and calorie/macro totals for a date (YYYY-MM-DD).",
            parameters: JSONSchema.object(["date": JSONSchema.string], required: ["date"]),
            argsType: LogArgs.self
        ) { args, ctx in
            guard let day = CoachDataAccess.parseLocalDate(args.date) else {
                return .error("invalid date '\(args.date)' — use YYYY-MM-DD")
            }
            let entries = NutritionRepository.entries(on: day, context: ctx.modelContext)
            let totals = NutritionRepository.totals(of: entries)
            let meals: [[String: Any]] = entries.map { entry in
                [
                    "meal_id": entry.id.uuidString,
                    "name": entry.name,
                    "meal_type": entry.mealTypeRaw,
                    "time": CoachDataAccess.localTimeString(entry.timestamp),
                    "kcal": entry.calories.rounded(),
                    "protein_g": entry.proteinG,
                    "carbs_g": entry.carbsG,
                    "fat_g": entry.fatG,
                    "source": entry.sourceRaw,
                ]
            }
            return .object([
                "ok": true, "date": args.date, "entry_count": totals.entryCount,
                "totals": ["kcal": totals.calories.rounded(), "protein_g": totals.proteinG,
                           "carbs_g": totals.carbsG, "fat_g": totals.fatG],
                "meals": meals,
            ])
        }
    }

    // MARK: log_meal

    private struct LogMealArgs: Decodable {
        let name: String, mealType: String, date: String, time: String?
        let calories: Double, proteinG: Double?, carbsG: Double?, fatG: Double?
        let fiberG: Double?, sugarG: Double?, sodiumMg: Double?
        let quantity: Double?, servingDescription: String?
        let source: String, offProductCode: String?, confidence: String, notes: String?
        enum CodingKeys: String, CodingKey {
            case name, mealType = "meal_type", date, time
            case calories, proteinG = "protein_g", carbsG = "carbs_g", fatG = "fat_g"
            case fiberG = "fiber_g", sugarG = "sugar_g", sodiumMg = "sodium_mg"
            case quantity, servingDescription = "serving_description"
            case source, offProductCode = "off_product_code", confidence, notes
        }
    }

    private static var logMeal: AnyCoachTool {
        .make(
            name: "log_meal",
            label: "Logging your meal",
            description: "Log a meal/food/drink the user ate. Values are TOTALS for what was eaten. "
                + "Ground nameable foods via search_food_database first (source 'database'); "
                + "for home-cooked or unverifiable food use source 'estimate' with honest confidence "
                + "and stated portion assumptions. One call per meal.",
            parameters: JSONSchema.object([
                "name": JSONSchema.string,
                "meal_type": JSONSchema.enumString(mealTypeEnum),
                "date": JSONSchema.string,
                "time": ["type": ["string", "null"]],
                "calories": JSONSchema.number,
                "protein_g": ["type": ["number", "null"]],
                "carbs_g": ["type": ["number", "null"]],
                "fat_g": ["type": ["number", "null"]],
                "fiber_g": ["type": ["number", "null"]],
                "sugar_g": ["type": ["number", "null"]],
                "sodium_mg": ["type": ["number", "null"]],
                "quantity": ["type": ["number", "null"]],
                "serving_description": ["type": ["string", "null"]],
                "source": JSONSchema.enumString(["database", "estimate"]),
                "off_product_code": ["type": ["string", "null"]],
                "confidence": JSONSchema.enumString(["low", "medium", "high"]),
                "notes": ["type": ["string", "null"]],
            ], required: ["name", "meal_type", "date", "time", "calories", "protein_g", "carbs_g", "fat_g",
                          "fiber_g", "sugar_g", "sodium_mg", "quantity", "serving_description",
                          "source", "off_product_code", "confidence", "notes"]),
            argsType: LogMealArgs.self
        ) { args, ctx in
            guard let mealType = MealType(rawValue: args.mealType) else {
                return .error("invalid meal_type '\(args.mealType)'")
            }
            guard args.calories >= 0, args.calories <= 6000 else {
                return .error("calories out of plausible range")
            }
            let timestamp = resolveTimestamp(date: args.date, time: args.time)
            let source: MealEntrySource = args.source == "database"
                ? (args.offProductCode != nil ? .offSearch : .llmEstimate)
                : .llmEstimate
            let entry = MealEntry(
                timestamp: timestamp,
                name: args.name,
                mealType: mealType,
                calories: args.calories,
                proteinG: args.proteinG ?? 0,
                carbsG: args.carbsG ?? 0,
                fatG: args.fatG ?? 0,
                fiberG: args.fiberG,
                sugarG: args.sugarG,
                sodiumMg: args.sodiumMg,
                source: source,
                offProductCode: args.offProductCode,
                servingDescription: args.servingDescription,
                quantity: args.quantity ?? 1,
                confidence: decodeConfidence(args.confidence),
                notes: args.notes,
                loggedByCoach: true
            )
            NutritionRepository.insert(entry, context: ctx.modelContext)
            ctx.loggedMealIds.append(entry.id)
            return .object(["ok": true, "meal_id": entry.id.uuidString, "name": args.name,
                            "kcal": args.calories.rounded(), "source": entry.sourceRaw,
                            "note": "Logged. The user sees a card and can tap it to adjust."])
        }
    }

    // MARK: update_meal_entry

    private struct UpdateMealArgs: Decodable {
        let mealId: String
        let name: String?, mealType: String?, calories: Double?
        let proteinG: Double?, carbsG: Double?, fatG: Double?, notes: String?
        let reason: String
        enum CodingKeys: String, CodingKey {
            case mealId = "meal_id", name, mealType = "meal_type", calories
            case proteinG = "protein_g", carbsG = "carbs_g", fatG = "fat_g", notes, reason
        }
    }

    private static var updateMealEntry: AnyCoachTool {
        .make(
            name: "update_meal_entry",
            label: "Updating that meal",
            description: "Edit a logged meal. Applies immediately for a meal logged today; for an older meal, returns needs_confirmation and shows a Confirm card.",
            parameters: JSONSchema.object([
                "meal_id": JSONSchema.string,
                "name": ["type": ["string", "null"]],
                "meal_type": ["type": ["string", "null"], "enum": mealTypeEnum + [NSNull()]],
                "calories": ["type": ["number", "null"]],
                "protein_g": ["type": ["number", "null"]],
                "carbs_g": ["type": ["number", "null"]],
                "fat_g": ["type": ["number", "null"]],
                "notes": ["type": ["string", "null"]],
                "reason": JSONSchema.string,
            ], required: ["meal_id", "name", "meal_type", "calories", "protein_g", "carbs_g", "fat_g", "notes", "reason"]),
            argsType: UpdateMealArgs.self
        ) { args, ctx in
            guard let id = UUID(uuidString: args.mealId),
                  let entry = NutritionRepository.entry(id: id, context: ctx.modelContext) else {
                return .error("meal '\(args.mealId)' not found")
            }
            let updates = MealUpdates(
                name: args.name, mealType: args.mealType, calories: args.calories,
                proteinG: args.proteinG, carbsG: args.carbsG, fatG: args.fatG, notes: args.notes
            )
            if Calendar.current.isDateInToday(entry.timestamp) {
                apply(updates, to: entry)
                NutritionRepository.update(entry, context: ctx.modelContext)
                ctx.loggedMealIds.append(entry.id)
                return .object(["ok": true, "updated": true, "meal_id": args.mealId])
            }
            ctx.pendingActions.append(PendingAction(
                kind: .updateMealEntry, activityId: args.mealId,
                summary: "Update \"\(entry.name)\" from \(CoachDataAccess.localDateString(entry.timestamp))?",
                confirmLabel: "Save changes", updates: nil, mealUpdates: updates
            ))
            return .object(["ok": true, "needs_confirmation": true,
                            "summary": "Awaiting your confirmation to edit that meal."])
        }
    }

    // MARK: delete_meal_entry

    private struct DeleteMealArgs: Decodable {
        let mealId: String, reason: String
        enum CodingKeys: String, CodingKey { case mealId = "meal_id", reason }
    }

    private static var deleteMealEntry: AnyCoachTool {
        .make(
            name: "delete_meal_entry",
            label: "Removing that meal",
            description: "Delete a logged meal. Always returns needs_confirmation and shows a Confirm card; the deletion only happens after the user taps Confirm.",
            parameters: JSONSchema.object([
                "meal_id": JSONSchema.string, "reason": JSONSchema.string,
            ], required: ["meal_id", "reason"]),
            argsType: DeleteMealArgs.self
        ) { args, ctx in
            guard let id = UUID(uuidString: args.mealId),
                  let entry = NutritionRepository.entry(id: id, context: ctx.modelContext) else {
                return .error("meal '\(args.mealId)' not found")
            }
            ctx.pendingActions.append(PendingAction(
                kind: .deleteMealEntry, activityId: args.mealId,
                summary: "Delete \"\(entry.name)\" (\(Int(entry.calories.rounded())) kcal) from \(CoachDataAccess.localDateString(entry.timestamp))?",
                confirmLabel: "Delete", updates: nil
            ))
            return .object(["ok": true, "needs_confirmation": true,
                            "summary": "Awaiting your confirmation to delete that meal."])
        }
    }

    // MARK: - shared

    static func apply(_ updates: MealUpdates, to entry: MealEntry) {
        var numbersChanged = false
        if let name = updates.name { entry.name = name }
        if let raw = updates.mealType, let mealType = MealType(rawValue: raw) { entry.mealType = mealType }
        if let kcal = updates.calories { entry.calories = kcal; numbersChanged = true }
        if let protein = updates.proteinG { entry.proteinG = protein; numbersChanged = true }
        if let carbs = updates.carbsG { entry.carbsG = carbs; numbersChanged = true }
        if let fat = updates.fatG { entry.fatG = fat; numbersChanged = true }
        if let notes = updates.notes { entry.notes = notes }
        // A user-requested correction to a database/estimate row marks it edited.
        if numbersChanged && entry.source != .manual { entry.userEdited = true }
        entry.updatedAt = Date()
    }

    private static func decodeConfidence(_ raw: String) -> DecodeConfidence {
        switch raw {
        case "high": return .known
        case "medium": return .partial
        default: return .unknown
        }
    }

    /// Combine a YYYY-MM-DD date with an optional HH:mm time; unstated time on a past day
    /// lands at noon, today at the current clock time.
    private static func resolveTimestamp(date: String, time: String?) -> Date {
        let day = CoachDataAccess.parseLocalDate(date) ?? Calendar.current.startOfDay(for: Date())
        if let time {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2,
               let stamped = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) {
                return stamped
            }
        }
        if Calendar.current.isDateInToday(day) { return Date() }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }
}
