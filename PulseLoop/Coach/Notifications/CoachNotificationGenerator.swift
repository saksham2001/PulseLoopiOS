import Foundation

/// Single-shot OpenAI call that turns a 12h context packet into a check-in.
/// No tools — just system + developer → strict `{title, body}`. Falls back to a
/// deterministic, grounded notification if disabled or the API fails, so a
/// delivered check-in is always sensible.
@MainActor
enum CoachNotificationGenerator {
    static func generate(
        slot: CoachNotificationSlot,
        packet: NotificationContextPacket,
        flags: CoachFeatureFlags,
        client: ResponsesClient
    ) async -> CoachNotification {
        guard flags.coachEnabled else { return scripted(slot: slot, packet: packet) }
        do {
            let input: [[String: Any]] = [
                OpenAIRequestBuilder.message(role: "system", content: NotificationPromptBuilder.systemPrompt(slot: slot)),
                OpenAIRequestBuilder.message(role: "developer", content: NotificationPromptBuilder.developerMessage(packet: packet)),
            ]
            let body = try OpenAIRequestBuilder.data(
                model: flags.model, input: input, tools: [],
                textFormat: CoachNotificationSchema.textFormat,
                previousResponseId: nil, reasoningEffort: flags.settings.reasoningEffort
            )
            let response = try await client.send(requestBody: body)
            return CoachNotification.decode(fromJSON: response.outputText) ?? scripted(slot: slot, packet: packet)
        } catch {
            return scripted(slot: slot, packet: packet)
        }
    }

    /// Proactive anomaly alert. Same shape as a check-in, but framed as a calm,
    /// non-alarming heads-up. Falls back to the grounded `anomaly.facts` copy if
    /// the model is disabled or fails.
    static func generateAnomaly(
        anomaly: CoachAnomaly,
        packet: NotificationContextPacket,
        flags: CoachFeatureFlags,
        client: ResponsesClient
    ) async -> CoachNotification {
        guard flags.coachEnabled else { return scriptedAnomaly(anomaly) }
        do {
            let input: [[String: Any]] = [
                OpenAIRequestBuilder.message(role: "system", content: NotificationPromptBuilder.anomalySystemPrompt()),
                OpenAIRequestBuilder.message(role: "developer", content: NotificationPromptBuilder.anomalyDeveloperMessage(packet: packet, anomaly: anomaly)),
            ]
            let body = try OpenAIRequestBuilder.data(
                model: flags.model, input: input, tools: [],
                textFormat: CoachNotificationSchema.textFormat,
                previousResponseId: nil, reasoningEffort: flags.settings.reasoningEffort
            )
            let response = try await client.send(requestBody: body)
            // An anomaly alert always sends — ignore a stray skip from the model.
            var n = CoachNotification.decode(fromJSON: response.outputText) ?? scriptedAnomaly(anomaly)
            n.skip = false
            return n
        } catch {
            return scriptedAnomaly(anomaly)
        }
    }

    static func scriptedAnomaly(_ anomaly: CoachAnomaly) -> CoachNotification {
        switch anomaly.kind {
        case .lowSpO2:
            return CoachNotification(title: "A quick heads-up",
                                     body: anomaly.facts,
                                     tip: "Rest a moment and re-measure when you're settled.",
                                     followUp: "Want to talk through what might affect your readings?")
        case .poorSleep:
            return CoachNotification(title: "Short night",
                                     body: anomaly.facts,
                                     tip: "Go easy today and aim for an earlier wind-down.",
                                     followUp: "Want tips for a better night tonight?")
        case .restingHRDrift:
            return CoachNotification(title: "A quick heads-up", body: anomaly.facts)
        }
    }

    /// Grounded, deterministic fallback.
    static func scripted(slot: CoachNotificationSlot, packet: NotificationContextPacket) -> CoachNotification {
        let name = packet.profileName.map { ", \($0)" } ?? ""
        switch slot {
        case .morning:
            if let sleep = packet.latestSleep {
                let h = sleep.totalMin / 60, m = sleep.totalMin % 60
                return CoachNotification(title: "Good morning\(name)",
                                         body: "You logged \(h)h \(m)m of sleep. Here's to a strong day — get moving when you can.")
            }
            return CoachNotification(title: "Good morning\(name)",
                                     body: "Ready to start the day? Take a measurement and I'll help you plan it.")
        case .midday:
            if let steps = packet.today.steps {
                return CoachNotification(title: "Midday check-in",
                                         body: "\(steps) steps so far. A short walk now keeps the momentum going.")
            }
            return CoachNotification(title: "Midday check-in",
                                     body: "How's the day going? A quick movement break is a great reset.")
        case .evening:
            if let steps = packet.today.steps {
                let goal = packet.goals.stepsDaily
                let hit = steps >= goal ? "You hit your \(goal) step goal — nice work." : "\(goal - steps) steps to your goal."
                return CoachNotification(title: "Evening check-in",
                                         body: "\(steps) steps today. \(hit) Time to start winding down.")
            }
            return CoachNotification(title: "Evening check-in",
                                     body: "How did today feel? Sync your ring and I'll recap your day.")
        }
    }
}
