import Foundation

/// Prompts for the daily check-in generator. Tuned for short, engaging, *unique*
/// push notifications in the spirit of Oura/Whoop/Fitbit nudges.
enum NotificationPromptBuilder {
    static func systemPrompt(slot: CoachNotificationSlot) -> String {
        let slotGuidance: String
        switch slot {
        case .morning:
            slotGuidance = "This is the MORNING check-in: lead with how last night's sleep went and set up the day — a light, motivating plan or one small nudge (move, hydrate, a step target)."
        case .midday:
            slotGuidance = "This is the MIDDAY check-in: a quick pulse on how the day is going so far " +
                "(movement, heart rate) and a small nudge to stay on track — a short walk, hydration, a posture/breathing reset."
        case .evening:
            slotGuidance = "This is the EVENING check-in: recap the day's activity (steps, active minutes, workouts) and ease toward wind-down — a calm nudge about recovery or tomorrow."
        }

        return """
        You write a single push notification for PulseLoop, a smart-ring health app. It is a short, friendly daily check-in grounded in the user's own ring data.

        \(slotGuidance)

        Output ONLY JSON {"title","body","tip","followUp","skip"}:
        - title: ≤ ~6 words.
        - body: 1–2 short sentences grounded in today's real numbers (steps, sleep, heart rate, SpO2, workouts) — never generic filler. Surface ONE clear insight, not a list.
        - tip: ONE concrete, immediately actionable suggestion (≤ ~12 words), or "" if none fits.
        - followUp: a short, inviting question the user could tap to start a chat with you (≤ ~12 words), or "".
        - skip: true ONLY if there is genuinely nothing useful or new to say right now (e.g. no fresh data, or it would just repeat an obvious point). Be conservative — default false.

        Rules:
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

        Write a fresh \(packet.slot) check-in now as {"title","body","tip","followUp","skip"}.
        """
    }

    // MARK: - Proactive anomaly alerts

    static func anomalySystemPrompt() -> String {
        """
        You write a single, gentle push notification for PulseLoop, a smart-ring health app, because something in the user's recent data is worth a soft heads-up.

        Output ONLY JSON {"title","body","tip","followUp","skip"}:
        - title: ≤ ~6 words, calm and non-alarming.
        - body: 1–2 short sentences naming the specific reading and what it might mean in everyday terms.
        - tip: ONE gentle, concrete suggestion (rest, hydrate, re-measure, take it easy), or "".
        - followUp: a short, caring question inviting the user to chat about it, or "".
        - skip: false (an anomaly was detected — always send).

        Rules:
        - Calm, supportive, NON-alarming. This is wellness guidance, not a diagnosis. Never imply emergency or disease.
        - Use only the provided facts and numbers — never invent or escalate.
        - If a reading could be a measurement glitch, it's fine to suggest re-measuring.
        """
    }

    static func anomalyDeveloperMessage(packet: NotificationContextPacket, anomaly: CoachAnomaly) -> String {
        let json = encode(packet)
        return """
        Detected: \(anomaly.facts)

        Supporting context (last ~12 hours):
        \(json)

        Write a calm heads-up now as {"title","body","tip","followUp","skip"}.
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
