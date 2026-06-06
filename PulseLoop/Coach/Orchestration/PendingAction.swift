import Foundation

/// A risky write the coach proposed but has NOT performed — surfaced to the user
/// as a Confirm/Cancel card and only executed on tap. Persisted as JSON on the
/// assistant `CoachMessage.pendingActionJSON`.
struct PendingAction: Codable, Equatable {
    enum Kind: String, Codable {
        case deleteActivitySession
        case updateActivitySession
    }

    var kind: Kind
    var activityId: String
    var summary: String          // human-readable description for the card
    var confirmLabel: String
    var updates: ActivityUpdates?   // only for `updateActivitySession`

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
