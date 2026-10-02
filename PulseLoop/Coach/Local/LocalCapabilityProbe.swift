import Foundation

/// Self-configuration for the local provider: given only a base URL, work out which engine is
/// behind it, what model it serves, and which optional request fields it will actually accept —
/// then hand back settings the user doesn't have to reason about.
///
/// **Why capabilities have to be probed rather than looked up.** `/v1/models` describes the model,
/// not the server's request surface, and the two things most likely to fail a coach turn are
/// decided at *launch time* by flags that endpoint never mentions: vLLM rejects `tools` unless it
/// was started with `--enable-auto-tool-choice --tool-call-parser`, and structured-output support
/// varies by backend and build (LM Studio implements `json_schema` but not `json_object`; some
/// llama.cpp builds error when `json_schema` meets a server-side `grammar`). The only honest test
/// is to send the field and see whether the server takes it.
///
/// Cost: three generations of at most a few tokens — a plain baseline request first, then the two
/// carrying the fields under test. The baseline is what makes a 4xx readable as "this field is
/// refused" rather than "this request is refused". On a server that has to page the model in first
/// (Ollama, LM Studio) the first of them can take tens of seconds — hence ``probeTimeout``.
///
/// Failure is never destructive. A probe that errors for an unrelated reason leaves that capability
/// at its safe default rather than switching it off, and the report says the probe was inconclusive
/// so the UI can say so too — and so Settings knows not to overwrite a value the user set by hand.
enum LocalCapabilityProbe {

    /// Which server is behind the URL. Cosmetic — it drives the summary line and the hints, not
    /// the request body; every real decision comes from ``Report``'s probed capabilities.
    enum Engine: String, Sendable {
        case ollama, llamaCPP, vllm, sglang, lmStudio, unknown

        var label: String {
            switch self {
            case .ollama: return "Ollama"
            case .llamaCPP: return "llama.cpp"
            case .vllm: return "vLLM"
            case .sglang: return "SGLang"
            case .lmStudio: return "LM Studio"
            case .unknown: return "OpenAI-compatible server"
            }
        }
    }

    /// A probed capability. ``unknown`` means the probe itself failed, so don't change the setting.
    enum Support: Sendable { case yes, no, unknown }

    struct Report: Sendable {
        var engine: Engine
        /// Engine version when it advertises one.
        var version: String? = nil
        var models: [String] = []
        /// The model to use: the sole served model, else the previously-chosen one if the server
        /// still lists it, else blank for the user to pick.
        var suggestedModel: String = ""
        var toolCalling: Support = .unknown
        var jsonSchema: Support = .unknown
        var jsonObject: Support = .unknown
        /// The server's **context window** for the chosen model (prompt + completion), when it
        /// reports one. This is NOT an output budget — see ``suggestedMaxTokens``.
        var contextWindow: Int? = nil
        /// Per-probe detail, shown under the summary so an inconclusive result is explainable.
        var notes: [String] = []

        /// The structured-output mode to store: the strongest one the server accepted. Falls back
        /// to `.off`, which needs nothing from the server.
        var suggestedStructuredOutput: LocalStructuredOutput {
            if jsonSchema == .yes { return .jsonSchema }
            if jsonObject == .yes { return .jsonObject }
            return .off
        }

        /// Tool calling stays ON unless the server actively refused it — an inconclusive probe
        /// must not silently strip the coach of its ability to read the user's data.
        var suggestedToolCalling: Bool { toolCalling != .no }

        /// Whether the probes actually reached a verdict, so a suggestion may **overwrite a
        /// setting the user chose by hand**.
        ///
        /// ``suggestedToolCalling`` and ``suggestedStructuredOutput`` both have a safe default for
        /// the inconclusive case, which is right for a first-time setup and wrong for a re-detect:
        /// a user who turned tools off for a vLLM server without `--enable-auto-tool-choice`, then
        /// pressed Detect to refresh the model list, would have them switched back on and every
        /// turn would 400. Probes are skipped entirely when the model comes back blank
        /// (``pickModel(_:currentModel:)`` on a multi-model server) or when the baseline request
        /// fails — neither says anything about capabilities.
        var toolCallingConclusive: Bool { toolCalling != .unknown }

        /// As ``toolCallingConclusive``. One conclusive probe is enough: a `yes` on the strict
        /// schema deliberately leaves the weaker JSON mode untested.
        var structuredOutputConclusive: Bool { jsonSchema != .unknown || jsonObject != .unknown }

        /// The value to store in **Max tokens**, derived from ``contextWindow``; 0 means "leave
        /// blank and let the server decide", i.e. *not detected* — never a reason to clear a value
        /// the user typed.
        ///
        /// A context window is not an output budget, and copying it across would be actively
        /// harmful: `max_tokens` is checked against what's *left* after the prompt, so a request
        /// with `prompt + max_tokens > context` is rejected outright. We therefore reserve
        /// ``promptReserveTokens`` for the coach's own prompt — measured at ~3.3k for a plain turn,
        /// doubled to cover tool results and replayed history — and cap the remainder at
        /// ``maxSuggestedTokens``, well past what a coach_response needs, so a huge context doesn't
        /// turn into a runaway generation budget.
        var suggestedMaxTokens: Int {
            guard let ctx = contextWindow else { return 0 }
            let headroom = ctx - promptReserveTokens
            if headroom < minUsefulOutputTokens { return 0 }
            return min(headroom, maxSuggestedTokens)
        }

        /// True when the reported context can't comfortably hold the coach's prompt, so the user
        /// needs to raise it on the server (Ollama `num_ctx`, llama.cpp `-c`, vLLM
        /// `--max-model-len`) rather than tune anything in the app.
        var contextTooSmall: Bool {
            guard let ctx = contextWindow else { return false }
            return ctx - promptReserveTokens < minUsefulOutputTokens
        }

        /// One line for the Settings summary.
        var summary: String {
            var out = engine.label
            if let version { out += " \(version)" }
            out += " · " + (suggestedModel.isEmpty ? "\(models.count) model(s)" : suggestedModel)
            out += " · tools "
            switch toolCalling {
            case .yes: out += "yes"
            case .no: out += "no"
            case .unknown: out += "unknown"
            }
            out += " · "
            switch suggestedStructuredOutput {
            case .jsonSchema: out += "strict schema"
            case .jsonObject: out += "JSON mode"
            case .off: out += "prompt-only"
            }
            if let ctx = contextWindow { out += " · \(formatTokens(ctx)) ctx" }
            return out
        }
    }

    /// Raised when the server can't be reached or isn't OpenAI-compatible — ``run`` 's only hard
    /// failure. Everything after model discovery degrades to ``Support/unknown`` instead.
    struct Unreachable: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Discovers everything about [baseURL] in one pass. [currentModel] is preserved when the
    /// server still lists it, so re-probing doesn't silently move a working setup to another model.
    static func run(
        baseURL: String,
        apiKey: String? = nil,
        currentModel: String = ""
    ) async throws -> Report {
        if let problem = LocalEndpoint.validate(baseURL) {
            throw Unreachable(reason: LocalEndpoint.message(problem))
        }
        var headers: [String: String] = [:]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }

        // 1. Models — also the reachability check, so its failure is the one hard failure.
        let entries: [LocalModelCatalog.ModelInfo]
        switch await LocalModelCatalog.fetch(baseURL: baseURL, apiKey: apiKey) {
        case .success(let found): entries = found
        case .failure(let message): throw Unreachable(reason: message)
        }
        let models = entries.map(\.id)
        let model = pickModel(models, currentModel: currentModel)

        // 2. Engine identity — best-effort, from the engine-specific info routes. Never fatal.
        let (engine, version) = await identify(baseURL: baseURL, headers: headers)

        // Context window: from the listing when the engine puts it there (vLLM, llama.cpp,
        // LM Studio), else from that engine's own route.
        // `??` takes an autoclosure, which can't be async — so the fallback is spelled out.
        var context = entries.first(where: { $0.id == model })?.contextWindow
        if context == nil {
            context = await contextFromEngine(
                baseURL: baseURL, headers: headers, engine: engine, model: model)
        }

        var notes: [String] = []
        if let context, context - promptReserveTokens < minUsefulOutputTokens {
            notes.append(
                "Context is only \(formatTokens(context)) — the coach's prompt alone is around "
                + "\(formatTokens(promptReserveTokens / 2)). Raise it on the server "
                + "(Ollama `num_ctx`, llama.cpp `-c`, vLLM `--max-model-len`) or replies will be "
                + "truncated.")
        }
        if model.isEmpty {
            // Capability probes need a model name on every engine except llama.cpp, and without
            // one a 400 would be indistinguishable from "capability unsupported".
            notes.append("Pick a model, then run this again to detect tools and response format.")
            return Report(engine: engine, version: version, models: models, suggestedModel: model,
                          contextWindow: context, notes: notes)
        }

        // 3. Baseline. A plain chat request with no optional fields at all, so the 4xx-means-no
        //    reading below is about the probed field rather than about the request as a whole.
        //    Skipping this was how an unloadable model id or an auth-gated chat route turned into
        //    "tools: not supported" and a persisted `toolCalling = false`.
        switch await send(baseURL: baseURL, headers: headers, model: model, extra: baselineProbe) {
        case .accepted:
            break
        case .refused(let status, let body):
            notes.append(
                "The server refused a plain chat request for `\(model)` (HTTP \(status)) — "
                + "\(shorten(body)). Tools and response format couldn't be tested, so both are "
                + "left unchanged. Check the model can actually load and that the chat route "
                + "accepts the same key as /v1/models.")
            return Report(engine: engine, version: version, models: models, suggestedModel: model,
                          contextWindow: context, notes: notes)
        case .inconclusive(let reason):
            notes.append(
                "Couldn't complete a plain chat request (\(reason)) — tools and response format "
                + "are left unchanged.")
            return Report(engine: engine, version: version, models: models, suggestedModel: model,
                          contextWindow: context, notes: notes)
        }

        // 4. Capability probes.
        let tools = await probe(baseURL: baseURL, headers: headers, model: model,
                                extra: toolProbe, label: "Tool calling", notes: &notes)
        let schema = await probe(baseURL: baseURL, headers: headers, model: model,
                                 extra: schemaProbe, label: "Strict schema", notes: &notes)
        // Only worth asking about the weaker mode when the stronger one was refused.
        let object: Support = schema == .yes
            ? .unknown
            : await probe(baseURL: baseURL, headers: headers, model: model,
                          extra: jsonObjectProbe, label: "JSON mode", notes: &notes)

        return Report(engine: engine, version: version, models: models, suggestedModel: model,
                      toolCalling: tools, jsonSchema: schema, jsonObject: object,
                      contextWindow: context, notes: notes)
    }

    /// Sole model → use it. Otherwise keep the user's current pick when the server still has it;
    /// else blank, because guessing among several would silently switch a working setup.
    static func pickModel(_ models: [String], currentModel: String) -> String {
        if !currentModel.isEmpty, models.contains(currentModel) { return currentModel }
        if models.count == 1 { return models[0] }
        return ""
    }

    // MARK: - Engine identity

    /// Asks each engine's own info route in turn and stops at the first that answers. These are
    /// distinct paths rather than a single field because `owned_by` in `/v1/models` is unreliable
    /// (vLLM says "vllm", but Ollama says "library" and LM Studio says "organization_owner", and a
    /// proxy rewrites all of them). Every call is best-effort — an engine we can't name still works.
    private static func identify(baseURL: String, headers: [String: String]) async -> (Engine, String?) {
        guard let base = LocalEndpoint.normalize(baseURL) else { return (.unknown, nil) }
        // vLLM: GET /version -> {"version":"0.27.1"}
        if let body = await get("\(base)/version", headers), let v = versionField(body) { return (.vllm, v) }
        // Ollama: GET /api/version -> {"version":"0.x.y"}
        if let body = await get("\(base)/api/version", headers), let v = versionField(body) { return (.ollama, v) }
        // llama.cpp: GET /props -> build_info / default_generation_settings
        if let body = await get("\(base)/props", headers), let root = jsonObject(body),
           root["build_info"] != nil || root["default_generation_settings"] != nil {
            return (.llamaCPP, root["build_info"] as? String)
        }
        // SGLang: GET /get_server_info -> model_path / version
        if let body = await get("\(base)/get_server_info", headers), let root = jsonObject(body),
           root["model_path"] != nil || root["version"] != nil {
            return (.sglang, root["version"] as? String)
        }
        // LM Studio: its richer native listing, absent everywhere else.
        if await get("\(base)/api/v0/models", headers) != nil { return (.lmStudio, nil) }
        return (.unknown, nil)
    }

    /// The context window from an engine's own route, for the ones that don't put it in
    /// `/v1/models`. Best-effort: a nil here just means the app won't suggest a budget.
    ///
    /// Ollama is the one that matters. Its `/v1/models` carries no context at all, and its default
    /// `num_ctx` is **2048** — smaller than the coach's own prompt — so without this a user would
    /// get silently truncated context and blame the model.
    private static func contextFromEngine(
        baseURL: String, headers: [String: String], engine: Engine, model: String
    ) async -> Int? {
        guard let base = LocalEndpoint.normalize(baseURL) else { return nil }
        switch engine {
        case .ollama:
            guard !model.isEmpty, let url = URL(string: "\(base)/api/show"),
                  let body = try? JSONSerialization.data(withJSONObject: ["model": model]) else { return nil }
            guard let data = try? await LocalHTTP.post(url: url, body: body, headers: headers,
                                                       timeout: identifyTimeout),
                  let text = String(data: data, encoding: .utf8),
                  let info = jsonObject(text)?["model_info"] as? [String: Any] else { return nil }
            // `model_info` is keyed by architecture, e.g. "qwen3.context_length", so match on the
            // suffix rather than guessing the family.
            for (key, value) in info where key.hasSuffix(".context_length") {
                if let n = value as? Int, n > 0 { return n }
                if let n = (value as? NSNumber)?.intValue, n > 0 { return n }
            }
            return nil
        case .sglang:
            guard let text = await get("\(base)/get_model_info", headers),
                  let root = jsonObject(text) else { return nil }
            return LocalModelCatalog.contextWindow(of: root)
        case .llamaCPP:
            guard let text = await get("\(base)/props", headers), let root = jsonObject(text) else { return nil }
            return LocalModelCatalog.contextWindow(of: root)
                ?? (root["default_generation_settings"] as? [String: Any])
                    .flatMap { LocalModelCatalog.contextWindow(of: $0) }
        default:
            return nil
        }
    }

    /// "262144" → "262k"; small values stay exact so a 2048 warning reads literally.
    static func formatTokens(_ tokens: Int) -> String {
        tokens >= 10_000 ? "\(tokens / 1000)k" : "\(tokens)"
    }

    private static func get(_ url: String, _ headers: [String: String]) async -> String? {
        guard let url = URL(string: url) else { return nil }
        guard let data = try? await LocalHTTP.get(url: url, headers: headers, timeout: identifyTimeout)
        else { return nil }   // A 404 here just means "not this engine".
        return String(data: data, encoding: .utf8)
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func versionField(_ body: String) -> String? { jsonObject(body)?["version"] as? String }

    // MARK: - Capability probes

    /// What one probe request actually got back, before it is read as a capability verdict.
    private enum Outcome {
        case accepted
        /// The server answered 4xx — it read the request and refused it.
        case refused(status: Int, body: String)
        /// 5xx, transport failure, or an unusable URL: says nothing either way.
        case inconclusive(String)
    }

    /// Sends a one-token chat request carrying [extra] and reports what came back.
    private static func send(
        baseURL: String, headers: [String: String], model: String, extra: [String: Any]
    ) async -> Outcome {
        guard let url = LocalEndpoint.chatCompletionsURL(baseURL) else {
            return .inconclusive("the server address couldn't be parsed")
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": probeMaxTokens,
        ]
        for (key, value) in extra { payload[key] = value }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .inconclusive("couldn't encode the probe request")
        }
        do {
            _ = try await LocalHTTP.post(url: url, body: body, headers: headers, timeout: probeTimeout)
            return .accepted
        } catch ResponsesError.http(let status, let body) {
            return (400...499).contains(status)
                ? .refused(status: status, body: body)
                : .inconclusive("HTTP \(status)")
        } catch {
            return .inconclusive(error.localizedDescription)
        }
    }

    /// Sends [extra] alongside a one-token chat request and classifies the answer.
    ///
    /// A 4xx is the server telling us it won't take the field — that's ``Support/no``, and the
    /// exact status doesn't matter (vLLM answers 400 for a disabled tool parser and 422 for a field
    /// its deserializer doesn't know). A 5xx or a transport failure says nothing about the
    /// capability, so it stays ``Support/unknown`` and the caller keeps its default.
    ///
    /// Reading a 4xx as "this field is unsupported" is only sound because ``run`` has already
    /// established with ``baselineProbe`` that a request carrying *no* optional fields succeeds.
    /// Without that, every whole-request rejection — a model id `/v1/models` lists but can't load,
    /// a chat route that wants auth when the listing didn't, a broken chat template — would come
    /// back as "tools: no" and silently persist tool calling off, which costs the coach all access
    /// to the user's data.
    private static func probe(
        baseURL: String, headers: [String: String], model: String,
        extra: [String: Any], label: String, notes: inout [String]
    ) async -> Support {
        switch await send(baseURL: baseURL, headers: headers, model: model, extra: extra) {
        case .accepted:
            return .yes
        case .refused(let status, let body):
            notes.append("\(label): not supported (HTTP \(status)) — \(shorten(body))")
            return .no
        case .inconclusive(let reason):
            notes.append("\(label): couldn't tell (\(reason)) — left unchanged.")
            return .unknown
        }
    }

    /// Server error bodies are verbose; the first line is the part worth showing.
    private static func shorten(_ body: String) -> String {
        let message = jsonObject(body)
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? body
        return String(message.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).first ?? "").prefix(160).description
    }

    /// Nothing optional at all — the control the capability probes are measured against.
    private static let baselineProbe: [String: Any] = [:]

    /// A throwaway tool. Named so it can't collide with a real coach tool in a server-side log.
    private static let toolProbe: [String: Any] = [
        "tools": [[
            "type": "function",
            "function": [
                "name": "pulseloop_probe",
                "description": "Capability probe. Do not call.",
                "parameters": ["type": "object", "properties": [String: Any]()],
            ],
        ]],
    ]

    /// A minimal schema, not the coach's: we're testing whether the *field* is accepted, and a
    /// large schema risks a rejection about the schema itself rather than the capability.
    private static let schemaProbe: [String: Any] = [
        "response_format": [
            "type": "json_schema",
            "json_schema": [
                "name": "pulseloop_probe",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": ["ok": ["type": "string"]],
                    "required": ["ok"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
    ]

    private static let jsonObjectProbe: [String: Any] = [
        "response_format": ["type": "json_object"],
    ]

    /// Long enough for a cold model to page in on Ollama/LM Studio.
    static let probeTimeout: TimeInterval = 120
    /// Short: these routes either exist or 404 immediately.
    static let identifyTimeout: TimeInterval = 10
    /// Enough that a grammar-constrained probe emits something, small enough to stay cheap.
    static let probeMaxTokens = 8

    /// Context reserved for input before any of it is offered as output budget. A plain coach turn
    /// measured 3.1–3.3k input tokens on a real device; this doubles that so a turn that replays
    /// history and feeds back tool results still fits.
    static let promptReserveTokens = 6144

    /// Below this much headroom, suggesting a budget is worse than saying the context is too small.
    static let minUsefulOutputTokens = 512

    /// A coach_response plus reasoning needs far less than this; the cap stops a 262k context from
    /// becoming a licence for a runaway generation.
    static let maxSuggestedTokens = 32_768
}
