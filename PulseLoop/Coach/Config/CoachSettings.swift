import Foundation

/// Where the coach's "brain" runs. v1 ships `offlineStub` + `userOpenAIKey`;
/// `backendProxy` is reserved for a future public build (iOS → server → OpenAI)
/// and is treated as disabled until implemented.
enum CoachProviderMode: String, Codable, CaseIterable, Identifiable {
    case offlineStub
    case userOpenAIKey
    case userGeminiKey
    case userOpenRouterKey
    case backendProxy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .offlineStub: return "Offline"
        case .userOpenAIKey: return "OpenAI (your key)"
        case .userGeminiKey: return "Gemini (your key)"
        case .userOpenRouterKey: return "OpenRouter (your key)"
        case .backendProxy: return "Backend proxy"
        }
    }
}

/// Preset Gemini model choices surfaced in Settings.
enum GeminiModel: String, CaseIterable, Identifiable {
    case flash25 = "gemini-2.5-flash"
    case flash20 = "gemini-2.0-flash"
    case pro25   = "gemini-2.5-pro"

    var id: String { rawValue }

    var label: String { rawValue }

    var blurb: String {
        switch self {
        case .flash25: return "Fast & capable (default)"
        case .flash20: return "Previous generation"
        case .pro25:   return "Best reasoning"
        }
    }
}

/// Preset OpenRouter model slugs surfaced in Settings. OpenRouter routes a
/// `vendor/model` slug to the underlying provider, and its catalog is large and
/// changes often — so the stored `CoachSettings.model` stays a free string and
/// Settings also exposes a "Custom…" text field where the user can type any
/// current slug from openrouter.ai/models. These are just the curated picks.
enum OpenRouterModel: String, CaseIterable, Identifiable {
    case claudeSonnet = "anthropic/claude-sonnet-4.6"
    case claudeOpus   = "anthropic/claude-opus-4.7"
    case gpt55        = "openai/gpt-5.5"
    case gpt54mini    = "openai/gpt-5.4-mini"
    case geminiFlash  = "google/gemini-2.5-flash"
    case geminiPro    = "google/gemini-2.5-pro"
    case deepseekV4   = "deepseek/deepseek-v4"

    var id: String { rawValue }

    var label: String { rawValue }

    var blurb: String {
        switch self {
        case .claudeSonnet: return "Balanced, great for coaching (default)"
        case .claudeOpus:   return "Most capable Claude"
        case .gpt55:        return "OpenAI flagship"
        case .gpt54mini:    return "Lower cost & latency"
        case .geminiFlash:  return "Fast & capable"
        case .geminiPro:    return "Deep reasoning"
        case .deepseekV4:   return "Strong open reasoning, low cost"
        }
    }

    /// Sensible default when switching to OpenRouter (strong instruction-following
    /// and structured-output support via OpenRouter).
    static let `default` = OpenRouterModel.claudeSonnet
}

/// Preset OpenAI model choices. The stored `CoachSettings.model` is a free
/// string (so a new model can be typed/served without a code change); these are
/// just the curated picks surfaced in Settings.
enum CoachModel: String, CaseIterable, Identifiable {
    case gpt54mini = "gpt-5.4-mini"
    case gpt54 = "gpt-5.4"
    case gpt55 = "gpt-5.5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpt54mini: return "gpt-5.4-mini"
        case .gpt54: return "gpt-5.4"
        case .gpt55: return "gpt-5.5"
        }
    }

    var blurb: String {
        switch self {
        case .gpt54mini: return "Lower cost & latency"
        case .gpt54: return "Balanced (default)"
        case .gpt55: return "Best reasoning"
        }
    }
}

/// User-tunable coach configuration, persisted as JSON in `UserDefaults`.
struct CoachSettings: Codable, Equatable {
    /// Master switch for all AI Coach features (tab, summaries, notifications).
    /// Off by default — users who only want metrics get a coach-free app.
    var coachMasterEnabled: Bool = false
    var providerMode: CoachProviderMode = .userOpenAIKey
    /// Default matches the web app; user-configurable (never hard-coded in the client).
    var model: String = CoachModel.gpt54.rawValue
    /// Optional reasoning effort hint ("low"/"medium"/"high") when the model supports it.
    var reasoningEffort: String? = nil
    var enableWebSearch: Bool = false
    /// OpenRouter-only: when true, route only through providers that don't log or
    /// train on prompts (sends `provider.data_collection = "deny"`). Ignored by
    /// the native OpenAI/Gemini clients.
    var orEnablePrivacyRouting: Bool = false
    /// OpenRouter-only: provider selection bias ("price" | "throughput" |
    /// "latency"). nil = OpenRouter's default routing. Ignored by other providers.
    var orProviderSort: String? = nil
    /// Milestone A is read-only: write/action and live-measurement tools stay off
    /// until Milestone B wires confirmation gates.
    var enableWriteTools: Bool = false
    var enableLiveMeasurements: Bool = false
    /// When true, the coach composer shows a camera/photo button so the user can
    /// attach an image to a message (multimodal input). Off by default.
    var enableImageInput: Bool = false
    var maxToolCalls: Int = 8
    var maxRounds: Int = 4
    // Milestone D — automated daily check-in notifications.
    var notificationsEnabled: Bool = false
    var morningHour: Int = 8
    var eveningHour: Int = 19

    /// The OpenRouter model slug to use. Free-form (the user may type any slug);
    /// falls back to the default only when the stored `model` is blank.
    var openRouterModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OpenRouterModel.default.rawValue : trimmed
    }

    static let `default` = CoachSettings()

    init() {}

    /// Tolerant decode: missing keys (older stored settings, new fields) fall back
    /// to defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CoachSettings.default
        coachMasterEnabled = try c.decodeIfPresent(Bool.self, forKey: .coachMasterEnabled) ?? d.coachMasterEnabled
        providerMode = try c.decodeIfPresent(CoachProviderMode.self, forKey: .providerMode) ?? d.providerMode
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        enableWebSearch = try c.decodeIfPresent(Bool.self, forKey: .enableWebSearch) ?? d.enableWebSearch
        orEnablePrivacyRouting = try c.decodeIfPresent(Bool.self, forKey: .orEnablePrivacyRouting) ?? d.orEnablePrivacyRouting
        orProviderSort = try c.decodeIfPresent(String.self, forKey: .orProviderSort)
        enableWriteTools = try c.decodeIfPresent(Bool.self, forKey: .enableWriteTools) ?? d.enableWriteTools
        enableLiveMeasurements = try c.decodeIfPresent(Bool.self, forKey: .enableLiveMeasurements) ?? d.enableLiveMeasurements
        enableImageInput = try c.decodeIfPresent(Bool.self, forKey: .enableImageInput) ?? d.enableImageInput
        maxToolCalls = try c.decodeIfPresent(Int.self, forKey: .maxToolCalls) ?? d.maxToolCalls
        maxRounds = try c.decodeIfPresent(Int.self, forKey: .maxRounds) ?? d.maxRounds
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        morningHour = try c.decodeIfPresent(Int.self, forKey: .morningHour) ?? d.morningHour
        eveningHour = try c.decodeIfPresent(Int.self, forKey: .eveningHour) ?? d.eveningHour
    }
}

/// Observable, UserDefaults-backed store for `CoachSettings`. Mutating `settings`
/// persists immediately. A shared instance keeps Settings and the coach in sync.
@MainActor
@Observable
final class CoachSettingsStore {
    static let shared = CoachSettingsStore()

    private static let storageKey = "pulseloop.coach.settings.v1"
    private let defaults: UserDefaults

    var settings: CoachSettings {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(CoachSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
