import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Adapts the app's `ResponsesClient` protocol to Apple's on-device
/// FoundationModels (`LanguageModelSession`). Everything runs locally: no API
/// key, no network, fully private.
///
/// v1 is **tool-less** — it ignores the OpenAI function / `web_search` tool
/// specs in the request body and does one-shot generation over the pre-built
/// context packet. That covers summaries, daily check-ins and plain chat;
/// chart/action/memory tools stay disabled on-device. When the request carries
/// a strict JSON schema (`text.format`), it uses FoundationModels guided
/// generation to constrain the output, falling back to schema-in-prompt text if
/// guided generation can't be built for that schema (the orchestrator's
/// `JSONRepair` then recovers the object).
///
/// **Text-only:** the shipping FoundationModels SDK has no image-input API
/// (`PromptBuilder` accepts only text), so image attachments aren't supported
/// on-device. The Settings UI hides the image-input option when this provider is
/// selected, so image turns never reach this client.
///
/// Like `GeminiClient`, one instance covers a single agent turn and accumulates
/// the conversation across `send` calls so repair turns keep prior context.
final class AppleFoundationModelsClient: ResponsesClient, @unchecked Sendable {
    /// Flattened system + developer text → session instructions.
    private var systemText: String = ""
    /// Ordered conversation turns (role: "user" | "assistant").
    private var turns: [(role: String, text: String)] = []
    /// responseId → assistant text, so a continuation turn can replay it.
    private var storedAssistant: [String: String] = [:]

    /// On-device context window is small; keep the assembled prompt within a
    /// conservative character budget (~roughly 3–4k tokens) so we degrade to a
    /// shorter answer rather than overflowing the model.
    private let promptCharBudget = 12_000

    init() {}

    func send(requestBody: Data) async throws -> OpenAIResponse {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await generate(requestBody: requestBody)
        } else {
            throw ResponsesError.http(status: 503, body: "On-device AI requires iOS 26 or later.")
        }
        #else
        throw ResponsesError.http(status: 503, body: "On-device AI is unavailable in this build.")
        #endif
    }

    // MARK: - Request-body parsing (shared, framework-independent)

    /// Splits the OpenAI-shaped body into instructions, the running transcript,
    /// and the optional strict output schema. Mirrors `GeminiClient`'s setup so
    /// behavior matches across providers.
    private func ingest(_ requestBody: Data) throws -> (schema: [String: Any]?, schemaName: String) {
        guard let req = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            throw ResponsesError.decoding("AppleFoundationModelsClient: invalid request body")
        }
        let input = req["input"] as? [[String: Any]] ?? []
        let previousResponseId = req["previous_response_id"] as? String

        if previousResponseId == nil {
            setupConversation(from: input)
        } else {
            appendContinuation(previousId: previousResponseId!, input: input)
        }

        let format = (req["text"] as? [String: Any])?["format"] as? [String: Any]
        let schema = format?["schema"] as? [String: Any]
        let schemaName = (format?["name"] as? String) ?? "Response"
        return (schema, schemaName)
    }

    private func setupConversation(from input: [[String: Any]]) {
        turns = []
        var systemParts: [String] = []
        for item in input {
            let role = item["role"] as? String ?? ""
            let content = text(from: item)
            if role == "system" || role == "developer" {
                if !content.isEmpty { systemParts.append(content) }
            } else if !content.isEmpty {
                turns.append((role: role == "assistant" ? "assistant" : "user", text: content))
            }
        }
        systemText = systemParts.joined(separator: "\n\n")
    }

    private func appendContinuation(previousId: String, input: [[String: Any]]) {
        if let assistant = storedAssistant[previousId] {
            turns.append((role: "assistant", text: assistant))
        }
        for item in input {
            // Tool results can't be produced on-device (v1 is tool-less), but a
            // repair/continuation turn still arrives as a plain message — fold it
            // in as a user turn so context is preserved.
            let content = text(from: item)
            if let role = item["role"] as? String, !content.isEmpty {
                turns.append((role: role == "assistant" ? "assistant" : "user", text: content))
            } else if (item["type"] as? String) == "function_call_output",
                      let output = item["output"] as? String, !output.isEmpty {
                turns.append((role: "user", text: "Tool result: \(output)"))
            }
        }
    }

    /// Pulls the text out of an input item. Text turns carry `content` as a plain
    /// `String`; a multimodal item (which shouldn't reach this client — image
    /// input is hidden on-device) carries the content-part array, from which we
    /// keep only the `input_text`/`text` parts and drop images.
    private func text(from item: [String: Any]) -> String {
        if let content = item["content"] as? String { return content }
        guard let parts = item["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "input_text", "text": return part["text"] as? String
            default: return nil
            }
        }.joined(separator: "\n")
    }

    /// Renders the running transcript into a single prompt string, trimmed to the
    /// on-device character budget (oldest turns dropped first).
    private func buildPrompt() -> String {
        var lines: [String] = []
        for turn in turns {
            let label = turn.role == "assistant" ? "Assistant" : "User"
            lines.append("\(label): \(turn.text)")
        }
        var prompt = lines.joined(separator: "\n\n")
        if prompt.count > promptCharBudget {
            prompt = String(prompt.suffix(promptCharBudget))
        }
        return prompt
    }

    #if canImport(FoundationModels)
    // MARK: - Generation

    @available(iOS 26.0, *)
    private func generate(requestBody: Data) async throws -> OpenAIResponse {
        guard SystemLanguageModel.default.isAvailable else {
            throw ResponsesError.http(status: 503, body: AppleOnDeviceAvailability.current.statusMessage)
        }

        let (schema, schemaName) = try ingest(requestBody)
        let prompt = buildPrompt()
        guard !prompt.isEmpty else { throw ResponsesError.emptyOutput }

        let instructions = systemText.isEmpty
            ? "You are a concise, supportive personal health coach."
            : systemText
        let session = LanguageModelSession(instructions: instructions)

        let text: String
        if let schema, let generated = try? await respondGuided(session: session, prompt: prompt, schema: schema, name: schemaName) {
            text = generated
        } else if let schema {
            // Guided generation unavailable for this schema — ask for raw JSON and
            // let the orchestrator's JSONRepair recover it.
            let directive = "\n\nRespond with a single JSON object only — no prose, no code fences."
            text = try await respondText(session: session, prompt: prompt + jsonHint(schema) + directive)
        } else {
            text = try await respondText(session: session, prompt: prompt)
        }

        let responseId = UUID().uuidString
        storedAssistant[responseId] = text
        return OpenAIResponse(id: responseId, outputItems: [.message(text: text)])
    }

    @available(iOS 26.0, *)
    private func respondText(session: LanguageModelSession, prompt: String) async throws -> String {
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw ResponsesError.transport(error)
        }
    }

    /// Constrained decoding against a runtime-built schema. Returns the generated
    /// content as a JSON string the existing decoders understand. Returns `nil`
    /// (caller falls back) if the schema can't be translated.
    @available(iOS 26.0, *)
    private func respondGuided(session: LanguageModelSession, prompt: String, schema: [String: Any], name: String) async throws -> String? {
        guard let dynamic = dynamicSchema(from: schema, name: name) else { return nil }
        let generationSchema = try GenerationSchema(root: dynamic, dependencies: [])
        let response = try await session.respond(to: prompt, schema: generationSchema)
        return response.content.jsonString
    }

    /// Recursively translates the strict JSON Schema the orchestrator emits into
    /// a FoundationModels `DynamicGenerationSchema`. Supports the subset the coach
    /// uses (objects, arrays, strings + enums, numbers, booleans).
    @available(iOS 26.0, *)
    private func dynamicSchema(from schema: [String: Any], name: String) -> DynamicGenerationSchema? {
        let type = schema["type"] as? String
        switch type {
        case "object":
            let props = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            var properties: [DynamicGenerationSchema.Property] = []
            for (key, raw) in props {
                guard let sub = raw as? [String: Any],
                      let child = dynamicSchema(from: sub, name: "\(name)_\(key)") else { continue }
                properties.append(DynamicGenerationSchema.Property(
                    name: key,
                    description: sub["description"] as? String,
                    schema: child,
                    isOptional: !required.contains(key)
                ))
            }
            return DynamicGenerationSchema(name: name, description: schema["description"] as? String, properties: properties)
        case "array":
            guard let items = schema["items"] as? [String: Any],
                  let element = dynamicSchema(from: items, name: "\(name)_item") else { return nil }
            return DynamicGenerationSchema(arrayOf: element)
        case "string":
            if let choices = schema["enum"] as? [String], !choices.isEmpty {
                return DynamicGenerationSchema(name: name, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            // Union types like ["string", "null"] collapse to the first concrete
            // type; anything unrecognized becomes a free string.
            if let types = schema["type"] as? [String],
               let concrete = types.first(where: { $0 != "null" }) {
                return dynamicSchema(from: schema.merging(["type": concrete]) { _, new in new }, name: name)
            }
            return DynamicGenerationSchema(type: String.self)
        }
    }
    #endif

    /// A compact textual hint describing the desired JSON shape, used only on the
    /// non-guided fallback path.
    private func jsonHint(_ schema: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return "\n\nMatch this JSON schema exactly:\n\(str)"
    }
}
