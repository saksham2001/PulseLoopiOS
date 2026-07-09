import Foundation

/// USD-per-1M-token rates for one model. `cachedInputPer1M` is the (cheaper)
/// prompt-cache-hit rate; `nil` means the model isn't cache-priced, so cached
/// input bills at the normal input rate.
struct CoachModelPrice: Equatable {
    let inputPer1M: Double
    let cachedInputPer1M: Double?
    let outputPer1M: Double
}

/// Estimates a turn's USD cost from token usage when the provider doesn't bill it
/// back (only OpenRouter reports exact cost). Keys are the provider model strings
/// from the `CoachSettings` enums; lookup is normalized (lowercase, strip the
/// OpenRouter `:online` web-search suffix), tries an exact match first, then the
/// longest matching key prefix, so a Custom slug like `openai/gpt-5.5-preview`
/// still prices off `openai/gpt-5.5`.
///
/// On-device / offline models are free ($0). An unknown free-form model returns
/// `nil` so the UI can show "cost unavailable" rather than a wrong number.
enum CoachPricingCatalog {
    /// Normalized-key → published list price, standard (non-batch) tier, as of
    /// July 2026. Sources: platform OpenAI/Google/DeepSeek/MiniMax pricing pages,
    /// platform.claude.com pricing docs, and openrouter.ai model pages. Estimates
    /// only — OpenRouter's API-reported exact cost always takes precedence.
    private static let table: [String: CoachModelPrice] = [
        // OpenAI (native) — CoachModel enum
        "gpt-5.4-mini": CoachModelPrice(inputPer1M: 0.75, cachedInputPer1M: 0.075, outputPer1M: 4.50),
        "gpt-5.4": CoachModelPrice(inputPer1M: 2.50, cachedInputPer1M: 0.25, outputPer1M: 15.00),
        "gpt-5.5": CoachModelPrice(inputPer1M: 5.00, cachedInputPer1M: 0.50, outputPer1M: 30.00),
        // Gemini (native) — GeminiModel enum. gemini-2.0-flash was shut down
        // June 1 2026 and has no published price; it intentionally has no entry
        // so the UI reports "cost unavailable".
        "gemini-2.5-flash": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: 0.03, outputPer1M: 2.50),
        "gemini-2.5-pro": CoachModelPrice(inputPer1M: 1.25, cachedInputPer1M: 0.125, outputPer1M: 10.00), // ≤200k-token tier; >200k bills 2x
        // OpenRouter — OpenRouterModel enum (vendor/model slugs). List prices
        // match the vendors'; cached rates use the vendor cache-read price.
        "anthropic/claude-sonnet-4.6": CoachModelPrice(inputPer1M: 3.00, cachedInputPer1M: 0.30, outputPer1M: 15.00),
        "anthropic/claude-opus-4.7": CoachModelPrice(inputPer1M: 5.00, cachedInputPer1M: 0.50, outputPer1M: 25.00),
        "openai/gpt-5.5": CoachModelPrice(inputPer1M: 5.00, cachedInputPer1M: 0.50, outputPer1M: 30.00),
        "openai/gpt-5.4-mini": CoachModelPrice(inputPer1M: 0.75, cachedInputPer1M: 0.075, outputPer1M: 4.50),
        "google/gemini-2.5-flash": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: 0.03, outputPer1M: 2.50),
        "google/gemini-2.5-pro": CoachModelPrice(inputPer1M: 1.25, cachedInputPer1M: 0.125, outputPer1M: 10.00),
        "deepseek/deepseek-v4-flash": CoachModelPrice(inputPer1M: 0.09, cachedInputPer1M: nil, outputPer1M: 0.18), // OpenRouter routes below DeepSeek's direct $0.14/$0.28
        // MiniMax — MiniMaxModel enum. No published cache-read rate; -highspeed
        // variants bill 2x the standard rate.
        "minimax-m3": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: nil, outputPer1M: 1.20), // ≤512k-token tier; >512k bills 2x
        "minimax-m2.7": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: nil, outputPer1M: 1.20),
        "minimax-m2.7-highspeed": CoachModelPrice(inputPer1M: 0.60, cachedInputPer1M: nil, outputPer1M: 2.40),
        "minimax-m2.5": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: nil, outputPer1M: 1.20),
        "minimax-m2.5-highspeed": CoachModelPrice(inputPer1M: 0.60, cachedInputPer1M: nil, outputPer1M: 2.40),
        "minimax-m2.1": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: nil, outputPer1M: 1.20),
        "minimax-m2.1-highspeed": CoachModelPrice(inputPer1M: 0.60, cachedInputPer1M: nil, outputPer1M: 2.40),
        "minimax-m2": CoachModelPrice(inputPer1M: 0.30, cachedInputPer1M: nil, outputPer1M: 1.20),
    ]

    /// The `effectiveModel` strings that always cost $0 (local / scripted).
    private static let freeModels: Set<String> = ["apple-on-device", "offline-stub"]

    /// The estimated USD cost of `usage` for `model`. Returns 0 for on-device /
    /// offline models, `nil` for an unrecognized model, else the priced estimate.
    static func cost(model: String, usage: CoachTokenUsage) -> Double? {
        guard let price = price(for: model) else { return nil }
        let cachedRate = price.cachedInputPer1M ?? price.inputPer1M
        let uncachedInput = max(0, usage.inputTokens - usage.cachedInputTokens)
        let dollars = (Double(uncachedInput) * price.inputPer1M
            + Double(usage.cachedInputTokens) * cachedRate
            + Double(usage.outputTokens) * price.outputPer1M) / 1_000_000
        return dollars
    }

    /// Resolves a model string to its price. Free models resolve to an all-zero
    /// price; unknown models return `nil`.
    static func price(for model: String) -> CoachModelPrice? {
        let key = normalize(model)
        if freeModels.contains(key) { return CoachModelPrice(inputPer1M: 0, cachedInputPer1M: 0, outputPer1M: 0) }
        if let exact = table[key] { return exact }
        // Longest-prefix fallback: a Custom slug like `openai/gpt-5.5-preview`
        // prices off the longest catalog key that it starts with.
        return table
            .filter { key.hasPrefix($0.key) }
            .max(by: { $0.key.count < $1.key.count })?
            .value
    }

    /// Lowercases and strips the OpenRouter `:online` web-search suffix so both the
    /// web-search and plain variants of a slug price the same.
    private static func normalize(_ model: String) -> String {
        var key = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix(":online") { key.removeLast(":online".count) }
        return key
    }
}
