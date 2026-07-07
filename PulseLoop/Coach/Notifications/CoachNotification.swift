import Foundation

/// A generated daily check-in: a push-notification title + body, plus the
/// richer fields the on-device model can produce for free — a concrete tip, a
/// tappable follow-up question, and an adaptive `skip` flag (the model may
/// decide there's nothing worth interrupting the user for).
struct CoachNotification: Codable, Equatable {
    var title: String
    var body: String
    var tip: String
    var followUp: String
    var skip: Bool

    init(title: String, body: String, tip: String = "", followUp: String = "", skip: Bool = false) {
        self.title = title
        self.body = body
        self.tip = tip
        self.followUp = followUp
        self.skip = skip
    }

    /// Tolerant decode — older payloads (and cloud providers) may omit the richer
    /// fields, so they default rather than failing the whole object.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        tip = try c.decodeIfPresent(String.self, forKey: .tip) ?? ""
        followUp = try c.decodeIfPresent(String.self, forKey: .followUp) ?? ""
        skip = try c.decodeIfPresent(Bool.self, forKey: .skip) ?? false
    }

    func encodedJSON() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(fromJSON json: String?) -> CoachNotification? {
        guard let json else { return nil }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let n = try? JSONDecoder().decode(CoachNotification.self, from: data) {
            return n
        }
        // Tolerate prose/fences around the object.
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let data = String(trimmed[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachNotification.self, from: data)
    }
}

/// Strict Structured-Outputs schema for `coach_notification` (mirrors `CoachResponseSchema`).
enum CoachNotificationSchema {
    static let name = "coach_notification"

    static var textFormat: [String: Any] {
        ["type": "json_schema", "name": name, "schema": jsonSchema, "strict": true]
    }

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "maxLength": 50],
                "body": ["type": "string", "maxLength": 160],
                "tip": ["type": "string", "maxLength": 80,
                        "description": "One concrete, actionable suggestion, or empty string."],
                "followUp": ["type": "string", "maxLength": 80,
                             "description": "A short question the user can tap to start a chat, or empty string."],
                "skip": ["type": "boolean",
                         "description": "True only when there is genuinely nothing useful or new to say."],
            ],
            "required": ["title", "body", "tip", "followUp", "skip"],
            "additionalProperties": false,
        ]
    }
}
