import Foundation
import SwiftData

enum MealType: String, Codable, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case snack

    var label: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snack: return "Snack"
        }
    }

    /// Default meal type for a new entry logged at the given time of day.
    static func inferred(at date: Date = Date()) -> MealType {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<11: return .breakfast
        case 11..<15: return .lunch
        case 17..<22: return .dinner
        default: return .snack
        }
    }
}

/// Where an entry's nutrition numbers came from — the honesty core of "we don't guess numbers".
/// Raw values are persisted; append, never rename.
enum MealEntrySource: String, Codable, CaseIterable {
    case offBarcode = "off_barcode"     // scanned barcode resolved via Open Food Facts
    case offSearch = "off_search"       // Open Food Facts text-search pick (user or coach)
    case llmEstimate = "llm_estimate"   // coach estimate (photo or text), no database grounding
    case manual                         // user typed the numbers

    var isDatabaseVerified: Bool { self == .offBarcode || self == .offSearch }
}

/// One logged meal / food / drink. Macros are stored as totals for the entry (quantity already
/// applied); `servingGrams` + `quantity` keep enough provenance to re-scale when the user edits
/// the serving. `date` is startOfDay for fast per-day queries, same pattern as `ActivityDaily`.
@Model
final class MealEntry {
    #Index<MealEntry>([\.date], [\.timestamp])
    @Attribute(.unique) var id: UUID
    var date: Date
    var timestamp: Date
    var name: String
    var mealTypeRaw: String
    /// Total energy for the entry in kcal (the app-wide energy unit).
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    // Optional nutrients: nil means "unknown", which must stay distinct from 0.
    var fiberG: Double?
    var sugarG: Double?
    var sodiumMg: Double?
    var sourceRaw: String
    /// Open Food Facts product code when database-grounded.
    var offProductCode: String?
    /// Human serving description, e.g. "1 cup" or "45 g".
    var servingDescription: String?
    /// Resolved grams per single serving when known — enables per-serving re-scaling.
    var servingGrams: Double?
    /// Servings consumed.
    var quantity: Double
    var confidenceRaw: String
    /// User adjusted the numbers after an estimate/lookup.
    var userEdited: Bool
    /// Encoded `CoachAttachmentRef` when logged from a photo; bytes stay in the attachment store.
    var photoRefJSON: String?
    var notes: String?
    /// Logged through the coach (chat/analysis) vs the nutrition page.
    var loggedByCoach: Bool
    var createdAt: Date
    /// Drives the HealthKit export watermark: edits re-export.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        name: String,
        mealType: MealType,
        calories: Double,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fiberG: Double? = nil,
        sugarG: Double? = nil,
        sodiumMg: Double? = nil,
        source: MealEntrySource = .manual,
        offProductCode: String? = nil,
        servingDescription: String? = nil,
        servingGrams: Double? = nil,
        quantity: Double = 1,
        confidence: DecodeConfidence = .known,
        userEdited: Bool = false,
        photoRefJSON: String? = nil,
        notes: String? = nil,
        loggedByCoach: Bool = false
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: timestamp)
        self.timestamp = timestamp
        self.name = name
        self.mealTypeRaw = mealType.rawValue
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.sourceRaw = source.rawValue
        self.offProductCode = offProductCode
        self.servingDescription = servingDescription
        self.servingGrams = servingGrams
        self.quantity = quantity
        self.confidenceRaw = confidence.rawValue
        self.userEdited = userEdited
        self.photoRefJSON = photoRefJSON
        self.notes = notes
        self.loggedByCoach = loggedByCoach
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var mealType: MealType {
        get { MealType(rawValue: mealTypeRaw) ?? .snack }
        set {
            mealTypeRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var source: MealEntrySource {
        get { MealEntrySource(rawValue: sourceRaw) ?? .manual }
        set {
            sourceRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var confidence: DecodeConfidence { DecodeConfidence(rawValue: confidenceRaw) ?? .known }

    /// Re-stamp `timestamp` and keep the `date` day-bucket in sync.
    func setTimestamp(_ newValue: Date) {
        timestamp = newValue
        date = Calendar.current.startOfDay(for: newValue)
        updatedAt = Date()
    }
}

/// A locally cached Open Food Facts product: powers the "recent / frequent foods" quick-log list
/// and keeps repeat lookups off the rate-limited API. Values are per-100g (OFF's native shape);
/// per-serving math happens at use time via `NutritionMath`. LRU-pruned by the repository.
@Model
final class CachedFoodProduct {
    #Index<CachedFoodProduct>([\.lastUsedAt])
    @Attribute(.unique) var code: String
    var name: String
    var brand: String?
    var energyKcal100g: Double
    var protein100g: Double
    var carbs100g: Double
    var fat100g: Double
    var fiber100g: Double?
    var sugars100g: Double?
    var saturatedFat100g: Double?
    var sodiumMg100g: Double?
    var servingSizeText: String?
    var servingQuantityG: Double?
    var fetchedAt: Date
    var useCount: Int
    var lastUsedAt: Date

    init(
        code: String,
        name: String,
        brand: String? = nil,
        energyKcal100g: Double,
        protein100g: Double = 0,
        carbs100g: Double = 0,
        fat100g: Double = 0,
        fiber100g: Double? = nil,
        sugars100g: Double? = nil,
        saturatedFat100g: Double? = nil,
        sodiumMg100g: Double? = nil,
        servingSizeText: String? = nil,
        servingQuantityG: Double? = nil
    ) {
        self.code = code
        self.name = name
        self.brand = brand
        self.energyKcal100g = energyKcal100g
        self.protein100g = protein100g
        self.carbs100g = carbs100g
        self.fat100g = fat100g
        self.fiber100g = fiber100g
        self.sugars100g = sugars100g
        self.saturatedFat100g = saturatedFat100g
        self.sodiumMg100g = sodiumMg100g
        self.servingSizeText = servingSizeText
        self.servingQuantityG = servingQuantityG
        self.fetchedAt = Date()
        self.useCount = 0
        self.lastUsedAt = Date()
    }
}
