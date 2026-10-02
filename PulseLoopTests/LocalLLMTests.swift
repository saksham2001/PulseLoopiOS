import XCTest
@testable import PulseLoop

/// The local / self-hosted coach provider: URL handling, the model listing, the Responses→Chat
/// translation, and the rules that decide when a probe may overwrite a setting the user chose.
///
/// Everything here is pure — no server is contacted. The parts that genuinely need one (a real
/// `/v1/models`, a real capability probe against a running engine) are runtime verification, not
/// unit tests.
final class LocalEndpointTests: XCTestCase {

    func testNormalizesBareHostAndPortToHTTP() {
        XCTAssertEqual(LocalEndpoint.normalize("192.168.1.50:11434"), "http://192.168.1.50:11434")
        XCTAssertEqual(LocalEndpoint.chatCompletionsURL("192.168.1.50:11434")?.absoluteString,
                       "http://192.168.1.50:11434/v1/chat/completions")
    }

    func testStripsTrailingSlashV1AndAPastedFullEndpoint() {
        // All four spellings a user might paste must land on the same base.
        for input in [
            "http://localhost:11434",
            "http://localhost:11434/",
            "http://localhost:11434/v1",
            "http://localhost:11434/v1/chat/completions",
        ] {
            XCTAssertEqual(LocalEndpoint.normalize(input), "http://localhost:11434", input)
        }
    }

    func testKeepsAReverseProxyPathPrefix() {
        XCTAssertEqual(LocalEndpoint.normalize("https://box.example.com/llm/v1"),
                       "https://box.example.com/llm")
        XCTAssertEqual(LocalEndpoint.modelsURL("https://box.example.com/llm/v1")?.absoluteString,
                       "https://box.example.com/llm/v1/models")
    }

    func testAcceptsCleartextOnlyForPrivateHosts() {
        for host in [
            "http://localhost:11434", "http://127.0.0.1:8080", "http://192.168.1.50:11434",
            "http://10.1.2.3:8000", "http://172.16.0.9:30000", "http://100.64.1.2:11434",
            "http://mac-studio.local:1234", "http://[::1]:8080",
            // Name forms that only resolve on a local network. Rejecting these told the user their
            // server had to be on their LAN, which is exactly where it was.
            "http://nas:11434", "http://ollama.lan:8080", "http://box.tail1234.ts.net:11434",
            "http://pi.home:8000", "http://llm.internal:1234", "http://srv.home.arpa:11434",
        ] {
            XCTAssertNil(LocalEndpoint.validate(host), host)
        }
        for host in ["http://example.com:11434", "http://8.8.8.8:8080", "http://172.32.0.1:80"] {
            XCTAssertEqual(LocalEndpoint.validate(host), .publicCleartext, host)
        }
    }

    func testAPublicDottedHostnameIsStillRejectedOverCleartext() {
        // The single-label allowance must not leak into ordinary registered domains.
        for host in ["example.com", "llm.example.com", "ollama.io", "notlocal.localdomain"] {
            XCTAssertFalse(LocalEndpoint.isPrivateHost(host), host)
        }
    }

    func testHTTPSIsUnrestrictedAndOtherSchemesRejected() {
        XCTAssertNil(LocalEndpoint.validate("https://llm.example.com"))
        XCTAssertEqual(LocalEndpoint.validate("ftp://box/llm"), .unsupportedScheme)
    }

    func testBlankAndMalformedAreDistinguished() {
        XCTAssertEqual(LocalEndpoint.validate("   "), .blank)
        XCTAssertEqual(LocalEndpoint.validate("http://"), .malformed)
    }

    func test172PrivateRangeBoundaries() {
        XCTAssertTrue(LocalEndpoint.isPrivateHost("172.16.0.1"))
        XCTAssertTrue(LocalEndpoint.isPrivateHost("172.31.255.254"))
        XCTAssertFalse(LocalEndpoint.isPrivateHost("172.15.0.1"))
        XCTAssertFalse(LocalEndpoint.isPrivateHost("172.32.0.1"))
    }
}

final class LocalModelCatalogTests: XCTestCase {

    private func data(_ json: String) -> Data { json.data(using: .utf8)! }

    func testParsesTheOpenAIListEnvelope() throws {
        let entries = try LocalModelCatalog.parseEntries(data("""
        {"object":"list","data":[{"id":"qwen3:8b"},{"id":"llama3.1:70b"}]}
        """))
        XCTAssertEqual(entries.map(\.id), ["llama3.1:70b", "qwen3:8b"])   // sorted
    }

    func testFallsBackToABareArrayAndDeduplicates() throws {
        let entries = try LocalModelCatalog.parseEntries(data("""
        ["a","b","a"]
        """))
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
    }

    func testReadsTheContextWindowUnderEachEnginesOwnName() throws {
        // Every engine spells it differently and none of them is the OpenAI spec.
        let entries = try LocalModelCatalog.parseEntries(data("""
        {"data":[
          {"id":"vllm","max_model_len":32768},
          {"id":"llamacpp","n_ctx":8192,"n_ctx_train":131072},
          {"id":"lmstudio","loaded_context_length":4096,"max_context_length":65536}
        ]}
        """))
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.contextWindow) })
        XCTAssertEqual(byID["vllm"], 32768)
        XCTAssertEqual(byID["llamacpp"], 8192)      // as served, not the trained ceiling
        XCTAssertEqual(byID["lmstudio"], 4096)      // actually loaded, not the model ceiling
    }

    func testAMissingDataArrayIsAnError() {
        XCTAssertThrowsError(try LocalModelCatalog.parseEntries(data(#"{"object":"list"}"#)))
    }
}

final class LocalCapabilityProbeTests: XCTestCase {

    private func report(
        tools: LocalCapabilityProbe.Support = .unknown,
        schema: LocalCapabilityProbe.Support = .unknown,
        object: LocalCapabilityProbe.Support = .unknown,
        contextWindow: Int? = nil
    ) -> LocalCapabilityProbe.Report {
        LocalCapabilityProbe.Report(
            engine: .vllm, version: "0.27.1", models: ["qwen3-8b"], suggestedModel: "qwen3-8b",
            toolCalling: tools, jsonSchema: schema, jsonObject: object, contextWindow: contextWindow)
    }

    // MARK: Model choice

    func testASoleServedModelIsChosenAutomatically() {
        XCTAssertEqual(LocalCapabilityProbe.pickModel(["only"], currentModel: ""), "only")
    }

    func testAnExistingChoiceIsKeptWhenTheServerStillListsIt() {
        XCTAssertEqual(LocalCapabilityProbe.pickModel(["a", "b"], currentModel: "b"), "b")
    }

    func testSeveralModelsAndNoValidCurrentPickLeavesTheChoiceToTheUser() {
        // Guessing would silently move a working setup onto a different model.
        XCTAssertEqual(LocalCapabilityProbe.pickModel(["a", "b"], currentModel: "gone"), "")
        XCTAssertEqual(LocalCapabilityProbe.pickModel([], currentModel: "x"), "")
    }

    // MARK: Verdicts

    func testToolCallingTurnsOffOnlyOnAnExplicitRefusal() {
        XCTAssertTrue(report(tools: .unknown).suggestedToolCalling)
        XCTAssertTrue(report(tools: .yes).suggestedToolCalling)
        XCTAssertFalse(report(tools: .no).suggestedToolCalling)
    }

    func testTheStrongestAcceptedResponseFormatWins() {
        XCTAssertEqual(report(schema: .yes).suggestedStructuredOutput, .jsonSchema)
        XCTAssertEqual(report(schema: .no, object: .yes).suggestedStructuredOutput, .jsonObject)
        XCTAssertEqual(report(schema: .no, object: .no).suggestedStructuredOutput, .off)
    }

    // MARK: Whether a suggestion may overwrite a hand-set value

    func testAnUnrunProbeIsNotConclusiveSoDetectLeavesTheSettingAlone() {
        // The state after a blank model pick or a failed baseline request. `suggestedToolCalling`
        // is still true here — that default is for a first-time setup, not for a re-detect over a
        // user who deliberately turned tools off for a vLLM without --enable-auto-tool-choice.
        let r = report()
        XCTAssertTrue(r.suggestedToolCalling)
        XCTAssertFalse(r.toolCallingConclusive)
        XCTAssertEqual(r.suggestedStructuredOutput, .off)
        XCTAssertFalse(r.structuredOutputConclusive)
    }

    func testARefusalIsConclusive() {
        let r = report(tools: .no, schema: .no, object: .no)
        XCTAssertTrue(r.toolCallingConclusive)
        XCTAssertTrue(r.structuredOutputConclusive)
    }

    func testAStrictSchemaYesIsConclusiveEvenThoughJSONModeGoesUntested() {
        let r = report(schema: .yes)
        XCTAssertTrue(r.structuredOutputConclusive)
        XCTAssertEqual(r.suggestedStructuredOutput, .jsonSchema)
    }

    // MARK: Max tokens

    func testAContextWindowTheServerNeverReportedSuggestsNothing() {
        // 0 means "not detected", which must not clear a Max tokens value the user typed.
        XCTAssertEqual(report().suggestedMaxTokens, 0)
    }

    func testMaxTokensIsTheContextMinusAPromptReserveCappedAtTheCeiling() {
        // A context window is not an output budget: `prompt + max_tokens > context` is rejected.
        let modest = report(contextWindow: 16384)
        XCTAssertEqual(modest.suggestedMaxTokens,
                       16384 - LocalCapabilityProbe.promptReserveTokens)
        let huge = report(contextWindow: 262144)
        XCTAssertEqual(huge.suggestedMaxTokens, LocalCapabilityProbe.maxSuggestedTokens)
    }

    func testAContextTooSmallForThePromptSuggestsNothingAndSaysSo() {
        // Ollama ships a 2048-token num_ctx default, smaller than the coach's own prompt.
        let tiny = report(contextWindow: 2048)
        XCTAssertEqual(tiny.suggestedMaxTokens, 0)
        XCTAssertTrue(tiny.contextTooSmall)
    }

    func testTheSummaryNamesTheEngineModelAndBothCapabilities() {
        let line = report(tools: .yes, schema: .yes, contextWindow: 32768).summary
        XCTAssertTrue(line.contains("vLLM"))
        XCTAssertTrue(line.contains("qwen3-8b"))
        XCTAssertTrue(line.contains("tools yes"))
        XCTAssertTrue(line.contains("strict schema"))
        XCTAssertTrue(line.contains("32k ctx"))
    }

    func testTheSummarySaysUnknownRatherThanImplyingANegative() {
        XCTAssertTrue(report().summary.contains("tools unknown"))
    }
}

final class LocalOpenAICompatClientTests: XCTestCase {

    private func client(
        toolCalling: Bool = true,
        structured: LocalStructuredOutput = .off,
        maxTokens: Int? = nil
    ) -> LocalOpenAICompatClient {
        LocalOpenAICompatClient(
            baseURL: "http://localhost:11434", model: "qwen3:8b",
            toolCallingEnabled: toolCalling, structuredOutput: structured,
            maxOutputTokens: maxTokens)
    }

    private func request(
        input: [[String: Any]], tools: [[String: Any]] = [], previousResponseId: String? = nil
    ) -> [String: Any] {
        var req: [String: Any] = ["input": input, "tools": tools]
        if let previousResponseId { req["previous_response_id"] = previousResponseId }
        return req
    }

    private func messages(_ body: [String: Any]) -> [[String: Any]] {
        body["messages"] as? [[String: Any]] ?? []
    }

    // MARK: Request shape

    func testNoMessageEverCarriesTheDeveloperRole() {
        // SGLang validates roles against a pydantic Literal and 400s on anything outside it.
        let body = client().buildRequestBody(request(input: [
            ["role": "developer", "content": "instructions"],
            ["role": "user", "content": "hi"],
        ]))
        XCTAssertFalse(messages(body).contains { ($0["role"] as? String) == "developer" })
    }

    func testSystemAndDeveloperTurnsMergeIntoOneLeadingSystemMessage() {
        // Many local chat templates require the system turn to be first and singular.
        let body = client().buildRequestBody(request(input: [
            ["role": "system", "content": "A"],
            ["role": "developer", "content": "B"],
            ["role": "user", "content": "hi"],
        ]))
        let msgs = messages(body)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        let system = msgs[0]["content"] as? String ?? ""
        XCTAssertTrue(system.contains("A"))
        XCTAssertTrue(system.contains("B"))
        // The schema instruction rides in the system block, not after the user turn.
        XCTAssertTrue(system.contains("coach_response"))
        XCTAssertEqual(msgs[1]["role"] as? String, "user")
    }

    func testToolsAreConvertedToTheNestedChatShapeWithoutStrict() {
        let body = client().buildRequestBody(request(
            input: [["role": "user", "content": "hi"]],
            tools: [["type": "function", "name": "get_steps", "description": "d",
                     "parameters": ["type": "object"], "strict": true]]))
        let tools = body["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let fn = tools[0]["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_steps")
        // `strict` is an OpenAI structured-outputs extension; stricter proxies reject it here.
        XCTAssertNil(fn?["strict"])
    }

    func testToolCallingOffOmitsToolsEntirely() {
        // vLLM without --enable-auto-tool-choice returns HTTP 400 for the field's mere presence.
        let body = client(toolCalling: false).buildRequestBody(request(
            input: [["role": "user", "content": "hi"]],
            tools: [["type": "function", "name": "get_steps"]]))
        XCTAssertNil(body["tools"])
    }

    func testWebSearchIsDroppedSinceNoLocalEngineHostsOne() {
        let body = client().buildRequestBody(request(
            input: [["role": "user", "content": "hi"]],
            tools: [["type": "web_search"]]))
        XCTAssertNil(body["tools"])
    }

    func testResponseFormatFollowsTheStructuredOutputSetting() {
        XCTAssertNil(client(structured: .off).responseFormat())
        XCTAssertEqual(client(structured: .jsonObject).responseFormat()?["type"] as? String, "json_object")
        let schema = client(structured: .jsonSchema).responseFormat()
        XCTAssertEqual(schema?["type"] as? String, "json_schema")
        let nested = schema?["json_schema"] as? [String: Any]
        XCTAssertEqual(nested?["name"] as? String, CoachResponseSchema.name)
        XCTAssertEqual(nested?["strict"] as? Bool, true)
    }

    func testToolRoundsOmitResponseFormatSoNativeToolCallsRemainPossible() {
        let tool: [String: Any] = [
            "type": "function", "name": "log_workout",
            "parameters": ["type": "object"],
        ]
        for mode in [LocalStructuredOutput.jsonObject, .jsonSchema] {
            let body = client(structured: mode).buildRequestBody(request(
                input: [["role": "user", "content": "log my workout"]],
                tools: [tool]))
            XCTAssertNotNil(body["tools"], "tools must remain enabled in \(mode)")
            XCTAssertNil(body["response_format"], "a grammar blocks native tool calls in \(mode)")
        }
    }

    func testToollessRoundsStillApplyConfiguredResponseFormat() {
        let body = client(structured: .jsonSchema).buildRequestBody(request(
            input: [["role": "user", "content": "return the final answer"]]))
        XCTAssertNil(body["tools"])
        let format = body["response_format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
    }

    func testMaxTokensIsOmittedUnlessPositive() {
        XCTAssertNil(client(maxTokens: nil).buildRequestBody(
            request(input: [["role": "user", "content": "hi"]]))["max_tokens"])
        XCTAssertNil(client(maxTokens: 0).buildRequestBody(
            request(input: [["role": "user", "content": "hi"]]))["max_tokens"])
        XCTAssertEqual(client(maxTokens: 4096).buildRequestBody(
            request(input: [["role": "user", "content": "hi"]]))["max_tokens"] as? Int, 4096)
    }

    func testNoReasoningCacheControlOrProviderBlockIsEverSent() {
        let body = client().buildRequestBody(request(input: [["role": "user", "content": "hi"]]))
        for key in ["reasoning", "reasoning_effort", "cache_control", "provider", "usage"] {
            XCTAssertNil(body[key], key)
        }
    }

    // MARK: Response parsing

    /// Decodes a Chat Completions response body for `ingestResponse`. Throwing rather than
    /// force-casting so a malformed literal in a test fails as that test, not as a crash that
    /// takes the whole suite with it.
    private func root(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("test fixture is not a JSON object", file: file, line: line)
            return [:]
        }
        return object
    }

    func testParsesContentAndStripsThinkBlocks() throws {
        let r = try client().ingestResponse(try root("""
        {"id":"chatcmpl-1","choices":[{"message":{"role":"assistant",
         "content":"<think>hmm</think>{\\"title\\":\\"ok\\"}"}}],
         "usage":{"prompt_tokens":10,"completion_tokens":4}}
        """))
        XCTAssertEqual(r.id, "chatcmpl-1")
        XCTAssertEqual(r.outputText, "{\"title\":\"ok\"}")
        XCTAssertEqual(r.usage?.inputTokens, 10)
        XCTAssertEqual(r.usage?.outputTokens, 4)
    }

    func testAnUnmatchedLeadingCloseThinkIsStripped() throws {
        // R1-style distills on llama.cpp/Ollama get the OPENING tag from the chat template, so the
        // completion starts mid-thought and content carries only the closing tag. Left in, the
        // whole chain of thought reached the parser and burned the repair budget.
        let r = try client().ingestResponse(try root("""
        {"id":"c","choices":[{"message":{"role":"assistant",
         "content":"the user wants a plan. let me think.</think>{\\"title\\":\\"ok\\"}"}}]}
        """))
        XCTAssertEqual(r.outputText, "{\"title\":\"ok\"}")
    }

    func testAnUnterminatedTrailingOpenThinkStillDropsItsRemainder() throws {
        let r = try client().ingestResponse(try root("""
        {"id":"c","choices":[{"message":{"role":"assistant",
         "content":"{\\"title\\":\\"ok\\"}<think>and then I would"}}]}
        """))
        XCTAssertEqual(r.outputText, "{\"title\":\"ok\"}")
    }

    func testTextWithNoThinkTagsAtAllIsUntouched() throws {
        let r = try client().ingestResponse(try root("""
        {"id":"c","choices":[{"message":{"role":"assistant","content":"{\\"title\\":\\"ok\\"}"}}]}
        """))
        XCTAssertEqual(r.outputText, "{\"title\":\"ok\"}")
    }

    func testToolCallArgumentsSurviveBothTheStringAndObjectEncodings() throws {
        // The spec says `arguments` is a JSON string; several local parsers emit an object.
        let asString = try client().ingestResponse(try root("""
        {"id":"a","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"get_steps","arguments":"{\\"days\\":7}"}}]}}]}
        """))
        XCTAssertEqual(asString.functionCalls.first?.arguments, "{\"days\":7}")

        let asObject = try client().ingestResponse(try root("""
        {"id":"b","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_2","type":"function","function":{"name":"get_steps","arguments":{"days":7}}}]}}]}
        """))
        XCTAssertEqual(asObject.functionCalls.first?.name, "get_steps")
        XCTAssertTrue(asObject.functionCalls.first?.arguments.contains("days") ?? false)
    }

    func testABodyLevelErrorIsSurfacedAsADecodingFailure() {
        // Reverse proxies routinely report errors in the body on an HTTP 200.
        XCTAssertThrowsError(try client().ingestResponse(try root(#"{"error":{"message":"no model"}}"#)))
        // llama.cpp sometimes makes `error` a bare string.
        XCTAssertThrowsError(try client().ingestResponse(try root(#"{"error":"no model"}"#)))
    }

    func testANonOpenAIResponseSaysSoInsteadOfThrowingABareParseError() {
        XCTAssertThrowsError(try client().ingestResponse(try root(#"{"hello":"world"}"#))) { error in
            guard case ResponsesError.decoding(let message) = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(message.contains("OpenAI-compatible"))
        }
    }

    func testAReasoningModelTruncatedMidThoughtReportsTheTokenLimitNotEmptyOutput() {
        // "The model returned no output" would send the user after the wrong problem; the fix is
        // the Max tokens field.
        XCTAssertThrowsError(try client().ingestResponse(try root("""
        {"id":"c","choices":[{"finish_reason":"length","message":{"role":"assistant",
         "content":null,"reasoning":"..."}}]}
        """))) { error in
            guard case ResponsesError.decoding(let message) = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(message.contains("Max tokens"))
        }
    }

    func testUsageIsNilRatherThanZeroWhenTheServerOmitsTheBlock() throws {
        let r = try client().ingestResponse(try root("""
        {"id":"c","choices":[{"message":{"role":"assistant","content":"{}"}}]}
        """))
        XCTAssertNil(r.usage)
    }

    func testAContinuationReplaysTheAssistantToolCallsBeforeTheToolResults() throws {
        // Chat Completions requires the assistant `tool_calls` message to precede the `tool`
        // results answering them.
        let c = client()
        _ = c.buildRequestBody(request(input: [["role": "user", "content": "hi"]]))
        _ = try c.ingestResponse(try root("""
        {"id":"resp-1","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"get_steps","arguments":"{}"}}]}}]}
        """))
        let body = c.buildRequestBody(request(
            input: [["type": "function_call_output", "call_id": "call_1", "output": "{\"steps\":900}"]],
            previousResponseId: "resp-1"))
        let msgs = messages(body)
        let assistantIndex = msgs.firstIndex { $0["tool_calls"] != nil }
        let toolIndex = msgs.firstIndex { ($0["role"] as? String) == "tool" }
        XCTAssertNotNil(assistantIndex)
        XCTAssertNotNil(toolIndex)
        XCTAssertLessThan(assistantIndex!, toolIndex!)
    }
}
