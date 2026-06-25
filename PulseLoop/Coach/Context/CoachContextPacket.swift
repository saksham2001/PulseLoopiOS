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
}
