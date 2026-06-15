import Foundation

/// Prompts for the daily check-in generator. Tuned for short, engaging, *unique*
/// push notifications in the spirit of Oura/Whoop/Fitbit nudges.
enum NotificationPromptBuilder {
    static func systemPrompt(slot: CoachNotificationSlot) -> String {
        let slotGuidance = slot == .morning
            ? "This is the MORNING check-in: lead with how last night's sleep went and set up the day — a light, motivating plan or one small nudge (move, hydrate, a step target)."
            : "This is the EVENING check-in: recap the day's activity (steps, active minutes, workouts) and ease toward wind-down — a calm nudge about recovery or tomorrow."

        return """
        You write a single push notification for PulseLoop, a smart-ring health app. It is a short, friendly daily check-in grounded in the user's own ring data.

        \(slotGuidance)

        Rules:
        - Output ONLY JSON {"title","body"}. Title ≤ ~6 words; body 1–2 short sentences.
        - Be specific to today's actual numbers (steps, sleep, heart rate, SpO2, workouts) — never generic filler. Mention a real number when you have one.
        - Surface ONE clear insight or nudge, not a list.
        - Be warm and engaging, like a thoughtful coach. At most one emoji, and only if it fits.
        - Ground every claim in the provided data. If data is thin, keep it light and honest; never invent numbers.
        - No medical diagnosis or alarming language. Wellness tone only.
        """
    }

    static func developerMessage(packet: NotificationContextPacket) -> String {
        let json = encode(packet)
        return """
        Context (last ~12 hours):
        \(json)

        Write a fresh \(packet.slot) check-in now as {"title","body"}.
        """
    }

    private static func encode(_ packet: NotificationContextPacket) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(packet), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
