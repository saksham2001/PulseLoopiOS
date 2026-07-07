import Foundation

/// Resolves "can the real coach run, and which tool classes are allowed" from
/// the user's settings plus whether a key is actually present. Mirrors the web
/// app's `settings.coach_enabled` gate, extended with per-class tool toggles.
struct CoachFeatureFlags {
    let settings: CoachSettings
    let hasAPIKey: Bool

    /// User-facing master switch — when off, the coach tab, summaries and
    /// notifications are all hidden. This is the gate the UI checks; the
    /// `coachEnabled` flag below additionally factors in provider/key state.
    var masterEnabled: Bool { settings.coachMasterEnabled }

    /// True when the real (LLM-backed) coach should run. Otherwise the
    /// orchestrator falls back to a deterministic scripted response.
    var coachEnabled: Bool {
        guard settings.coachMasterEnabled else { return false }
        switch settings.providerMode {
        case .offlineStub:
            return false
        case .appleOnDevice:
            // On-device only — ready when the local model is usable on this
            // device. Otherwise the coach degrades to scripted and on-device
            // failures surface as an error in chat.
            return AppleOnDeviceAvailability.current.isAvailable
        case .userOpenAIKey, .userGeminiKey, .userOpenRouterKey:
            return hasAPIKey
        case .backendProxy:
            return false  // not implemented in v1
        }
    }

    var webSearchEnabled: Bool { settings.enableWebSearch }
    var writeToolsEnabled: Bool { settings.enableWriteTools }
    var liveMeasurementsEnabled: Bool { settings.enableLiveMeasurements }
    var imageInputEnabled: Bool { settings.enableImageInput }

    var maxToolCalls: Int { max(1, settings.maxToolCalls) }
    var maxRounds: Int { max(1, settings.maxRounds) }
    var model: String { settings.model }

    /// One-line status for the Settings UI.
    var statusLine: String {
        if !settings.coachMasterEnabled { return "Off — turn on AI Coach to enable." }
        switch settings.providerMode {
        case .offlineStub:
            return "Offline — scripted replies only."
        case .appleOnDevice:
            return AppleOnDeviceAvailability.current.statusMessage
        case .userOpenAIKey:
            return hasAPIKey ? "Ready · \(settings.model)" : "Add an OpenAI key to enable."
        case .userGeminiKey:
            return hasAPIKey ? "Ready · \(settings.model)" : "Add a Gemini key to enable."
        case .userOpenRouterKey:
            return hasAPIKey ? "Ready · \(settings.openRouterModel)" : "Add an OpenRouter key to enable."
        case .backendProxy:
            return "Backend proxy not available yet."
        }
    }
}
