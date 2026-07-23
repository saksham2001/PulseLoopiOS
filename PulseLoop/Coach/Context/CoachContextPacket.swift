import Foundation

/// Compact context the model sees every turn — ports the web app's
/// CoachContextPacket (`backend/app/coach/context.py`). Deliberately small:
/// latest values + rollups + warnings. Dense arrays are never embedded; the
/// model fetches those on demand via tools.
///
/// Encoded camelCase → snake_case by the prompt builder so property names stay
/// idiomatic Swift while the wire shape matches the web contract.
struct CoachContextPacket: Encodable {
    var generatedAt: String
    var timezone: String
    var profile: ProfileContext
    var device: DeviceContext
    var goals: GoalContext
    var today: DayContext
    var lastSevenDays: WeekContext
    var latestVitals: VitalsContext
    var latestSleep: SleepContext?
    var recentWorkouts: [WorkoutContext]
    var memories: [MemoryContext]
    var conversationSummary: String?
    var dataQualityWarnings: [String]
    /// Opt-in city-level location + current weather. Nil when the toggle is off,
    /// permission is denied, or WeatherKit is unavailable. Raw coordinates NEVER
    /// appear here — only the reverse-geocoded city/region.
    var environment: EnvironmentContext?
    /// Opt-in nutrition tracking summary. Nil when the feature is off or the user
    /// doesn't share it with the coach — absent from the JSON entirely.
    var nutrition: NutritionContext?

    struct ProfileContext: Encodable {
        var name: String?
        var age: Int?
        var sex: String?
        var heightCm: Double?
        var weightKg: Double?
        /// "metric" | "imperial" — the units the coach should answer in.
        var units: String
        /// "empty" | "partial" | "complete"
        var completeness: String
    }

    struct DeviceContext: Encodable {
        var name: String?
        var batteryPercent: Int?
        var state: String
        var lastConnectedAt: String?
        var lastSyncAt: String?
    }

    struct GoalContext: Encodable {
        var stepsDaily: Int
        var activeMinutesDaily: Int
        var sleepHours: Double
        var exerciseDaysWeekly: Int
        // Nutrition intake goals (nil = not set; only present while nutrition is shared).
        var calorieIntakeDaily: Int?
        var proteinGDaily: Int?
        var carbsGDaily: Int?
        var fatGDaily: Int?
    }

    struct DayContext: Encodable {
        var localDate: String
        var steps: Int?
        var calories: Double?
        var distanceKm: Double?
        var activeMinutes: Int?
        /// "none" | "low" | "medium" | "high"
        var dataConfidence: String
    }

    struct WeekContext: Encodable {
        var daysAvailable: Int
        var avgSteps: Int?
        var totalSteps: Int?
        var activeMinutesTotal: Int?
        var exerciseDays: Int
        var mostActiveDay: String?
    }

    struct VitalsContext: Encodable {
        var latestHr: Double?
        var latestHrAt: String?
        var latestSpo2: Double?
        var latestSpo2At: String?
        var restingHrEstimate: Double?
        var peakHrToday: Double?
    }

    struct SleepContext: Encodable {
        var date: String
        var totalMin: Int
        var deepMin: Int
        var lightMin: Int
        var awakeMin: Int
        var score: Int?
        var confidence: String
        var decoderNote: String
    }

    struct WorkoutContext: Encodable {
        var id: String
        var type: String
        var startTime: String
        var durationMin: Double?
        var distanceKm: Double?
        var avgHr: Double?
        var status: String
    }

    struct MemoryContext: Encodable {
        var type: String
        var key: String
        var value: String
        var importance: Int
    }

    /// Today's consumed nutrition + goals + meal list. Only present when the user
    /// enabled nutrition tracking AND sharing it with the coach.
    struct NutritionContext: Encodable {
        var caloriesConsumed: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var mealsLoggedToday: Int
        var mealsToday: [MealBrief]
        var yesterdayCalories: Double?

        struct MealBrief: Encodable {
            var mealId: String
            var name: String
            var mealType: String
            var time: String
            var kcal: Double
            /// "off_barcode" | "off_search" | "llm_estimate" | "manual"
            var source: String
        }
    }

    /// City-level location + current/forecast weather. City-only privacy: never a
    /// street, never coordinates. Any field may be nil when weather degrades to a
    /// city-only or stale result.
    struct EnvironmentContext: Encodable {
        var city: String?
        var region: String?
        var tempC: Double?
        var condition: String?
        var highC: Double?
        var lowC: Double?
        var precipitationChancePct: Int?
        var sunrise: String?
        var sunset: String?
        var asOf: String
    }
}
