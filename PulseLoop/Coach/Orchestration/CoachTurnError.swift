import Foundation

/// A user-facing failure for a coach turn, shown as a red-bordered error bubble
/// in chat. Provider-agnostic: every `ResponsesClient` (OpenAI, Gemini,
/// OpenRouter) throws `ResponsesError`, which maps to a short `code` (e.g.
/// "HTTP 401", "Network", "No output") plus a human-readable `reason`.
struct CoachTurnError: Equatable, Codable {
    /// Short, scannable code shown in the bubble header (e.g. "HTTP 429").
    let code: String
    /// The full reason text shown beneath the header.
    let reason: String

    init(code: String, reason: String) {
        self.code = code
        self.reason = reason
    }

    /// Plain-text form stored in `CoachMessage.body` (history/search fallback).
    var plainText: String { "Coach error · \(code)\n\(reason)" }

    /// JSON form stored in `CoachMessage.cardsJSON` so the error bubble can render
    /// the structured code/reason. Reuses the existing field — no schema change.
    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(fromJSON json: String?) -> CoachTurnError? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachTurnError.self, from: data)
    }

    /// Maps a thrown error into a displayable code + reason. Handles the app's
    /// `ResponsesError` cases explicitly and falls back to `localizedDescription`.
    init(_ error: Error) {
        if let e = error as? ResponsesError {
            switch e {
            case .missingAPIKey:
                self.init(code: "No API key", reason: "No API key is configured for the selected provider. Add one in Settings → AI Coach.")
            case .transport(let underlying):
                self.init(code: "Network", reason: underlying.localizedDescription)
            case .http(let status, let body):
                self.init(code: "HTTP \(status)", reason: CoachTurnError.cleanReason(from: body, status: status))
            case .decoding(let msg):
                self.init(code: "Response error", reason: msg)
            case .emptyOutput:
                self.init(code: "No output", reason: "The model returned an empty response. Try again, or pick a different model.")
            }
        } else {
            self.init(code: "Error", reason: error.localizedDescription)
        }
    }

    /// Extracts a readable message from a provider error body, which is usually
    /// JSON like `{"error":{"message":"..."}}` (OpenAI/OpenRouter) or
    /// `{"error":{"message":"...","status":"..."}}` (Gemini). Falls back to the
    /// raw body (trimmed) when it isn't that shape.
    private static func cleanReason(from body: String, status: Int) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // {"error": {"message": "..."}} or {"error": "..."}
            if let errObj = root["error"] as? [String: Any], let msg = errObj["message"] as? String, !msg.isEmpty {
                return msg
            }
            if let errStr = root["error"] as? String, !errStr.isEmpty {
                return errStr
            }
            if let msg = root["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        if trimmed.isEmpty {
            return "The provider returned HTTP \(status) with no details."
        }
        return String(trimmed.prefix(400))
    }
}
