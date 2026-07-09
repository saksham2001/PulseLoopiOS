import Foundation

/// Single-shot OpenAI call that produces a coach-card summary. No tools — just
/// system + developer → strict `{title, body, chips}`. Returns the provided
/// scripted `fallback` (from `TodayInsights`/`SleepInsights`) when the coach is
/// disabled or the call fails, so cards never look empty.
@MainActor
enum CoachSummaryGenerator {
    static func generate(
        kind: CoachSummaryKind,
        contextJSON: String,
        fallback: CoachSummaryContent,
        flags: CoachFeatureFlags,
        client: ResponsesClient,
        angle: String = "",
        recentTexts: [String] = []
    ) async -> CoachSummaryContent {
        guard flags.coachEnabled else { return fallback }
        do {
            let input: [[String: Any]] = [
                OpenAIRequestBuilder.message(role: "system", content: CoachSummaryPromptBuilder.systemPrompt(kind: kind)),
                OpenAIRequestBuilder.message(role: "developer", content: CoachSummaryPromptBuilder.developerMessage(contextJSON: contextJSON, angle: angle, recentTexts: recentTexts)),
            ]
            let body = try OpenAIRequestBuilder.data(
                model: flags.model, input: input, tools: [],
                textFormat: CoachSummarySchema.textFormat,
                previousResponseId: nil, reasoningEffort: flags.settings.reasoningEffort
            )
            let response = try await client.send(requestBody: body)
            return CoachSummaryContent.decode(fromJSON: response.outputText) ?? fallback
        } catch {
            return fallback
        }
    }
}
