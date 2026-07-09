import Foundation

/// Generated coach-card content: a headline, a short body, and up to a few
/// tappable follow-up chips.
struct CoachSummaryContent: Codable, Equatable {
    var title: String
    var body: String
    var chips: [String]

    static func decode(fromJSON json: String?) -> CoachSummaryContent? {
        guard let json else { return nil }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let c = try? JSONDecoder().decode(CoachSummaryContent.self, from: data) {
            return c
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let data = String(trimmed[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachSummaryContent.self, from: data)
    }

    /// As a `CoachResponse` for seeding the chat thread (chips → follow-ups).
    func asCoachResponse() -> CoachResponse {
        CoachResponse(
            responseType: .insight,
            title: title,
            summary: body,
            followUpChips: chips,
            confidence: .medium
        )
    }
}

/// Strict Structured-Outputs schema for `coach_summary`.
enum CoachSummarySchema {
    static let name = "coach_summary"

    static var textFormat: [String: Any] {
        ["type": "json_schema", "name": name, "schema": jsonSchema, "strict": true]
    }

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "maxLength": 60],
                "body": ["type": "string", "maxLength": 320],
                "chips": [
                    "type": "array",
                    // Kept short so both questions fit side by side on the card.
                    "items": ["type": "string", "maxLength": 40],
                    "maxItems": 2,
                ],
            ],
            "required": ["title", "body", "chips"],
            "additionalProperties": false,
        ]
    }
}
