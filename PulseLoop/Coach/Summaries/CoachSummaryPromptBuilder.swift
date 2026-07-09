import Foundation

/// Prompts for the Today/Sleep coach-card summaries.
enum CoachSummaryPromptBuilder {
    static func systemPrompt(kind: CoachSummaryKind) -> String {
        let focus: String
        switch kind {
        case .today:
            focus = "This card sits on the Today page. Give a quick, motivating read on how the day is going so far (steps, heart rate, sleep last night, activity)."
        case .sleepDay:
            focus = "This card sits on the Sleep page for last night. Interpret the night — duration, deep/light/awake balance, and the sleep score — and what it means for today."
        case .sleepRange:
            focus = "This card sits on the Sleep page for a multi-night range. Summarize the sleep trend (average duration, consistency, score) over the period."
        }
        return """
        You write a short coach card for PulseLoop, a smart-ring health app, grounded in the user's own data.

        \(focus)

        Rules:
        - Output ONLY JSON {"title","body","chips"}. Title ≤ ~6 words. Body 1–2 short, specific sentences citing real numbers from the data.
        - `chips`: up to 2 short follow-up questions the user might tap (e.g. "Why is my deep sleep low?"). Keep each under 40 characters — they render side by side. Phrase them as the user would ask.
        - Be warm, specific, and genuinely useful — not generic. Ground every claim in the provided data; if data is thin, say so lightly and never invent numbers.
        - No medical diagnosis or alarming language. Wellness tone. At most one emoji, only if it fits.
        - When an `environment` block (city + weather) is present, you may use it for concrete advice (outdoor vs indoor, hydration, rain). Never name a location finer than the city; don't force it.
        - A coaching angle and your recent cards are provided — vary your voice and structure; never open two cards the same way.
        """
    }

    static func developerMessage(contextJSON: String, angle: String = "", recentTexts: [String] = []) -> String {
        var blocks = ["Data for this card:\n\(contextJSON)"]
        if !angle.isEmpty {
            blocks.append("Coaching angle for this check-in (take it unless the data makes it a poor fit): \(angle)")
        }
        if !recentTexts.isEmpty {
            let list = recentTexts.map { "- \($0)" }.joined(separator: "\n")
            blocks.append("Your most recent check-ins — do NOT repeat their phrasing, openings, or structure:\n\(list)")
        }
        blocks.append("Write the card now as {\"title\",\"body\",\"chips\"}.")
        return blocks.joined(separator: "\n\n")
    }
}
