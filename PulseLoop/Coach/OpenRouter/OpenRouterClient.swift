import Foundation

/// Adapts the app's `ResponsesClient` protocol to OpenRouter's OpenAI-compatible
/// **Chat Completions** API (`POST /api/v1/chat/completions`). OpenRouter is an
/// aggregator: `model` is a `vendor/model` slug (e.g. `anthropic/claude-sonnet-4.6`)
/// that it routes to the underlying provider. Translates the app's Responses-API
/// request bodies into Chat Completions requests and maps responses back, so no
/// other component needs to know which provider is active.
///
/// State across turns: the OpenAI Responses API is stateful (server tracks
/// history via `previous_response_id`); Chat Completions is stateless (caller
/// sends the full message list each time). This class accumulates the
/// conversation as Chat Completions `messages` across `send` calls; each instance
/// covers exactly one agent turn (the orchestrator creates a fresh client per
/// turn via the factory).
final class OpenRouterClient: ResponsesClient, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    // OpenRouter-only routing options (see `CoachSettings`). Threaded in from the
    // resolveClient sites alongside `model`; the native clients ignore them.
    private let privacyRouting: Bool
    private let providerSort: String?
    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    // Accumulated Chat Completions messages for this turn.
    private var messages: [[String: Any]] = []
    // Maps generated response IDs → the assistant message dict (content + tool_calls)
    // so a continuation turn can re-insert it before the matching tool results.
    private var storedAssistantMessage: [String: [String: Any]] = [:]
    // Set in `convertTools` when the orchestrator's hosted `web_search` tool spec
    // is seen; routes to OpenRouter's `:online` model suffix (see `onlineModelSlug`).
    private var webSearchRequested = false

    init(
        apiKey: String,
        model: String = OpenRouterModel.default.rawValue,
        privacyRouting: Bool = false,
        providerSort: String? = nil,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.privacyRouting = privacyRouting
        self.providerSort = providerSort
        self.session = session
    }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        guard !apiKey.isEmpty else { throw ResponsesError.missingAPIKey }

        guard let req = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            throw ResponsesError.decoding("OpenRouterClient: invalid request body")
        }

        let input = req["input"] as? [[String: Any]] ?? []
        let tools = req["tools"] as? [[String: Any]] ?? []
        let previousResponseId = req["previous_response_id"] as? String
        // OpenRouter accepts the same unified `reasoning` object the app already
        // builds (`{ "effort": "low|medium|high" }`); it's ignored for models that
        // don't reason, so forward it as-is when present.
        let reasoning = req["reasoning"]
        // The Responses-API `text.format` carries the strict coach_response JSON
        // schema; we translate it to Chat Completions `response_format`.
        let textFormat = (req["text"] as? [String: Any])?["format"] as? [String: Any]

        if previousResponseId == nil {
            setupConversation(from: input)
        } else {
            appendContinuation(previousId: previousResponseId!, input: input)
        }

        let body = buildChatBody(tools: convertTools(tools), reasoning: reasoning, textFormat: textFormat)
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Optional attribution headers OpenRouter uses for its app leaderboard.
        request.setValue("https://github.com/hoveeman/PulseLoopIOS", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("PulseLoop", forHTTPHeaderField: "X-Title")
        request.httpBody = bodyData
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResponsesError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ResponsesError.http(status: http.statusCode, body: body)
        }

        return try parseChatResponse(data)
    }

    // MARK: - Conversation setup

    /// First turn: convert the Responses `input` items into Chat Completions
    /// `messages`. Responses uses a `developer` role; Chat Completions doesn't, so
    /// fold it into `system`.
    private func setupConversation(from input: [[String: Any]]) {
        messages = []
        storedAssistantMessage = [:]
        for item in input {
            guard let role = item["role"] as? String, item["content"] != nil else { continue }
            messages.append(["role": chatRole(role), "content": chatContent(from: item)])
        }
        // Unlike the native OpenAI/Gemini clients, OpenRouter sends no enforced
        // `response_format` (several catalog models reject this app's schema), so
        // the model isn't told the required output shape out-of-band. Inject the
        // field spec as a system message so it can produce valid coach_response
        // JSON from the prompt alone.
        messages.append(["role": "system", "content": CoachResponseSchema.promptInstruction])
    }

    /// Subsequent turns: replay the stored assistant message for `previousId`
    /// (Chat Completions requires the assistant `tool_calls` message to precede the
    /// `tool` results answering them), then append the new tool results / messages.
    private func appendContinuation(previousId: String, input: [[String: Any]]) {
        if let assistant = storedAssistantMessage[previousId] {
            messages.append(assistant)
        }
        for item in input {
            if (item["type"] as? String) == "function_call_output",
               let callId = item["call_id"] as? String,
               let output = item["output"] as? String {
                messages.append(["role": "tool", "tool_call_id": callId, "content": output])
            } else if let role = item["role"] as? String, item["content"] != nil {
                messages.append(["role": chatRole(role), "content": chatContent(from: item)])
            }
        }
    }

    private func chatRole(_ responsesRole: String) -> String {
        responsesRole == "developer" ? "system" : responsesRole
    }

    /// Converts a Responses-API message item's `content` into Chat Completions
    /// `content`. Text items keep `content` a plain String (unchanged path, so the
    /// cache-control rewrite still applies). Image items carry the OpenAI
    /// content-part array (`input_text` + `input_image`), which we map to Chat
    /// Completions parts (`{type:text}` + `{type:image_url, image_url:{url}}`).
    private func chatContent(from item: [String: Any]) -> Any {
        if let text = item["content"] as? String { return text }
        guard let parts = item["content"] as? [[String: Any]] else { return "" }
        var out: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "text":
                if let text = part["text"] as? String { out.append(["type": "text", "text": text]) }
            case "input_image":
                if let url = part["image_url"] as? String {
                    out.append(["type": "image_url", "image_url": ["url": url]])
                }
            default:
                break
            }
        }
        return out
    }

    // MARK: - Tool conversion (Responses flat → Chat Completions nested)

    /// Converts the app's flat Responses function specs
    /// (`{type, name, description, parameters}`) into Chat Completions' nested
    /// shape (`{type: function, function: {...}}`). The OpenAI-hosted `web_search`
    /// tool (type != "function") has no Chat Completions function equivalent, so
    /// it's dropped here and instead routed via OpenRouter's `:online` model suffix
    /// (see `onlineModelSlug`), which works across the whole catalog and needs no
    /// extra tool-loop round trip.
    private func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            let type = tool["type"] as? String
            if type == "web_search" || type == "web_search_preview" {
                webSearchRequested = true
                return nil
            }
            guard type == "function", let name = tool["name"] as? String else { return nil }
            var fn: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String { fn["description"] = desc }
            if let params = tool["parameters"] as? [String: Any] { fn["parameters"] = params }
            if let strict = tool["strict"] as? Bool { fn["strict"] = strict }
            return ["type": "function", "function": fn]
        }
    }

    // MARK: - Build request body

    private func buildChatBody(tools: [[String: Any]], reasoning: Any?, textFormat: [String: Any]?) -> [String: Any] {
        var body: [String: Any] = ["model": onlineModelSlug(), "messages": cacheControlledMessages()]

        if !tools.isEmpty {
            // Cache the (large, static) tool block — re-sent on every round and
            // identical across questions. A breakpoint on the last tool caches the
            // whole tools prefix on providers that support it (Anthropic, etc.);
            // OpenRouter strips `cache_control` for providers that don't.
            var cachedTools = tools
            cachedTools[cachedTools.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = cachedTools
        }

        // Enforce the coach_response shape via OpenRouter structured outputs
        // (https://openrouter.ai/docs/guides/features/structured-outputs). We send
        // `response_format` with `strict: true`, and `provider.require_parameters`
        // (below) makes OpenRouter route only to providers that actually honor it —
        // so models/providers that can't enforce this schema are skipped rather than
        // silently returning prose. `promptInstruction` (a system message) remains
        // as a belt-and-suspenders backup for models that ignore the schema.
        if let responseFormat = chatResponseFormat(from: textFormat) {
            body["response_format"] = responseFormat
        }

        if let reasoning { body["reasoning"] = reasoning }

        if let provider = providerOptions(requireParameters: body["response_format"] != nil) {
            body["provider"] = provider
        }

        return body
    }

    /// Translates the Responses-API `text.format` object
    /// (`{type:"json_schema", name, schema, strict}`) into the Chat Completions
    /// `response_format` shape OpenRouter expects
    /// (`{type:"json_schema", json_schema:{name, strict, schema}}`).
    private func chatResponseFormat(from textFormat: [String: Any]?) -> [String: Any]? {
        guard let textFormat,
              (textFormat["type"] as? String) == "json_schema",
              let schema = textFormat["schema"] as? [String: Any] else { return nil }
        var jsonSchema: [String: Any] = ["schema": schema, "strict": true]
        if let name = textFormat["name"] as? String { jsonSchema["name"] = name }
        return ["type": "json_schema", "json_schema": jsonSchema]
    }

    /// The model slug to send, with OpenRouter's `:online` web-search suffix
    /// appended when the orchestrator requested web search. Not doubled if the
    /// slug already ends in `:online` (e.g. a user-typed Custom slug).
    private func onlineModelSlug() -> String {
        guard webSearchRequested, !model.hasSuffix(":online") else { return model }
        return model + ":online"
    }

    /// OpenRouter's top-level `provider` routing object, assembled from the
    /// OpenRouter-only settings. `data_collection: "deny"` excludes providers that
    /// log/train on prompts; `sort` biases provider selection;
    /// `require_parameters: true` makes OpenRouter route only to providers that
    /// honor every parameter we send (notably `response_format`), so the structured
    /// output is actually enforced. Returns nil when nothing is set.
    private func providerOptions(requireParameters: Bool) -> [String: Any]? {
        var provider: [String: Any] = [:]
        if requireParameters { provider["require_parameters"] = true }
        if privacyRouting { provider["data_collection"] = "deny" }
        if let sort = providerSort, !sort.isEmpty { provider["sort"] = sort }
        return provider.isEmpty ? nil : provider
    }

    // MARK: - Prompt caching

    /// Returns `messages` with Anthropic-style `cache_control` breakpoints on the
    /// system messages so the large static prefix isn't re-billed at full price on
    /// every tool-loop round / question. The first system message (the static coach
    /// system prompt) caches cross-question; the last (the per-question data context)
    /// caches across this question's rounds. `cache_control` is ignored by providers
    /// that don't support it.
    private func cacheControlledMessages() -> [[String: Any]] {
        var out = messages
        let systemIdxs = out.indices.filter { (out[$0]["role"] as? String) == "system" }
        if let first = systemIdxs.first { out[first] = withCacheControl(out[first]) }
        if let last = systemIdxs.last, last != systemIdxs.first { out[last] = withCacheControl(out[last]) }
        return out
    }

    /// Converts a string-content message into the Chat Completions content-array
    /// form carrying a `cache_control` breakpoint.
    private func withCacheControl(_ message: [String: Any]) -> [String: Any] {
        guard let text = message["content"] as? String else { return message }
        var m = message
        m["content"] = [["type": "text", "text": text, "cache_control": ["type": "ephemeral"]]]
        return m
    }

    // MARK: - Parse Chat Completions response → OpenAIResponse

    private func parseChatResponse(_ data: Data) throws -> OpenAIResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding("OpenRouterClient: response was not a JSON object")
        }

        // OpenRouter can surface an upstream provider error in an `error` object
        // even on an HTTP 200.
        if let err = root["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "unknown error"
            throw ResponsesError.decoding("OpenRouter error: \(msg)")
        }

        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ResponsesError.decoding("OpenRouterClient: no choices in response — \(body.prefix(300))")
        }

        let responseId = (root["id"] as? String).map { $0.isEmpty ? UUID().uuidString : $0 } ?? UUID().uuidString
        var outputItems: [ResponseOutputItem] = []
        // Persist the raw assistant message so a continuation turn can replay it.
        var assistantMessage: [String: Any] = ["role": "assistant"]

        if let content = message["content"] as? String, !content.isEmpty {
            outputItems.append(.message(text: content))
            assistantMessage["content"] = content
        } else {
            // Chat Completions allows null content when tool_calls are present.
            assistantMessage["content"] = NSNull()
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            var storedCalls: [[String: Any]] = []
            for call in toolCalls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                // Reuse OpenRouter's own tool_call id as the orchestrator's call_id so
                // the tool result message can reference it on the next turn.
                let callId = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "or_call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
                let args = fn["arguments"] as? String ?? "{}"
                outputItems.append(.functionCall(ResponseFunctionCall(name: name, callID: callId, arguments: args)))
                storedCalls.append([
                    "id": callId,
                    "type": "function",
                    "function": ["name": name, "arguments": args],
                ])
            }
            if !storedCalls.isEmpty { assistantMessage["tool_calls"] = storedCalls }
        }

        if outputItems.isEmpty { throw ResponsesError.emptyOutput }

        storedAssistantMessage[responseId] = assistantMessage
        return OpenAIResponse(id: responseId, outputItems: outputItems)
    }
}
