import Foundation

/// Deterministic, grounded responses for when the LLM coach can't run (no key /
/// offline / API error) or when the final output can't be parsed. Ports
/// `_scripted_body` / `_fallback_body` from the web orchestrator.
enum CoachFallbacks {
    /// Used after an API failure or unrepairable output.
    static func fallback() -> CoachResponse {
        CoachResponse(
            responseType: .errorRecovery,
            title: "I had trouble with that",
            summary: "I checked your data but couldn't finish preparing the answer. Try asking again, or narrow the question.",
            dataQualityNote: "No changes were made.",
            followUpChips: ["How am I doing today?", "Summarize my week", "What data is missing?"],
            confidence: .low
        )
    }

    /// Used when the coach is disabled (offline / no key). Grounded in the
    /// context packet so it's still useful.
    static func scripted(packet: CoachContextPacket) -> CoachResponse {
        let today = packet.today
        guard let steps = today.steps else {
            return CoachResponse(
                responseType: .dataMissing,
                title: "No activity synced yet",
                // swiftlint:disable:next line_length
                summary: "I don't have today's activity from the ring yet. Sync the ring or take a measurement and I'll summarize what comes in. (The AI coach is off — add an OpenAI key in Settings to enable full coaching.)",
                dataQualityNote: packet.dataQualityWarnings.first,
                followUpChips: ["Is my ring connected?", "What data is missing?"],
                confidence: .low
            )
        }
        var bullets = ["Steps today: \(steps)"]
        if let cal = today.calories { bullets.append("Calories: \(Int(cal)) kcal") }
        if let hr = packet.latestVitals.latestHr { bullets.append("Latest HR: \(Int(hr)) bpm") }
        if let spo2 = packet.latestVitals.latestSpo2 { bullets.append("Latest SpO₂: \(Int(spo2))%") }
        return CoachResponse(
            responseType: .insight,
            title: "Here's where you are today",
            summary: "You're at \(steps) steps so far today. The AI coach is off — add an OpenAI key in Settings for trends and tailored guidance.",
            bullets: bullets,
            dataQualityNote: packet.dataQualityWarnings.last,
            followUpChips: ["How does today compare to yesterday?", "What's my heart rate trend?"],
            confidence: today.dataConfidence == "high" ? .medium : .low
        )
    }
}
