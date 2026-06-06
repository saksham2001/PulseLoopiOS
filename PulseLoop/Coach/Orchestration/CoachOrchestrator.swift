import Foundation

/// The coach agent loop: context → model → tools → structured final. Ports
/// `_run_openai` from the web orchestrator, with the same caps, per-tool
/// arg-retry guard, JSON repair, and graceful fallbacks. Runs on the main actor
/// (tools read SwiftData); the network awaits hop off-main inside the client.
@MainActor
struct CoachOrchestrator {
    let client: ResponsesClient
    let registry: ToolRegistry
    let flags: CoachFeatureFlags
    let toolContext: ToolExecutionContext

    private let maxFinalAttempts = 3
    private let maxToolArgRetries = 2

    struct TurnResult {
        let assistant: CoachResponse
        let trace: [CoachToolCallTrace]
        var pendingActions: [PendingAction] = []
    }

    struct PriorMessage { let role: String; let text: String }

    func runTurn(
        userText: String,
        packet: CoachContextPacket,
        recentMessages: [PriorMessage],
        onTrace: @escaping (CoachTraceEvent) -> Void = { _ in }
    ) async -> TurnResult {
        guard flags.coachEnabled else {
            return TurnResult(assistant: CoachFallbacks.scripted(packet: packet), trace: [])
        }
        do {
            return try await runOpenAI(userText: userText, packet: packet, recentMessages: recentMessages, onTrace: onTrace)
        } catch {
            onTrace(CoachTraceEvent(label: "Something went wrong", status: .failedTool))
            return TurnResult(assistant: CoachFallbacks.fallback(), trace: [])
        }
    }

    private func runOpenAI(
        userText: String,
        packet: CoachContextPacket,
        recentMessages: [PriorMessage],
        onTrace: @escaping (CoachTraceEvent) -> Void
    ) async throws -> TurnResult {
        let toolSpecs = registry.toolSpecs
        let textFormat = CoachResponseSchema.textFormat

        // Initial input: system + developer + recent turns + the new user message.
        var input: [[String: Any]] = [
            OpenAIRequestBuilder.message(role: "system", content: CoachPromptBuilder.systemPrompt),
            OpenAIRequestBuilder.message(role: "developer", content: CoachPromptBuilder.developerMessage(packet: packet)),
        ]
        for m in recentMessages {
            input.append(OpenAIRequestBuilder.message(role: m.role == "user" ? "user" : "assistant", content: m.text))
        }
        input.append(OpenAIRequestBuilder.message(role: "user", content: userText))

        onTrace(CoachTraceEvent(label: "Thinking about your question…", status: .thinking))

        var response = try await send(input: input, tools: toolSpecs, textFormat: textFormat, previousResponseId: nil)
        noteWebSearch(response, onTrace: onTrace)

        var trace: [CoachToolCallTrace] = []
        var toolCalls = 0
        var rounds = 0
        var argFailures: [String: Int] = [:]

        while rounds < flags.maxRounds {
            let functionCalls = response.functionCalls
            if functionCalls.isEmpty { break }

            var outputs: [[String: Any]] = []
            for fc in functionCalls {
                if toolCalls >= flags.maxToolCalls {
                    outputs.append(OpenAIRequestBuilder.functionCallOutput(
                        callID: fc.callID, output: "{\"error\":\"tool-call budget exceeded\"}"))
                    continue
                }
                if (argFailures[fc.name] ?? 0) > maxToolArgRetries {
                    outputs.append(OpenAIRequestBuilder.functionCallOutput(
                        callID: fc.callID, output: "{\"error\":\"stop calling \(fc.name); arguments kept failing\"}"))
                    continue
                }
                toolCalls += 1
                let label = registry.tool(named: fc.name)?.publicLabel ?? "Working"
                onTrace(CoachTraceEvent(label: label, status: .runningTool, toolName: fc.name))

                let startedAt = Date()
                let result = await ToolCallExecutor.execute(fc, registry: registry, context: toolContext)
                let finishedAt = Date()

                if result.isError, result.jsonString.contains("invalid arguments") {
                    argFailures[fc.name, default: 0] += 1
                }
                onTrace(CoachTraceEvent(
                    label: label, status: result.isError ? .failedTool : .completedTool, toolName: fc.name))
                trace.append(CoachToolCallTrace(
                    toolName: fc.name, label: label,
                    status: result.isError ? "error" : "success",
                    argsRedacted: ToolCallExecutor.redactArgs(fc.arguments),
                    resultSummary: result.summary,
                    startedAt: startedAt, finishedAt: finishedAt))
                outputs.append(OpenAIRequestBuilder.functionCallOutput(callID: fc.callID, output: result.jsonString))
            }

            rounds += 1
            onTrace(CoachTraceEvent(label: "Putting it together…", status: .writingAnswer))
            response = try await send(input: outputs, tools: toolSpecs, textFormat: textFormat, previousResponseId: response.id)
            noteWebSearch(response, onTrace: onTrace)
        }

        let assistant = try await parseFinal(response, textFormat: textFormat)
        onTrace(CoachTraceEvent(label: "", status: .done))
        return TurnResult(assistant: assistant, trace: trace, pendingActions: toolContext.pendingActions)
    }

    // MARK: - Final parse + repair

    private func parseFinal(_ response: OpenAIResponse, textFormat: [String: Any]) async throws -> CoachResponse {
        var current = response
        var attempts = 1
        while true {
            if let parsed = CoachResponseParser.parse(current.outputText) { return parsed }
            attempts += 1
            if attempts > maxFinalAttempts { return CoachFallbacks.fallback() }
            let repair = OpenAIRequestBuilder.message(
                role: "user",
                content: "Your previous output did not match the required coach_response JSON schema. Return only valid JSON for that schema now.")
            current = try await send(input: [repair], tools: [], textFormat: textFormat, previousResponseId: current.id)
        }
    }

    // MARK: - Helpers

    private func send(
        input: [[String: Any]], tools: [[String: Any]], textFormat: [String: Any], previousResponseId: String?
    ) async throws -> OpenAIResponse {
        let body = try OpenAIRequestBuilder.data(
            model: flags.model, input: input, tools: tools, textFormat: textFormat,
            previousResponseId: previousResponseId, reasoningEffort: flags.settings.reasoningEffort)
        return try await client.send(requestBody: body)
    }

    private func noteWebSearch(_ response: OpenAIResponse, onTrace: (CoachTraceEvent) -> Void) {
        if !response.webSearchCallIDs.isEmpty {
            onTrace(CoachTraceEvent(label: "Searching reliable sources", status: .completedTool, toolName: "web_search"))
        }
    }
}
