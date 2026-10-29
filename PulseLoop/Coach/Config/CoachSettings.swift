import Foundation

/// Where the coach's "brain" runs. v1 ships `offlineStub` + `userOpenAIKey`;
/// `backendProxy` is reserved for a future public build (iOS → server → OpenAI)
/// and is treated as disabled until implemented.
enum CoachProviderMode: String, Codable, CaseIterable, Identifiable {
    case offlineStub
    case appleOnDevice
    case userOpenAIKey
    case userGeminiKey
    case userOpenRouterKey
    case userMiniMaxKey
    /// Any OpenAI-Chat-Completions-compatible server the user runs themselves: Ollama, llama.cpp,
    /// vLLM, SGLang, LM Studio. Declared after the keyed providers so inserting it doesn't disturb
    /// anyone's stored `rawValue`.
    case localOpenAICompat
    case backendProxy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .offlineStub: return "Offline"
        case .appleOnDevice: return "On-device (Apple)"
        case .userOpenAIKey: return "OpenAI"
        case .userGeminiKey: return "Gemini"
        case .userOpenRouterKey: return "OpenRouter"
        case .userMiniMaxKey: return "MiniMax"
        case .localOpenAICompat: return "Local / self-hosted"
        case .backendProxy: return "Backend proxy"
        }
    }
}

/// How hard to constrain a local model's output shape — see `docs/local-llm-coach.md` §5.
///
/// `.off` is the default because it's the only mode implemented by every backend: the coach's
/// shape is carried by `CoachResponseSchema.promptInstruction` in the system message, with the
/// orchestrator's JSON-repair loop as the backstop. The other two are opt-in because the support
/// matrix is genuinely uneven — LM Studio implements `json_schema` but not `json_object`, and some
/// llama.cpp builds error when `json_schema` collides with a server-side `grammar`.
enum LocalStructuredOutput: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case jsonObject
    case jsonSchema

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Prompt only"
        case .jsonObject: return "JSON mode"
        case .jsonSchema: return "Strict schema"
        }
    }

    var blurb: String {
        switch self {
        case .off: return "Works everywhere (default)"
        case .jsonObject: return "response_format: json_object — not on LM Studio"
        case .jsonSchema: return "response_format: json_schema — best when supported"
        }
    }
}

/// A `reasoning.effort` level. Which levels a model accepts varies — GPT-6 Sol/Astra
/// reject `none`, DeepSeek has no `medium`, Gemini stops at `high` — and an
/// unsupported level is an HTTP 400 on OpenAI, so each preset lists its own. On
/// Gemini the level is sent as `thinkingConfig.thinkingLevel`.
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }

    /// Levels every reasoning-capable model accepts — offered for a Custom slug.
    static let common: [ReasoningEffort] = [.low, .medium, .high]
    /// GPT-6 Sol/Astra and Claude 5.5.
    static let lowToMax: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
}

/// Preset MiniMax model choices surfaced in Settings. MiniMax's catalog is small
/// and fixed (unlike OpenRouter), so these are exact API model names rather than a
/// free-text field. The stored `CoachSettings.model` stays a string, so a new
/// model name still works if typed/served; these are just the curated picks.
///
/// The M2.5 and M2.7 families are omitted: MiniMax closes them to new users on
/// Oct 19 2026 and retires them on Nov 18 2026. `MiniMax-M3.1-Flash-Preview` is
/// plan-only (not pay-as-you-go), so it isn't offered to API-key users either.
enum MiniMaxModel: String, CaseIterable, Identifiable {
    case m3            = "MiniMax-M3"
    case m21           = "MiniMax-M2.1"
    case m21highspeed  = "MiniMax-M2.1-highspeed"
    case m2            = "MiniMax-M2"

    var id: String { rawValue }

    var label: String { rawValue }

    var blurb: String {
        switch self {
        case .m3:           return "Latest — agentic reasoning, tool use, 1M context (default)"
        case .m21:          return "Strong multi-language programming (~60 tps)"
        case .m21highspeed: return "M2.1 — faster (~100 tps)"
        case .m2:           return "Agentic capabilities, advanced reasoning"
        }
    }

    /// Sensible default when switching to MiniMax — the latest agentic model, best
    /// suited to the coach's multi-round tool loop.
    static let `default` = MiniMaxModel.m3
}

/// Preset Gemini model choices surfaced in Settings. `gemini-2.0-flash` was shut
/// down June 1 2026, and since Sep 18 2026 the 2.5 models only serve keys that
/// already used them, so the picks are the current Gemini 3/4 models.
enum GeminiModel: String, CaseIterable, Identifiable {
    case flash38    = "gemini-3.8-flash"
    case flashLite  = "gemini-3.5-flash-lite"
    case argon      = "gemini-4-argon"

    var id: String { rawValue }

    var label: String { rawValue }

    var blurb: String {
        switch self {
        case .flash38:   return "Fast & capable (default)"
        case .flashLite: return "Lowest cost & latency"
        case .argon:     return "Best reasoning"
        }
    }

    /// Accepted `thinkingConfig.thinkingLevel` values — 3.8 Flash and 4 Argon
    /// reject `minimal`.
    var reasoningEfforts: [ReasoningEffort] {
        switch self {
        case .flashLite: return [.minimal, .low, .medium, .high]
        case .flash38, .argon: return [.low, .medium, .high]
        }
    }

    static let `default` = GeminiModel.flash38
}

/// Preset OpenRouter model slugs surfaced in Settings. OpenRouter routes a
/// `vendor/model` slug to the underlying provider, and its catalog is large and
/// changes often — so the stored `CoachSettings.model` stays a free string and
/// Settings also exposes a "Custom…" text field where the user can type any
/// current slug from openrouter.ai/models. These are just the curated picks.
enum OpenRouterModel: String, CaseIterable, Identifiable {
    case claudeSonnet = "anthropic/claude-sonnet-5.5"
    case claudeOpus   = "anthropic/claude-opus-5.5"
    case claudeHaiku  = "anthropic/claude-haiku-5.5"
    case gptSol       = "openai/gpt-6.1-sol"
    case gptLuna      = "openai/gpt-6-luna"
    case geminiPro    = "google/gemini-4-argon"
    case geminiFlash  = "google/gemini-3.8-flash"
    case deepseek     = "deepseek/deepseek-v4.1-flash"

    var id: String { rawValue }

    var label: String { rawValue }

    var blurb: String {
        switch self {
        case .claudeSonnet: return "Balanced, great for coaching (default)"
        case .claudeOpus:   return "Most capable Claude"
        case .claudeHaiku:  return "Fastest, lowest-cost Claude"
        case .gptSol:       return "OpenAI balanced flagship"
        case .gptLuna:      return "Lower cost & latency"
        case .geminiPro:    return "Deep reasoning"
        case .geminiFlash:  return "Fast & capable"
        case .deepseek:     return "Strong open reasoning, low cost"
        }
    }

    /// Effort levels the model lists in OpenRouter's `reasoning.supported_efforts`.
    var reasoningEfforts: [ReasoningEffort] {
        switch self {
        case .claudeSonnet, .claudeOpus, .claudeHaiku, .gptSol: return ReasoningEffort.lowToMax
        case .gptLuna:                 return [.none] + ReasoningEffort.lowToMax
        case .geminiPro, .geminiFlash: return [.low, .medium, .high]
        case .deepseek:                return [.low, .high, .max]
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
    case luna = "gpt-6-luna"
    case sol = "gpt-6.1-sol"
    case astra = "gpt-6-astra"

    var id: String { rawValue }

    var label: String { rawValue }

    var blurb: String {
        switch self {
        case .luna: return "Lower cost & latency"
        case .sol: return "Balanced (default)"
        case .astra: return "Best reasoning"
        }
    }

    /// Accepted `reasoning.effort` levels — Sol and Astra reject `none` (HTTP 400).
    var reasoningEfforts: [ReasoningEffort] {
        switch self {
        case .luna: return [.none] + ReasoningEffort.lowToMax
        case .sol, .astra: return ReasoningEffort.lowToMax
        }
    }

    static let `default` = CoachModel.sol
}

/// User-tunable coach configuration, persisted as JSON in `UserDefaults`.
struct CoachSettings: Codable, Equatable {
    /// Master switch for all AI Coach features (tab, summaries, notifications).
    /// Off by default — users who only want metrics get a coach-free app.
    var coachMasterEnabled: Bool = false
    /// Default to Apple's on-device foundation model: it needs no API key and runs locally, so the
    /// coach works out of the box for everyone. Users who want a more powerful hosted model can switch
    /// provider and plug in their own key. (Only applies to fresh installs / unset settings; a user's
    /// saved choice is preserved via the tolerant decode below.)
    var providerMode: CoachProviderMode = .appleOnDevice
    /// Fallback model string used when the user switches to a keyed provider; user-configurable
    /// (never hard-coded in the client). Unused while on the Apple on-device model.
    var model: String = CoachModel.default.rawValue
    /// Optional reasoning effort hint (a `ReasoningEffort` raw value). Sent via
    /// `resolvedReasoningEffort`, which drops a level the current model doesn't accept.
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
    var middayHour: Int = 13
    var eveningHour: Int = 19
    /// Proactive, event-driven anomaly alerts (resting-HR drift, low SpO₂, poor
    /// sleep). On-device only — free/unlimited local inference makes "watch the
    /// stream and speak up when something looks off" practical. Off by default.
    var proactiveAlertsEnabled: Bool = false
    /// Opt-in: share the user's city name + current weather with the coach so it
    /// can ground practical advice (outdoor vs indoor, hydration, rain). City-level
    /// only — never the precise location. Off by default.
    var enableEnvironmentContext: Bool = false
    /// Local-only: base URL of the self-hosted server, as typed (`http://192.168.1.50:11434`).
    /// A URL that `LocalEndpoint.validate` accepts — not the key — is what gates readiness.
    var localBaseURL: String = ""
    /// Local-only: model name the server expects. Free-form; `/v1/models` populates the picker.
    var localModel: String = ""
    /// Local-only: send `tools`. Off for a server started without tool-call support (vLLM without
    /// `--enable-auto-tool-choice` returns HTTP 400) or a model that can't call them.
    var localToolCalling: Bool = true
    /// Local-only: how hard to constrain the output shape. Default off — the only mode every
    /// backend supports.
    var localStructuredOutput: LocalStructuredOutput = .off
    /// Local-only: `max_tokens`; 0 = omit and let the server decide.
    var localMaxTokens: Int = 0
    /// Local-only: read timeout in seconds. Long, because CPU inference is slow.
    var localTimeoutSeconds: Int = LocalOpenAICompatClient.defaultReadTimeoutSeconds

    /// The local base URL with surrounding whitespace gone; blank when unconfigured. There's no
    /// default to fall back to — every engine listens on a different port.
    var resolvedLocalBaseURL: String {
        localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The local model name. Blank is sent as-is rather than substituted: llama.cpp ignores the
    /// field entirely, so an empty value is legitimate there, and inventing a slug would turn a
    /// working setup into a 404 on the servers that do read it.
    var resolvedLocalModel: String {
        localModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The OpenRouter model slug to use. Free-form (the user may type any slug);
    /// falls back to the default only when the stored `model` is blank.
    var openRouterModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OpenRouterModel.default.rawValue : trimmed
    }

    /// The MiniMax model name to use. Falls back to the default only when the
    /// stored `model` is blank.
    var minimaxModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MiniMaxModel.default.rawValue : trimmed
    }

    /// The effort levels the selected preset accepts; `nil` when unknown (a Custom
    /// slug, a non-preset stored model) or when the provider takes no effort hint.
    var knownReasoningEfforts: [ReasoningEffort]? {
        switch providerMode {
        case .userOpenAIKey: return CoachModel(rawValue: model)?.reasoningEfforts
        case .userOpenRouterKey: return OpenRouterModel(rawValue: model)?.reasoningEfforts
        // A non-preset Gemini model may be a 2.5 model, which rejects `thinkingLevel`.
        case .userGeminiKey: return GeminiModel(rawValue: model)?.reasoningEfforts ?? []
        default: return nil
        }
    }

    /// The levels the Reasoning picker offers: the preset's own list, or the common
    /// subset for a Custom/legacy OpenAI or OpenRouter model. Empty hides the picker.
    var reasoningEffortOptions: [ReasoningEffort] {
        if let known = knownReasoningEfforts { return known }
        switch providerMode {
        case .userOpenAIKey, .userOpenRouterKey: return ReasoningEffort.common
        default: return []
        }
    }

    /// The effort to send: the stored hint, dropped back to the model's default when
    /// the selected preset doesn't accept it (e.g. `none` left over after switching
    /// from Luna to Sol). Unknown models pass the hint through unchanged.
    var resolvedReasoningEffort: String? {
        guard let effort = reasoningEffort, let supported = knownReasoningEfforts else { return reasoningEffort }
        return supported.contains { $0.rawValue == effort } ? effort : nil
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
        middayHour = try c.decodeIfPresent(Int.self, forKey: .middayHour) ?? d.middayHour
        eveningHour = try c.decodeIfPresent(Int.self, forKey: .eveningHour) ?? d.eveningHour
        proactiveAlertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .proactiveAlertsEnabled) ?? d.proactiveAlertsEnabled
        enableEnvironmentContext = try c.decodeIfPresent(Bool.self, forKey: .enableEnvironmentContext) ?? d.enableEnvironmentContext
        localBaseURL = try c.decodeIfPresent(String.self, forKey: .localBaseURL) ?? d.localBaseURL
        localModel = try c.decodeIfPresent(String.self, forKey: .localModel) ?? d.localModel
        localToolCalling = try c.decodeIfPresent(Bool.self, forKey: .localToolCalling) ?? d.localToolCalling
        localStructuredOutput = try c.decodeIfPresent(LocalStructuredOutput.self, forKey: .localStructuredOutput) ?? d.localStructuredOutput
        localMaxTokens = try c.decodeIfPresent(Int.self, forKey: .localMaxTokens) ?? d.localMaxTokens
        localTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .localTimeoutSeconds) ?? d.localTimeoutSeconds
    }
}

/// Observable, UserDefaults-backed store for `CoachSettings`. Mutating `settings`
/// persists immediately. A shared instance keeps Settings and the coach in sync.
@MainActor
@Observable
final class CoachSettingsStore {
    static let shared = CoachSettingsStore()

    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

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
