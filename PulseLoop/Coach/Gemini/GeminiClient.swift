import Foundation

/// Adapts the app's `ResponsesClient` protocol to Google Gemini's
/// `generateContent` API. Translates OpenAI Responses-API request bodies into
/// Gemini requests and maps responses back so no other component needs to know
/// which provider is active.
///
/// State across turns: the OpenAI Responses API is stateful (server tracks
/// history via `previous_response_id`). Gemini is stateless (caller sends full
/// history each time). This class accumulates the conversation as Gemini
/// `contents` entries across `send` calls; each instance covers exactly one
/// agent turn (the orchestrator creates a fresh client per turn via the factory).
final class GeminiClient: ResponsesClient, @unchecked Sendable {
    private let apiKey: String
    // The model the orchestrator selected, taken from each request body's `model`
    // field (see `send`); the init value is only a fallback if that's absent.
    private var model: String
    private let session: URLSession
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    // Accumulated Gemini-format conversation contents.
    private var systemText: String = ""
    private var contents: [[String: Any]] = []
    // Maps generated response IDs → Gemini model parts (function calls + text).
    private var storedModelParts: [String: [[String: Any]]] = [:]
    // Maps generated call IDs → function names (Gemini uses name, not call_id).
    private var callIdToName: [String: String] = [:]
    // Web search: the orchestrator requests it via the OpenAI hosted-tool spec.
    // Gemini 2.5 can't combine google_search with functionDeclarations or a JSON
    // responseSchema in one request, so we ground only on a tool-less turn and
    // fire it at most once per agent turn (later repair turns enforce the schema).
    private var webSearchRequested = false
    private var webSearchGrounded = false
    // Sources cited by a google_search turn, queued to prepend to the next user
    // message so the schema turn can fill the response `sources` array.
    private var pendingSourcesNote: String?

    init(apiKey: String, model: String = "gemini-2.5-flash", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        guard !apiKey.isEmpty else { throw ResponsesError.missingAPIKey }

        guard let req = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            throw ResponsesError.decoding("GeminiClient: invalid request body")
        }

        // The orchestrator/services pass the user-selected model in the body
        // (`flags.model`). Honor it so the picker in settings actually takes effect.
        if let requestedModel = req["model"] as? String, !requestedModel.isEmpty {
            model = requestedModel
        }

        let input = req["input"] as? [[String: Any]] ?? []
        let tools = req["tools"] as? [[String: Any]] ?? []
        let textFormat = (req["text"] as? [String: Any])?["format"] as? [String: Any]
        let previousResponseId = req["previous_response_id"] as? String

        if previousResponseId == nil {
            setupConversation(from: input)
        } else {
            appendContinuation(previousId: previousResponseId!, input: input)
        }

        let geminiBody = buildGeminiBody(tools: convertTools(tools), textFormat: textFormat)
        let geminiData = try JSONSerialization.data(withJSONObject: geminiBody)

        let urlStr = "\(baseURL)/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            throw ResponsesError.decoding("GeminiClient: could not build endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = geminiData
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

        return try parseGeminiResponse(data)
    }

    // MARK: - Conversation setup

    /// First turn: separate system/developer messages into systemInstruction and
    /// convert the remaining history into Gemini contents.
    private func setupConversation(from input: [[String: Any]]) {
        contents = []
        callIdToName = [:]
        storedModelParts = [:]

        var systemParts: [String] = []
        var conversationItems: [[String: Any]] = []

        for item in input {
            let role = item["role"] as? String ?? ""
            let content = item["content"] as? String ?? ""
            if role == "system" || role == "developer" {
                if !content.isEmpty { systemParts.append(content) }
            } else {
                conversationItems.append(item)
            }
        }

        systemText = systemParts.joined(separator: "\n\n")

        for item in conversationItems {
            guard let role = item["role"] as? String else { continue }
            let parts = geminiParts(from: item)
            guard !parts.isEmpty else { continue }
            let geminiRole = role == "assistant" ? "model" : "user"
            contents.append(["role": geminiRole, "parts": parts])
        }
    }

    /// Converts a Responses-API message item's `content` into Gemini `parts`. Text
    /// items keep `content` as a String → `[{"text": …}]` (unchanged path). Image
    /// items carry `content` as the OpenAI content-part array (`input_text` +
    /// `input_image`), which we map to `{"text": …}` + `{"inlineData": {mimeType, data}}`.
    private func geminiParts(from item: [String: Any]) -> [[String: Any]] {
        if let text = item["content"] as? String {
            return [["text": text]]
        }
        guard let parts = item["content"] as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "text":
                if let text = part["text"] as? String { out.append(["text": text]) }
            case "input_image":
                if let inline = inlineData(fromImageURL: part["image_url"] as? String) {
                    out.append(["inlineData": inline])
                }
            default:
                break
            }
        }
        return out
    }

    /// Splits an `input_image` `data:<mime>;base64,<data>` URL into Gemini's
    /// `inlineData` object (`mimeType` + bare base64 `data`).
    private func inlineData(fromImageURL url: String?) -> [String: String]? {
        guard let url, url.hasPrefix("data:"),
              let comma = url.firstIndex(of: ","),
              let semicolon = url.firstIndex(of: ";"),
              url.distance(from: url.startIndex, to: semicolon) < url.distance(from: url.startIndex, to: comma)
        else { return nil }
        let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<semicolon])
        let data = String(url[url.index(after: comma)...])
        return ["mimeType": mime, "data": data]
    }

    /// Subsequent turns (tool results or repair messages): append the stored
    /// model response then the new user content.
    private func appendContinuation(previousId: String, input: [[String: Any]]) {
        if let modelParts = storedModelParts[previousId] {
            contents.append(["role": "model", "parts": modelParts])
        }

        // Input items may be tool results (function_call_output) or plain messages.
        var userParts: [[String: Any]] = []
        // Prepend any queued grounding-sources note so it rides with this user turn.
        if let note = pendingSourcesNote {
            userParts.append(["text": note])
            pendingSourcesNote = nil
        }
        for item in input {
            if let toolPart = convertToolResult(item) {
                userParts.append(toolPart)
            } else if let role = item["role"] as? String, item["content"] != nil {
                if role == "assistant" {
                    if !userParts.isEmpty {
                        contents.append(["role": "user", "parts": userParts])
                        userParts = []
                    }
                    // Assistant replays are always text, but route through the same
                    // converter so a String content still yields `[{"text": …}]`.
                    contents.append(["role": "model", "parts": geminiParts(from: item)])
                } else {
                    userParts.append(contentsOf: geminiParts(from: item))
                }
            }
        }
        if !userParts.isEmpty {
            contents.append(["role": "user", "parts": userParts])
        }
    }

    // MARK: - Tool conversion (OpenAI → Gemini)

    /// Converts OpenAI function-tool specs to Gemini `functionDeclarations`. The
    /// OpenAI hosted `web_search` spec has no Gemini function equivalent; instead
    /// it records that grounding is wanted (see `webSearchRequested`) so we can
    /// attach `google_search` on the tool-less final turn.
    private func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        let decls = tools.compactMap { tool -> [String: Any]? in
            let type = tool["type"] as? String
            if type == "web_search" || type == "web_search_preview" {
                webSearchRequested = true
                return nil
            }
            guard type == "function", let name = tool["name"] as? String else { return nil }
            var decl: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String { decl["description"] = desc }
            if let params = tool["parameters"] as? [String: Any] {
                decl["parameters"] = cleanSchema(params)
            }
            return decl
        }
        return decls.isEmpty ? [] : [["functionDeclarations": decls]]
    }

    /// Strips JSON Schema keywords Gemini rejects and rewrites the parts whose
    /// syntax differs from the OpenAPI subset Gemini expects:
    ///   • `additionalProperties` / `$schema` / `strict` — unsupported keywords.
    ///   • union types like `["string", "null"]` → single `type` + `nullable`.
    private func cleanSchema(_ schema: [String: Any]) -> [String: Any] {
        var out = schema
        out.removeValue(forKey: "additionalProperties")
        out.removeValue(forKey: "$schema")
        out.removeValue(forKey: "strict")

        // Gemini uses `nullable: true` rather than JSON Schema union types.
        if let types = out["type"] as? [String] {
            if types.contains("null") { out["nullable"] = true }
            out["type"] = types.first { $0 != "null" } ?? "string"
        }

        if let props = out["properties"] as? [String: Any] {
            out["properties"] = props.mapValues { val -> Any in
                (val as? [String: Any]).map { cleanSchema($0) } ?? val
            }
        }
        if let items = out["items"] as? [String: Any] {
            out["items"] = cleanSchema(items)
        }
        return out
    }

    // MARK: - Tool result conversion

    private func convertToolResult(_ item: [String: Any]) -> [String: Any]? {
        guard (item["type"] as? String) == "function_call_output",
              let callId = item["call_id"] as? String,
              let output = item["output"] as? String else { return nil }
        let name = callIdToName[callId] ?? callId
        let resultData = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) ?? output
        return ["functionResponse": ["name": name, "response": ["result": resultData]]]
    }

    // MARK: - Build Gemini request body

    private func buildGeminiBody(tools: [[String: Any]], textFormat: [String: Any]?) -> [String: Any] {
        var body: [String: Any] = ["contents": contents]

        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }
        if !tools.isEmpty {
            body["tools"] = tools
            // VALIDATED mode validates function calls with constrained decoding —
            // Gemini's equivalent of OpenAI strict mode. Without it Gemini omits
            // required-but-empty fields (e.g. an empty `annotations` array, a
            // `reason` string), which then fail our non-optional arg decoders.
            body["toolConfig"] = ["functionCallingConfig": ["mode": "VALIDATED"]]
        }

        // Web search (Google Search grounding). On Gemini 2.5 google_search can't
        // share a request with functionDeclarations or a JSON responseSchema, so
        // we ground exactly once, on the first tool-less turn: attach google_search
        // and skip the schema. The grounded prose + cited sources land in history;
        // the orchestrator's subsequent tool-less repair turn then enforces the
        // coach_response schema (and can fill the `sources` array from them).
        let groundingTurn = tools.isEmpty && webSearchRequested && !webSearchGrounded
        if groundingTurn {
            body["tools"] = [["google_search": [:]]]
            webSearchGrounded = true
        }

        // Gemini rejects function declarations combined with a JSON response
        // schema, so only constrain output to structured JSON on tool-less turns.
        // The grounding turn also omits the schema (google_search + responseSchema
        // is rejected); the repair turn that follows applies it.
        var genConfig: [String: Any] = [:]
        if tools.isEmpty, !groundingTurn, let fmt = textFormat {
            let fmtType = fmt["type"] as? String ?? ""
            if fmtType == "json_schema" || fmtType == "json_object" {
                genConfig["responseMimeType"] = "application/json"
                if let schema = fmt["schema"] as? [String: Any] {
                    genConfig["responseSchema"] = cleanSchema(schema)
                }
            }
        }
        if !genConfig.isEmpty { body["generationConfig"] = genConfig }

        return body
    }

    // MARK: - Parse Gemini response → OpenAIResponse

    private func parseGeminiResponse(_ data: Data) throws -> OpenAIResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding("GeminiClient: response was not a JSON object")
        }

        guard let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ResponsesError.decoding("GeminiClient: no candidates in response — \(body.prefix(300))")
        }

        let responseId = UUID().uuidString
        var outputItems: [ResponseOutputItem] = []
        var modelParts: [[String: Any]] = []

        for part in parts {
            if let text = part["text"] as? String {
                outputItems.append(.message(text: text))
                modelParts.append(["text": text])
            } else if let fc = part["functionCall"] as? [String: Any],
                      let name = fc["name"] as? String {
                let args = fc["args"] as? [String: Any] ?? [:]
                let argsStr = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let callId = "gemini_call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
                callIdToName[callId] = name
                outputItems.append(.functionCall(ResponseFunctionCall(name: name, callID: callId, arguments: argsStr)))
                modelParts.append(["functionCall": ["name": name, "args": args]])
            }
        }

        // Grounding sources: when google_search ran, Gemini returns the cited
        // pages in groundingMetadata. Queue them so the next (schema) turn can
        // populate the response `sources` array. Queuing (rather than appending to
        // `contents` here) keeps the user/model turn order valid — the note rides
        // with the next user message in appendContinuation.
        let sources = groundingSources(from: first)
        if !sources.isEmpty {
            let json = (try? JSONSerialization.data(withJSONObject: sources))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            pendingSourcesNote = "Web search sources (use these verbatim to fill the "
                + "response `sources` array as title/url/publisher): \(json)"
        }

        if outputItems.isEmpty { throw ResponsesError.emptyOutput }

        storedModelParts[responseId] = modelParts
        return OpenAIResponse(id: responseId, outputItems: outputItems)
    }

    /// Extracts cited pages from a candidate's `groundingMetadata` as
    /// `{title, url, publisher}` dicts matching the coach_response sources schema.
    private func groundingSources(from candidate: [String: Any]) -> [[String: String]] {
        guard let meta = candidate["groundingMetadata"] as? [String: Any],
              let chunks = meta["groundingChunks"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var sources: [[String: String]] = []
        for chunk in chunks {
            guard let web = chunk["web"] as? [String: Any],
                  let uri = web["uri"] as? String, !uri.isEmpty,
                  seen.insert(uri).inserted else { continue }
            let title = (web["title"] as? String) ?? uri
            sources.append(["title": title, "url": uri, "publisher": title])
        }
        return sources
    }
}
