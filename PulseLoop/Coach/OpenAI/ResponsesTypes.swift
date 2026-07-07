import Foundation

/// One output item from a Responses API result. We only model what the agent
/// loop needs; everything else collapses to `.other`.
enum ResponseOutputItem: Sendable {
    case message(text: String)
    case functionCall(ResponseFunctionCall)
    case webSearchCall(id: String)
    case other(type: String)
}

struct ResponseFunctionCall: Sendable {
    let name: String
    let callID: String
    let arguments: String
}

/// Parsed, Sendable view of a `POST /v1/responses` result.
struct OpenAIResponse: Sendable {
    let id: String
    let outputItems: [ResponseOutputItem]

    var functionCalls: [ResponseFunctionCall] {
        outputItems.compactMap { if case .functionCall(let fc) = $0 { return fc } else { return nil } }
    }

    var webSearchCallIDs: [String] {
        outputItems.compactMap { if case .webSearchCall(let id) = $0 { return id } else { return nil } }
    }

    /// Concatenated assistant text (the final structured-output JSON lives here).
    var outputText: String {
        outputItems.compactMap { if case .message(let text) = $0 { return text } else { return nil } }
            .joined()
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> OpenAIResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding("response was not a JSON object")
        }
        let id = root["id"] as? String ?? ""
        let rawOutput = root["output"] as? [[String: Any]] ?? []
        var items: [ResponseOutputItem] = []
        for item in rawOutput {
            let type = item["type"] as? String ?? ""
            switch type {
            case "message":
                items.append(.message(text: extractText(item)))
            case "function_call":
                let fc = ResponseFunctionCall(
                    name: item["name"] as? String ?? "",
                    callID: item["call_id"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? "{}"
                )
                items.append(.functionCall(fc))
            case "web_search_call":
                items.append(.webSearchCall(id: item["id"] as? String ?? UUID().uuidString))
            default:
                items.append(.other(type: type))
            }
        }
        return OpenAIResponse(id: id, outputItems: items)
    }

    private static func extractText(_ messageItem: [String: Any]) -> String {
        let content = messageItem["content"] as? [[String: Any]] ?? []
        return content.compactMap { part -> String? in
            let t = part["type"] as? String
            if t == "output_text" || t == "text" { return part["text"] as? String }
            return nil
        }.joined()
    }
}

/// Builds the `[String: Any]` request body for a Responses turn and serializes
/// it. Kept dictionary-based because tool specs and the strict output schema are
/// naturally arbitrary JSON.
enum OpenAIRequestBuilder {
    /// One input message item. The text path keeps `content` a plain String so the
    /// adapter clients' `content as? String` branches are untouched; images are
    /// purely additive — only when `images` is non-empty does `content` become the
    /// Responses-API content-part array (`input_text` + `input_image`).
    static func message(role: String, content: String, images: [CoachImagePayload] = []) -> [String: Any] {
        guard !images.isEmpty else { return ["role": role, "content": content] }
        var parts: [[String: Any]] = [["type": "input_text", "text": content]]
        for img in images {
            parts.append(["type": "input_image", "image_url": img.dataURL])
        }
        return ["role": role, "content": parts]
    }

    /// A function-call result item to feed back into the next turn.
    static func functionCallOutput(callID: String, output: String) -> [String: Any] {
        ["type": "function_call_output", "call_id": callID, "output": output]
    }

    static func body(
        model: String,
        input: [[String: Any]],
        tools: [[String: Any]],
        textFormat: [String: Any]?,
        previousResponseId: String?,
        reasoningEffort: String?
    ) -> [String: Any] {
        var body: [String: Any] = ["model": model, "input": input]
        if !tools.isEmpty { body["tools"] = tools }
        if let textFormat { body["text"] = ["format": textFormat] }
        if let previousResponseId { body["previous_response_id"] = previousResponseId }
        if let reasoningEffort, !reasoningEffort.isEmpty { body["reasoning"] = ["effort": reasoningEffort] }
        return body
    }

    static func data(
        model: String,
        input: [[String: Any]],
        tools: [[String: Any]],
        textFormat: [String: Any]?,
        previousResponseId: String?,
        reasoningEffort: String?
    ) throws -> Data {
        let dict = body(model: model, input: input, tools: tools, textFormat: textFormat,
                        previousResponseId: previousResponseId, reasoningEffort: reasoningEffort)
        return try JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes])
    }
}
