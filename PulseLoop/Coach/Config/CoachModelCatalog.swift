import Foundation
import os

/// The models a cloud provider serves right now, read from its own model-list endpoint
/// once the provider is selected and its key saved — so Settings stops depending on
/// preset slugs that go stale. The presets (`CoachModel`, `GeminiModel`, …) stay the
/// curated picks shown first, and the fallback when the list can't be fetched.
///
/// Advisory, like `LocalModelCatalog`: the stored model stays a free string, so a model
/// the list omits still works if the provider serves it.
///
/// | Provider   | Endpoint                          | What it adds                         |
/// |------------|-----------------------------------|--------------------------------------|
/// | OpenAI     | `GET api.openai.com/v1/models`    | ids only — filtered to chat models   |
/// | Gemini     | `GET …/v1beta/models` (paged)     | display name, `generateContent` only |
/// | OpenRouter | `GET openrouter.ai/api/v1/models` | name, reasoning levels, expiry date  |
/// | MiniMax    | `GET api.minimax.io/v1/models`    | ids only                             |
///
/// Keys always travel in a header, never in the URL. OpenRouter is the only listing
/// that says which reasoning levels a model accepts (`reasoning.supported_efforts`)
/// or when it's being retired (`expiration_date`).
enum CoachModelCatalog {

    /// One listed model. `reasoningEfforts` nil = the listing doesn't say; empty = the
    /// model takes no effort hint. `expiresOn` is an ISO date (`2026-11-18`) when the
    /// provider has announced a retirement.
    struct Entry: Sendable, Equatable {
        let id: String
        var name: String?
        var reasoningEfforts: [ReasoningEffort]?
        var expiresOn: String?
    }

    struct Listing: Sendable, Equatable {
        let entries: [Entry]
        let fetchedAt: Date

        func entry(for model: String) -> Entry? {
            let slug = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return entries.first { $0.id == slug }
        }
    }

    enum Result: Sendable, Equatable {
        case success(Listing)
        /// Already user-facing.
        case failure(String)

        var listing: Listing? {
            if case .success(let listing) = self { return listing }
            return nil
        }
    }

    /// A refresh sits behind a provider switch, so it fails fast rather than hanging the picker.
    static let refreshTimeout: TimeInterval = 15
    /// Long enough that reopening Settings doesn't refetch; short enough to notice a new model the same day.
    static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private static let maxGeminiPages = 5

    /// The providers with a model-list endpoint. Local has its own (`LocalModelCatalog`).
    static func supports(_ provider: CoachProviderMode) -> Bool { endpoint(for: provider) != nil }

    static func endpoint(for provider: CoachProviderMode) -> URL? {
        switch provider {
        case .userOpenAIKey: return URL(string: "https://api.openai.com/v1/models")
        case .userGeminiKey: return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")
        case .userOpenRouterKey: return URL(string: "https://openrouter.ai/api/v1/models")
        // Global host, as MiniMaxClient uses.
        case .userMiniMaxKey: return URL(string: "https://api.minimax.io/v1/models")
        default: return nil
        }
    }

    // MARK: - Cache

    private struct Cached {
        let keyHash: Int
        let listing: Listing
    }

    /// In memory only, per provider; a different key misses. The raw key isn't kept.
    private static let cache = OSAllocatedUnfairLock(initialState: [CoachProviderMode: Cached]())

    /// The last successful listing for `provider`, when it was fetched with the same key and is fresh.
    static func cached(_ provider: CoachProviderMode, apiKey: String, now: Date = Date()) -> Listing? {
        cache.withLock { $0[provider] }.flatMap { cached in
            cached.keyHash == apiKey.hashValue && now.timeIntervalSince(cached.listing.fetchedAt) < cacheLifetime
                ? cached.listing : nil
        }
    }

    /// The listed entry for `model` under `provider`, from the cache only (no network).
    static func cachedEntry(_ provider: CoachProviderMode, model: String) -> Entry? {
        cache.withLock { $0[provider] }?.listing.entry(for: model)
    }

    /// Test seam: seed or clear the cache.
    static func store(_ listing: Listing?, for provider: CoachProviderMode, apiKey: String) {
        cache.withLock { $0[provider] = listing.map { Cached(keyHash: apiKey.hashValue, listing: $0) } }
    }

    // MARK: - Fetch

    /// Fetches the listing, or returns the cached one when `force` is false and it's still
    /// fresh. Never throws: a failure comes back as data for Settings to show inline.
    static func fetch(
        _ provider: CoachProviderMode, apiKey: String, force: Bool = false, session: URLSession = .shared
    ) async -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, let listing = cached(provider, apiKey: key) { return .success(listing) }
        guard let url = endpoint(for: provider) else { return .failure("This provider has no model list.") }
        guard !key.isEmpty else { return .failure("Save an API key to load the model list.") }
        do {
            let entries: [Entry]
            switch provider {
            case .userGeminiKey:
                entries = try await fetchGemini(url, apiKey: key, session: session)
            case .userOpenAIKey:
                entries = try parseOpenAI(try await get(url, bearer: key, session: session))
            case .userOpenRouterKey:
                entries = try parseOpenRouter(try await get(url, bearer: key, session: session))
            default:
                entries = try parseIds(try await get(url, bearer: key, session: session))
            }
            guard !entries.isEmpty else { return .failure("The provider listed no usable models.") }
            let listing = Listing(entries: entries, fetchedAt: Date())
            store(listing, for: provider, apiKey: key)
            return .success(listing)
        } catch ResponsesError.http(let status, _) {
            return .failure(status == 401 || status == 403
                ? "The provider rejected the key (HTTP \(status))."
                : "The provider answered HTTP \(status) for its model list.")
        } catch ResponsesError.transport(let underlying) {
            return .failure("Couldn't load the model list — \(underlying.localizedDescription)")
        } catch ResponsesError.decoding(let message) {
            return .failure(message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// True when a fetched listing doesn't include `model` — most likely retired, or (OpenRouter)
    /// no longer tool-capable. Not flagged: Gemini's rolling `-latest` aliases and OpenAI dated
    /// snapshots, which the listing never shows by design, and MiniMax presets (unverified that
    /// MiniMax lists every variant, so only a slug we no longer preset is flagged there).
    static func isUnlisted(_ provider: CoachProviderMode, listing: Listing, model: String) -> Bool {
        let slug = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty || listing.entry(for: slug) != nil { return false }
        switch provider {
        case .userGeminiKey where slug.hasSuffix("-latest"): return false
        case .userOpenAIKey where isDatedSnapshot(slug): return false
        case .userMiniMaxKey where MiniMaxModel(rawValue: slug) != nil: return false
        default: return true
        }
    }

    // MARK: - Parsing

    /// OpenAI lists every model the key can use — embeddings, speech, image, moderation and
    /// realtime ones included — with nothing but an id. Keep the text models the coach can
    /// drive through the Responses API, and drop dated snapshots (each is also listed under
    /// its alias) and retired slugs.
    static func parseOpenAI(_ data: Data) throws -> [Entry] {
        let ids = try dataArray(data).compactMap { ($0 as? [String: Any])?.nonBlank("id") }
        return Set(ids)
            .filter { id in
                (id.hasPrefix("gpt-") || id.range(of: #"^o\d+(-.*)?$"#, options: .regularExpression) != nil)
                    && !openAINonChat.contains { id.contains($0) }
                    && !isDatedSnapshot(id)
                    && !openAIRetired.contains(id)
            }
            .sorted()
            .map { Entry(id: $0) }
    }

    /// One page of `models.list`; ids come as `models/gemini-…` and are stored without the prefix.
    static func parseGeminiPage(_ data: Data) throws -> (entries: [Entry], nextPageToken: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding("The Gemini model list was not a JSON object.")
        }
        let entries = ((root["models"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap { m -> Entry? in
            guard let name = m.nonBlank("name") else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
            guard id.hasPrefix("gemini"), methods.contains("generateContent"),
                  !geminiNonChat.contains(where: { id.contains($0) }) else { return nil }
            return Entry(id: id, name: m.nonBlank("displayName"))
        }
        return (entries, root.nonBlank("nextPageToken"))
    }

    /// OpenRouter's listing is the richest: a name, `supported_parameters`, the reasoning
    /// levels the model accepts and an expiry date. The coach drives a tool loop, so a model
    /// without `tools` is left out; so are `:batch` variants, which aren't interactive.
    static func parseOpenRouter(_ data: Data) throws -> [Entry] {
        var seen = Set<String>()
        return try dataArray(data).compactMap { $0 as? [String: Any] }.compactMap { m -> Entry? in
            guard let id = m.nonBlank("id"), seen.insert(id).inserted else { return nil }
            let params = (m["supported_parameters"] as? [String]) ?? []
            guard params.contains("tools"), !id.hasSuffix(":batch") else { return nil }
            let listed = ((m["reasoning"] as? [String: Any])?["supported_efforts"] as? [String])
                .map { raw in ReasoningEffort.allCases.filter { raw.contains($0.rawValue) } }
            return Entry(
                id: id,
                name: m.nonBlank("name"),
                // No `reasoning` parameter at all: the model takes no effort hint.
                reasoningEfforts: listed ?? (params.contains("reasoning") ? nil : []),
                expiresOn: m.nonBlank("expiration_date"))
        }
        .sorted { $0.id < $1.id }
    }

    /// The bare OpenAI-style `{"data":[{"id":…}]}` envelope (MiniMax).
    static func parseIds(_ data: Data) throws -> [Entry] {
        Set(try dataArray(data).compactMap { ($0 as? [String: Any])?.nonBlank("id") }).sorted().map { Entry(id: $0) }
    }

    // MARK: - Internals

    private static func fetchGemini(_ url: URL, apiKey: String, session: URLSession) async throws -> [Entry] {
        var all: [Entry] = []
        var token: String?
        // The listing is a few dozen models; the page cap only guards against a looping token.
        for _ in 0..<maxGeminiPages {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page = try parseGeminiPage(try await get(components.url!, headers: ["x-goog-api-key": apiKey], session: session))
            all += page.entries
            token = page.nextPageToken
            if token == nil { break }
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }

    private static func get(_ url: URL, bearer key: String, session: URLSession) async throws -> Data {
        try await get(url, headers: ["Authorization": "Bearer \(key)"], session: session)
    }

    private static func get(_ url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = refreshTimeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResponsesError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ResponsesError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func dataArray(_ data: Data) throws -> [Any] {
        let root = try? JSONSerialization.jsonObject(with: data)
        if let object = root as? [String: Any], let list = object["data"] as? [Any] { return list }
        if let list = root as? [Any] { return list }
        throw ResponsesError.decoding("No `data` array in the model list.")
    }

    private static func isDatedSnapshot(_ slug: String) -> Bool {
        slug.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static let openAINonChat = [
        "embedding", "tts", "whisper", "transcribe", "audio", "realtime", "image", "dall-e",
        "moderation", "search", "instruct", "computer-use", "sora",
    ]
    /// Slugs the picker retired; still listed by OpenAI for older keys.
    private static let openAIRetired: Set<String> = ["gpt-4o", "gpt-4o-mini", "o4-mini"]
    private static let geminiNonChat = ["embedding", "tts", "image", "native-audio", "live", "aqa"]
}

private extension Dictionary where Key == String, Value == Any {
    func nonBlank(_ key: String) -> String? {
        guard let value = self[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
