import Foundation

/// A risky write the coach proposed but has NOT performed — surfaced to the user
/// as a Confirm/Cancel card and only executed on tap. Persisted as JSON on the
/// assistant `CoachMessage.pendingActionJSON`.
struct PendingAction: Codable, Equatable {
    enum Kind: String, Codable {
        case deleteActivitySession
        case updateActivitySession
        case deleteMealEntry
        case updateMealEntry
    }

    var kind: Kind
    /// Target row id. Named for the original activity actions; meal actions reuse it
    /// (kept as-is so existing persisted cards keep decoding).
    var activityId: String
    var summary: String          // human-readable description for the card
    var confirmLabel: String
    var updates: ActivityUpdates?   // only for `updateActivitySession`
    /// Field updates for `updateMealEntry`. Optional + defaulted nil so older
    /// persisted actions decode unchanged.
    var mealUpdates: MealUpdates? = nil

    func encodedJSON() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(fromJSON json: String?) -> PendingAction? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PendingAction.self, from: data)
    }
}

/// Field updates for `updateActivitySession` (nil = leave unchanged).
struct ActivityUpdates: Codable, Equatable {
    var type: String?
    var notes: String?
    var distanceKm: Double?
    var durationMin: Double?
    var perceivedEffort: String?
    var startTime: String?
}

/// Field updates for `updateMealEntry` (nil = leave unchanged).
struct MealUpdates: Codable, Equatable {
    var name: String?
    var mealType: String?
    var calories: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var notes: String?
}
