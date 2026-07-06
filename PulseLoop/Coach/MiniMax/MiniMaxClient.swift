import Foundation

/// Adapts the app's `ResponsesClient` protocol to MiniMax's OpenAI-compatible
/// **Chat Completions** API (`POST /v1/chat/completions`). MiniMax speaks the
/// OpenAI Chat Completions shape (Bearer auth, nested `tools`, `tool_calls`), so
/// this is a translating adapter just like `OpenRouterClient` / `GeminiClient` —
/// the rest of the coach is unchanged.
///
/// Deliberately simpler than `OpenRouterClient`: MiniMax's compat endpoint has no
/// hosted web search, no provider-routing block, and no `:online` suffix; it also
/// doesn't document `response_format`, Anthropic `cache_control`, or the OpenAI
/// `reasoning` object — so none of those are sent. The coach's output shape is
/// enforced by the injected `promptInstruction` system message plus the
/// orchestrator's JSON-repair loop, exactly as in the OpenRouter fallback path.
///
/// State across turns: the OpenAI Responses API is stateful; Chat Completions is
/// stateless. This class accumulates the conversation as Chat Completions
/// `messages` across `send` calls; the orchestrator creates a fresh client per
/// agent turn via the factory.
final class MiniMaxClient: ResponsesClient, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    // Global (international) host. China-region accounts use `api.minimaxi.com`
    // instead — swap the host here if the key belongs to the CN platform.
    private let endpoint = URL(string: "https://api.minimax.io/v1/chat/completions")!

    // Accumulated Chat Completions messages for this turn.
    private var messages: [[String: Any]] = []
    // Maps generated response IDs → the assistant message dict (content + tool_calls)
    // so a continuation turn can re-insert it before the matching tool results.
    private var storedAssistantMessage: [String: [String: Any]] = [:]

    init(
        apiKey: String,
        model: String = MiniMaxModel.default.rawValue,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        guard !apiKey.isEmpty else { throw ResponsesError.missingAPIKey }

        guard let req = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            throw ResponsesError.decoding("MiniMaxClient: invalid request body")
        }

        let input = req["input"] as? [[String: Any]] ?? []
        let tools = req["tools"] as? [[String: Any]] ?? []
        let previousResponseId = req["previous_response_id"] as? String

        if previousResponseId == nil {
            setupConversation(from: input)
        } else {
            appendContinuation(previousId: previousResponseId!, input: input)
        }

        let body = buildChatBody(tools: convertTools(tools))
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        // MiniMax's compat endpoint isn't sent an enforced `response_format`, so the
        // model isn't told the required output shape out-of-band. Inject the field
        // spec as a system message so it can produce valid coach_response JSON from
        // the prompt alone (the orchestrator's JSON-repair loop is the backstop).
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
    /// `content`. Text items keep `content` a plain String. Image items carry the
    /// OpenAI content-part array (`input_text` + `input_image`), which we map to
    /// Chat Completions parts (`{type:text}` + `{type:image_url, image_url:{url}}`).
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
    /// tool has no MiniMax equivalent (MiniMax's compat endpoint offers no hosted
    /// search), so it's dropped. The Settings UI already hides the web-search
    /// toggle for MiniMax; dropping it here is a defensive backstop.
    private func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            let type = tool["type"] as? String
            if type == "web_search" || type == "web_search_preview" { return nil }
            guard type == "function", let name = tool["name"] as? String else { return nil }
            var fn: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String { fn["description"] = desc }
            if let params = tool["parameters"] as? [String: Any] { fn["parameters"] = params }
            if let strict = tool["strict"] as? Bool { fn["strict"] = strict }
            return ["type": "function", "function": fn]
        }
    }

    // MARK: - Build request body

    private func buildChatBody(tools: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages]
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    // MARK: - Parse Chat Completions response → OpenAIResponse

    private func parseChatResponse(_ data: Data) throws -> OpenAIResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding("MiniMaxClient: response was not a JSON object")
        }

        // MiniMax can surface an error object (and sometimes a base_resp status)
        // even on an HTTP 200.
        if let err = root["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "unknown error"
            throw ResponsesError.decoding("MiniMax error: \(msg)")
        }
        if let base = root["base_resp"] as? [String: Any],
           let statusCode = base["status_code"] as? Int, statusCode != 0 {
            let msg = base["status_msg"] as? String ?? "unknown error"
            throw ResponsesError.decoding("MiniMax error (\(statusCode)): \(msg)")
        }

        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ResponsesError.decoding("MiniMaxClient: no choices in response — \(body.prefix(300))")
        }

        let responseId = (root["id"] as? String).map { $0.isEmpty ? UUID().uuidString : $0 } ?? UUID().uuidString
        var outputItems: [ResponseOutputItem] = []
        // Persist the raw assistant message so a continuation turn can replay it.
        var assistantMessage: [String: Any] = ["role": "assistant"]

        if let rawContent = message["content"] as? String {
            // M-series models emit reasoning inline as `<think>…</think>` blocks by
            // default; strip them so the coach_response JSON parses cleanly.
            let content = stripThinking(rawContent)
            if !content.isEmpty {
                outputItems.append(.message(text: content))
                assistantMessage["content"] = content
            } else {
                assistantMessage["content"] = NSNull()
            }
        } else {
            // Chat Completions allows null content when tool_calls are present.
            assistantMessage["content"] = NSNull()
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            var storedCalls: [[String: Any]] = []
            for call in toolCalls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                // Reuse MiniMax's own tool_call id as the orchestrator's call_id so
                // the tool result message can reference it on the next turn.
                let callId = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "mm_call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
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

    /// Removes `<think>…</think>` reasoning blocks (and any leading whitespace they
    /// leave behind) from assistant content. Tolerant of an unterminated trailing
    /// `<think>` (truncated output).
    private func stripThinking(_ text: String) -> String {
        var out = ""
        var scanIndex = text.startIndex
        while let openRange = text.range(of: "<think>", range: scanIndex..<text.endIndex) {
            out += text[scanIndex..<openRange.lowerBound]
            if let closeRange = text.range(of: "</think>", range: openRange.upperBound..<text.endIndex) {
                scanIndex = closeRange.upperBound
            } else {
                // Unterminated block — drop the rest.
                scanIndex = text.endIndex
                break
            }
        }
        out += text[scanIndex..<text.endIndex]
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
