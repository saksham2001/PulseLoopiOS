import Foundation

/// `GET {base}/v1/models` against a self-hosted server, so Settings can offer a real model picker
/// instead of making the user type `qwen3:8b` from memory.
///
/// Every engine in scope serves this route (it's how the OpenAI SDK enumerates models), and every
/// one returns the same envelope: `{"object":"list","data":[{"id":"…"},…]}`. Ollama lists pulled
/// models, LM Studio lists loaded ones, vLLM/SGLang list the single served model, and llama.cpp
/// lists the loaded model under its `--alias`. The list is advisory — the stored model stays a
/// free string, because a router in front of any of these can serve names the endpoint doesn't
/// enumerate.
enum LocalModelCatalog {

    /// One entry from the listing. ``contextWindow`` is the model's **context window** (prompt +
    /// completion) when the server volunteers it — NOT an output budget; see
    /// ``LocalCapabilityProbe`` for the derivation. Nil when the engine doesn't report it here.
    struct ModelInfo: Sendable, Equatable {
        let id: String
        var contextWindow: Int? = nil
    }

    /// The outcome of a refresh, kept as data so Settings can show the failure inline.
    enum Result: Sendable {
        case success([ModelInfo])
        /// Already user-facing.
        case failure(String)

        var models: [String] {
            if case .success(let entries) = self { return entries.map(\.id) }
            return []
        }
    }

    /// Short: this is a list lookup behind a button, not a generation.
    static let refreshTimeout: TimeInterval = 15

    static func fetch(
        baseURL: String,
        apiKey: String? = nil,
        timeout: TimeInterval = refreshTimeout
    ) async -> Result {
        if let problem = LocalEndpoint.validate(baseURL) {
            return .failure(LocalEndpoint.message(problem))
        }
        guard let url = LocalEndpoint.modelsURL(baseURL) else {
            return .failure(LocalEndpoint.message(.malformed))
        }
        var headers: [String: String] = [:]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }
        do {
            let data = try await LocalHTTP.get(url: url, headers: headers, timeout: timeout)
            return .success(try parseEntries(data))
        } catch ResponsesError.http(let status, _) {
            return .failure("The server answered HTTP \(status) for /v1/models.")
        } catch ResponsesError.transport(let underlying) {
            return .failure("Couldn't reach \(url.absoluteString) — \(underlying.localizedDescription)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Pulls the `id`s out of the OpenAI list envelope, sorted and de-duplicated. Falls back to a
    /// bare top-level array, which a couple of thin proxies return instead of the envelope.
    static func parse(_ data: Data) throws -> [String] { try parseEntries(data).map(\.id) }

    /// As ``parse(_:)``, but keeps each entry's context window when the server reports one
    /// alongside the id. The field name differs per engine and none of them is the OpenAI spec —
    /// vLLM writes `max_model_len`, llama.cpp `n_ctx` (with `n_ctx_train` as the model's trained
    /// maximum), and LM Studio `loaded_context_length` / `max_context_length` in its own richer
    /// listing. We take the first present, preferring what's actually *loaded* over what the model
    /// could support, because the loaded value is the one a request is measured against.
    static func parseEntries(_ data: Data) throws -> [ModelInfo] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let rows: [Any]
        if let object = root as? [String: Any], let list = object["data"] as? [Any] {
            rows = list
        } else if let list = root as? [Any] {
            rows = list
        } else {
            throw ResponsesError.decoding("No `data` array in the /v1/models response.")
        }

        var seen = Set<String>()
        var entries: [ModelInfo] = []
        for row in rows {
            let entry: ModelInfo?
            if let dict = row as? [String: Any] {
                entry = (dict["id"] as? String)
                    .flatMap { $0.isEmpty ? nil : ModelInfo(id: $0, contextWindow: contextWindow(of: dict)) }
            } else if let id = row as? String, !id.isEmpty {
                entry = ModelInfo(id: id)
            } else {
                entry = nil
            }
            if let entry, seen.insert(entry.id).inserted { entries.append(entry) }
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// The context window an entry advertises, under whichever name its engine uses.
    static func contextWindow(of entry: [String: Any]) -> Int? {
        for key in contextKeys {
            if let value = entry[key] as? Int, value > 0 { return value }
            if let value = (entry[key] as? NSNumber)?.intValue, value > 0 { return value }
        }
        return nil
    }

    /// Ordered by preference: loaded-context first, then configured, then trained maximum.
    private static let contextKeys = [
        "loaded_context_length",   // LM Studio (actually loaded)
        "max_model_len",           // vLLM
        "n_ctx",                   // llama.cpp (as served)
        "max_context_length",      // LM Studio (model ceiling)
        "context_length",          // generic / proxies
        "n_ctx_train",             // llama.cpp (model ceiling)
    ]
}
