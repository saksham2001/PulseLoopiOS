import Foundation

/// The self-hosted / local coach client — see `docs/local-llm-coach.md`.
///
/// Adapts the app's `ResponsesClient` protocol to the OpenAI **Chat Completions** API
/// (`POST {base}/v1/chat/completions`) as implemented by Ollama, llama.cpp's `llama-server`,
/// vLLM, SGLang, LM Studio and friends. Structurally this is `MiniMaxClient` — same
/// Responses→Chat translation, same accumulate-messages-across-`send` statefulness, same
/// fresh-client-per-turn contract from the factory — with four deliberate differences, each forced
/// by something a local backend does that a hosted one doesn't:
///
///  1. **The API key is optional.** Every one of these servers runs unauthenticated by default
///     (`--api-key` is opt-in on llama.cpp/vLLM/SGLang; Ollama ignores the field entirely). A blank
///     key omits the `Authorization` header rather than throwing — the readiness sentinel is the
///     **base URL** instead (see `CoachClientResolver`).
///  2. **`developer` is folded into `system`, and all system turns are merged into one leading
///     message.** SGLang validates roles against a pydantic `Literal` and raises (→ HTTP 400) for a
///     role outside it; vLLM accepts `developer` and hands it to a Jinja chat template that usually
///     has no branch for it. Many local templates additionally require the system turn to be first
///     and singular. Folding + merging is lossless and works on all of them.
///  3. **Capabilities are user-declared, not assumed.** vLLM 400s on `tools` unless the server was
///     started with `--enable-auto-tool-choice`; LM Studio has no `json_object` mode. Tool calling
///     and structured output are therefore switches, defaulting to the combination that works
///     everywhere (tools on, `response_format` off + prompt-injected schema).
///  4. **A long, configurable read timeout, and no redirects.** A 30B model on CPU can spend
///     minutes on one round; and see `LocalHTTP` for why a redirect must never be followed here.
///
/// Nothing else is sent: no `reasoning`, no `cache_control`, no provider-routing block. Only Ollama
/// documents `reasoning_effort`, and vLLM/SGLang would warn or reject the rest.
final class LocalOpenAICompatClient: ResponsesClient, @unchecked Sendable {
    /// Generous by cloud standards, ordinary for a quantized model on consumer hardware.
    static let defaultReadTimeoutSeconds = 180

    /// Base URL as the user typed it; normalized via `LocalEndpoint`.
    private let baseURL: String
    private let model: String
    /// Optional — blank means send no `Authorization` header at all.
    private let apiKey: String?
    private let toolCallingEnabled: Bool
    private let structuredOutput: LocalStructuredOutput
    /// `nil`/0 = omit `max_tokens` and let the server decide.
    private let maxOutputTokens: Int?
    private let readTimeoutSeconds: Int

    /// Accumulated Chat Completions messages for this turn, minus the system block.
    private var messages: [[String: Any]] = []
    /// The merged leading system message (instructions + per-turn context + schema instruction).
    private var systemPrompt: String = ""
    /// Maps generated response IDs → the assistant message (content + tool_calls) so a
    /// continuation turn can re-insert it before the matching tool results.
    private var storedAssistantMessage: [String: [String: Any]] = [:]

    init(
        baseURL: String,
        model: String,
        apiKey: String? = nil,
        toolCallingEnabled: Bool = true,
        structuredOutput: LocalStructuredOutput = .off,
        maxOutputTokens: Int? = nil,
        readTimeoutSeconds: Int = LocalOpenAICompatClient.defaultReadTimeoutSeconds
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.toolCallingEnabled = toolCallingEnabled
        self.structuredOutput = structuredOutput
        self.maxOutputTokens = maxOutputTokens
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        if let problem = LocalEndpoint.validate(baseURL) {
            throw ResponsesError.decoding(LocalEndpoint.message(problem))
        }
        // Not `.missingAPIKey` — the key is optional on this provider, so blaming it would send the
        // user to the one field that is allowed to be empty.
        guard let endpoint = LocalEndpoint.chatCompletionsURL(baseURL) else {
            throw ResponsesError.decoding(LocalEndpoint.message(.malformed))
        }
        guard let req = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            throw ResponsesError.decoding("LocalOpenAICompatClient: invalid request body")
        }

        let body = buildRequestBody(req)
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])

        var headers: [String: String] = [:]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }

        let data = try await LocalHTTP.post(
            url: endpoint, body: bodyData, headers: headers,
            timeout: TimeInterval(readTimeoutSeconds))

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding(
                "The server at \(endpoint.absoluteString) did not return JSON — is it an "
                + "OpenAI-compatible endpoint?")
        }
        return try ingestResponse(root)
    }

    // MARK: - Request assembly (internal for unit tests)

    func buildRequestBody(_ req: [String: Any]) -> [String: Any] {
        let input = req["input"] as? [[String: Any]] ?? []
        let tools = req["tools"] as? [[String: Any]] ?? []
        let previousResponseId = req["previous_response_id"] as? String

        if let previousResponseId {
            appendContinuation(previousId: previousResponseId, input: input)
        } else {
            setupConversation(from: input)
        }
        return buildChatBody(tools: toolCallingEnabled ? convertTools(tools) : [])
    }

    // MARK: - Conversation setup

    /// First turn. Every `system`/`developer` item is merged, in order, into a single leading
    /// system message; `user`/`assistant` items keep their order after it. The schema instruction
    /// joins the system block rather than trailing the conversation (where MiniMax puts it) because
    /// a system turn after a user turn raises in several local chat templates.
    private func setupConversation(from input: [[String: Any]]) {
        messages = []
        storedAssistantMessage = [:]

        var systemParts: [String] = []
        var conversation: [[String: Any]] = []
        for item in input {
            guard let role = item["role"] as? String, item["content"] != nil else { continue }
            if role == "system" || role == "developer" {
                // A system turn is always plain instruction text; flatten any content parts.
                systemParts.append(flattenText(item))
            } else {
                conversation.append(["role": role, "content": chatContent(from: item)])
            }
        }
        // Only the prompt tells an unconstrained local model what shape to answer in. Even with
        // `response_format` on, this stays — it's what the orchestrator's JSON-repair loop leans on
        // when a small model ignores the grammar.
        systemParts.append(CoachResponseSchema.promptInstruction)
        systemPrompt = systemParts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        messages = conversation
    }

    /// Subsequent turns: replay the stored assistant message for [previousId] (Chat Completions
    /// requires the assistant `tool_calls` message to precede the `tool` results answering them),
    /// then append the new tool results / messages. A stray system/developer item here is folded
    /// into the leading system block rather than appended mid-conversation.
    private func appendContinuation(previousId: String, input: [[String: Any]]) {
        if let assistant = storedAssistantMessage[previousId] { messages.append(assistant) }
        for item in input {
            if (item["type"] as? String) == "function_call_output",
               let callId = item["call_id"] as? String,
               let output = item["output"] as? String {
                messages.append(["role": "tool", "tool_call_id": callId, "content": output])
                continue
            }
            guard let role = item["role"] as? String, item["content"] != nil else { continue }
            if role == "system" || role == "developer" {
                systemPrompt = [systemPrompt, flattenText(item)]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            } else {
                messages.append(["role": role, "content": chatContent(from: item)])
            }
        }
    }

    /// All text in a message item, whether `content` is a string or a content-part array.
    private func flattenText(_ item: [String: Any]) -> String {
        if let text = item["content"] as? String { return text }
        guard let parts = item["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Converts a Responses-API message item's `content` into Chat Completions `content`. Text
    /// stays a plain string; images map to `{type:image_url, image_url:{url}}` parts. Local vision
    /// backends take base64 `data:` URLs (Ollama explicitly rejects remote image URLs), which is
    /// exactly what `CoachImagePayload.dataURL` produces.
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

    /// Flat Responses function specs → Chat Completions' nested `{type:function, function:{…}}`.
    /// The hosted `web_search` tool is dropped: no local engine has one. `strict` is dropped too —
    /// it's an OpenAI structured-outputs extension that vLLM/SGLang don't act on and some stricter
    /// proxies reject inside a function spec.
    private func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            let type = tool["type"] as? String
            if type == "web_search" || type == "web_search_preview" { return nil }
            guard type == "function", let name = tool["name"] as? String else { return nil }
            var fn: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String { fn["description"] = desc }
            if let params = tool["parameters"] as? [String: Any] { fn["parameters"] = params }
            return ["type": "function", "function": fn]
        }
    }

    // MARK: - Build request body

    func buildChatBody(tools: [[String: Any]]) -> [String: Any] {
        var allMessages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            allMessages.append(["role": "system", "content": systemPrompt])
        }
        allMessages.append(contentsOf: messages)

        var body: [String: Any] = [
            // llama.cpp ignores `model` unless started with --alias; everyone else requires it.
            // Sending it unconditionally is correct for both.
            "model": model,
            "messages": allMessages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            // Ollama/llama.cpp applies `response_format` as a grammar to the entire assistant
            // generation. When native tools are present that grammar prevents the model from
            // emitting the protocol-level `tool_calls` envelope; small models instead serialize
            // a function-looking object as ordinary content and may falsely claim the write ran.
            // Keep tool rounds unconstrained. If their final prose misses coach_response, the
            // orchestrator's repair turn carries no tools and receives the configured grammar.
        } else if let format = responseFormat() {
            body["response_format"] = format
        }
        if let maxOutputTokens, maxOutputTokens > 0 { body["max_tokens"] = maxOutputTokens }
        return body
    }

    /// The `response_format` block, or nil when the user left structured output off (the default,
    /// and the only setting that works on every backend). `.jsonSchema` uses the nested OpenAI
    /// shape — `{type:"json_schema", json_schema:{name, strict, schema}}` — which vLLM, SGLang,
    /// LM Studio and recent llama.cpp all accept. `.jsonObject` is the older, weaker mode; LM
    /// Studio doesn't implement it, hence the choice.
    func responseFormat() -> [String: Any]? {
        switch structuredOutput {
        case .off:
            return nil
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema:
            return [
                "type": "json_schema",
                "json_schema": [
                    "name": CoachResponseSchema.name,
                    "strict": true,
                    "schema": CoachResponseSchema.jsonSchema,
                ] as [String: Any],
            ]
        }
    }

    // MARK: - Parse Chat Completions response → OpenAIResponse (internal for tests)

    func ingestResponse(_ root: [String: Any]) throws -> OpenAIResponse {
        // Some servers (and most reverse proxies in front of them) report errors in the body on an
        // HTTP 200. `error` may be an object or, on llama.cpp, a bare string.
        if let err = root["error"] as? [String: Any] {
            throw ResponsesError.decoding("Server error: \(err["message"] as? String ?? "\(err)")")
        }
        if let err = root["error"] as? String {
            throw ResponsesError.decoding("Server error: \(err)")
        }

        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ResponsesError.decoding(
                "No `choices` in the response — the server may not be OpenAI-compatible. "
                + "Got: \(String("\(root)".prefix(300)))")
        }

        let responseId = (root["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        var outputItems: [ResponseOutputItem] = []
        var assistantMessage: [String: Any] = ["role": "assistant"]

        // Open reasoning models emit their chain of thought either as an inline `<think>…</think>`
        // block (llama.cpp/Ollama without a reasoning parser) or split into a separate field —
        // `reasoning` on vLLM 0.27+, `reasoning_content` on older builds and SGLang. Neither
        // belongs in the coach_response JSON: the first is stripped, the others aren't read.
        let content = (message["content"] as? String).map(stripThinking)
        if let content, !content.isEmpty {
            outputItems.append(.message(text: content))
            assistantMessage["content"] = content
        } else {
            assistantMessage["content"] = NSNull()
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            var storedCalls: [[String: Any]] = []
            for call in toolCalls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                let callId = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "local_call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
                // `arguments` is a JSON *string* per the spec, but several local tool-call parsers
                // emit a JSON object instead. Re-encode that so the orchestrator's parse succeeds
                // instead of failing the round on a well-formed-but-differently-typed field.
                let args: String
                if let raw = fn["arguments"] as? String {
                    args = raw
                } else if let object = fn["arguments"],
                          let data = try? JSONSerialization.data(withJSONObject: object),
                          let text = String(data: data, encoding: .utf8) {
                    args = text
                } else {
                    args = "{}"
                }
                outputItems.append(.functionCall(
                    ResponseFunctionCall(name: name, callID: callId, arguments: args)))
                storedCalls.append([
                    "id": callId,
                    "type": "function",
                    "function": ["name": name, "arguments": args],
                ])
            }
            if !storedCalls.isEmpty { assistantMessage["tool_calls"] = storedCalls }
        }

        if outputItems.isEmpty {
            // A reasoning model that ran out of budget mid-thought returns null content, no tool
            // calls, and finish_reason "length". Bare "the model returned no output" sends the
            // user looking for the wrong problem — the fix is the Max tokens field.
            if (first["finish_reason"] as? String) == "length" {
                let spentReasoning = message["reasoning"] != nil || message["reasoning_content"] != nil
                throw ResponsesError.decoding(
                    "The model hit its token limit before producing an answer"
                    + (spentReasoning ? " (it spent the budget reasoning)" : "")
                    + ". Raise Max tokens in Settings → AI Coach, or leave it blank.")
            }
            throw ResponsesError.emptyOutput
        }

        storedAssistantMessage[responseId] = assistantMessage
        return OpenAIResponse(id: responseId, outputItems: outputItems, usage: usage(from: root))
    }

    /// Maps the `usage` block when present. Local servers all report the OpenAI split; a server
    /// that omits it leaves usage nil, and the coach shows no token counts rather than zeros.
    private func usage(from root: [String: Any]) -> CoachTokenUsage? {
        guard let usage = root["usage"] as? [String: Any],
              let input = usage["prompt_tokens"] as? Int,
              let output = usage["completion_tokens"] as? Int else { return nil }
        return CoachTokenUsage(inputTokens: input, outputTokens: output)
    }

    /// Removes `<think>…</think>` reasoning blocks. Tolerant at both ends: an unterminated trailing
    /// `<think>` (truncated output) drops its remainder, and a leading unmatched `</think>` drops
    /// everything before it.
    ///
    /// That second case is the common one, not an edge case. R1-style distills served by llama.cpp
    /// and Ollama have the *opening* tag injected into the prompt by the chat template, so the
    /// completion starts mid-thought and the only tag in `content` is a bare closing one. Matching
    /// pairs only, the whole chain of thought reaches `CoachResponseParser`, which then burns the
    /// orchestrator's repair budget — each attempt up to the 180 s read timeout — before the turn
    /// ends in a parse failure.
    func stripThinking(_ text: String) -> String {
        var body = text
        if let firstClose = body.range(of: "</think>") {
            let firstOpen = body.range(of: "<think>")
            if firstOpen == nil || firstClose.lowerBound < firstOpen!.lowerBound {
                body = String(body[firstClose.upperBound...])
            }
        }
        var out = ""
        var scanIndex = body.startIndex
        while let openRange = body.range(of: "<think>", range: scanIndex..<body.endIndex) {
            out += body[scanIndex..<openRange.lowerBound]
            if let closeRange = body.range(of: "</think>", range: openRange.upperBound..<body.endIndex) {
                scanIndex = closeRange.upperBound
            } else {
                scanIndex = body.endIndex   // Unterminated block — drop the rest.
                break
            }
        }
        out += body[scanIndex..<body.endIndex]
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
