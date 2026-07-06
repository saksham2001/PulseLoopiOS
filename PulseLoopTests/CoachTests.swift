import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

// MARK: - Stubs

/// In-memory ResponsesClient that replays a scripted queue of responses.
actor StubResponsesClient: ResponsesClient {
    private var queue: [OpenAIResponse]
    private(set) var sendCount = 0
    init(_ responses: [OpenAIResponse]) { self.queue = responses }
    func send(requestBody: Data) async throws -> OpenAIResponse {
        sendCount += 1
        return queue.isEmpty ? OpenAIResponse(id: "empty", outputItems: []) : queue.removeFirst()
    }
}

/// URLProtocol that returns a fixed body/status for the Responses client test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastRequestURL: URL?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        Self.lastRequestURL = request.url
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func validResponseJSON(title: String = "Today") -> String {
    """
    {"response_type":"insight","title":"\(title)","summary":"You did well.","bullets":["A","B"],\
    "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
    "follow_up_chips":["More"],"actions_taken":[],"confidence":"high"}
    """
}

// MARK: - Schema

final class CoachSchemaTests: XCTestCase {
    func testDecodeValidResponse() throws {
        let r = try XCTUnwrap(CoachResponse.decode(fromJSON: validResponseJSON()))
        XCTAssertEqual(r.responseType, .insight)
        XCTAssertEqual(r.title, "Today")
        XCTAssertEqual(r.bullets, ["A", "B"])
        XCTAssertEqual(r.confidence, .high)
    }

    func testRejectsMissingRequiredField() {
        // No response_type / summary → decode must fail.
        XCTAssertNil(CoachResponse.decode(fromJSON: #"{"title":"x"}"#))
    }

    func testParserStripsCodeFenceAndProse() {
        let fenced = "```json\n\(validResponseJSON())\n```"
        XCTAssertNotNil(CoachResponseParser.parse(fenced))
        let prose = "Here you go:\n\(validResponseJSON())\nHope that helps!"
        XCTAssertNotNil(CoachResponseParser.parse(prose))
    }

    func testStrictSchemaIsSerializable() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(CoachResponseSchema.jsonSchema))
        let format = CoachResponseSchema.textFormat
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testChartRoundTrips() throws {
        let chart = CoachChart(chartType: .bar, title: "Steps", metric: .steps,
                               range: CoachChartRange(start: "2026-05-01", end: "2026-05-07"),
                               data: [CoachChartPoint(x: "2026-05-01", y: 8000, series: nil)])
        let response = CoachResponse(responseType: .insightWithChart, title: "T", summary: "S", chart: chart)
        let json = try XCTUnwrap(response.encodedJSON())
        let decoded = try XCTUnwrap(CoachResponse.decode(fromJSON: json))
        XCTAssertEqual(decoded.chart?.chartType, .bar)
        XCTAssertEqual(decoded.chart?.data.first?.y, 8000)
    }
}

// MARK: - Analysis engine

final class AnalysisEngineTests: XCTestCase {
    func testTrendRising() {
        let base = Date()
        let series = (0..<5).map { (Calendar.current.date(byAdding: .day, value: $0, to: base)!, Double($0 * 100)) }
        let t = AnalysisEngine.trend(series)
        XCTAssertEqual(t.direction, "rising")
        XCTAssertEqual(t.changeAbsolute, 400)
    }

    func testCorrelationPerfectPositive() {
        let r = AnalysisEngine.correlation([(1, 2), (2, 4), (3, 6), (4, 8)])
        XCTAssertEqual(r.pearson ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(r.strength, "strong")
    }

    func testDistribution() {
        let d = AnalysisEngine.distribution([1, 2, 3, 4, 5])
        XCTAssertEqual(d.median, 3)
        XCTAssertEqual(d.min, 1)
        XCTAssertEqual(d.max, 5)
    }

    func testOutlierDetected() {
        var values = Array(repeating: 100.0, count: 8)
        values.append(1000)
        let series = values.enumerated().map { (Calendar.current.date(byAdding: .day, value: $0.offset, to: Date())!, $0.element) }
        XCTAssertFalse(AnalysisEngine.outliers(series).isEmpty)
    }
}

// MARK: - Tools

@MainActor
final class CoachToolTests: XCTestCase {
    private func context() throws -> ModelContext { try TestSupport.makeContext() }

    private func ctx(_ modelContext: ModelContext) -> ToolExecutionContext {
        ToolExecutionContext(modelContext: modelContext, flags: CoachFeatureFlags(settings: .default, hasAPIKey: false))
    }

    func testDailySummaryReturnsActivity() async throws {
        let c = try context()
        let today = CoachDataAccess.localDateString(Date())
        TestSupport.insertActivity(date: Date(), steps: 8200, calories: 410, into: c)
        TestSupport.insertMeasurement(kind: .heartRate, value: 72, timestamp: Date(), into: c)

        let tool = try XCTUnwrap(ToolRegistry(flags: ctx(c).flags).tool(named: "get_daily_summary"))
        let result = try await tool.run(Data(#"{"date":"\#(today)"}"#.utf8), ctx(c))
        let obj = try parse(result)
        XCTAssertEqual((obj["data_available"] as? Bool), true)
        let activity = try XCTUnwrap(obj["activity"] as? [String: Any])
        XCTAssertEqual(activity["steps"] as? Int, 8200)
    }

    func testMetricSeriesFiltersToRange() async throws {
        let c = try context()
        TestSupport.insertActivity(date: TestSupport.day(0), steps: 5000, into: c)
        TestSupport.insertActivity(date: TestSupport.day(-1), steps: 6000, into: c)
        TestSupport.insertActivity(date: TestSupport.day(-40), steps: 9999, into: c)

        let start = CoachDataAccess.localDateString(TestSupport.day(-7))
        let end = CoachDataAccess.localDateString(TestSupport.day(0))
        let tool = try XCTUnwrap(ToolRegistry(flags: ctx(c).flags).tool(named: "get_metric_series"))
        let result = try await tool.run(Data(#"{"metric":"steps","start":"\#(start)","end":"\#(end)","granularity":"day"}"#.utf8), ctx(c))
        let obj = try parse(result)
        XCTAssertEqual(obj["count"] as? Int, 2)  // the -40d row is excluded
    }

    func testHRRawSeriesKeepsIntradayPointsButDailyCollapses() throws {
        let c = try context()
        let day = "2026-06-01"
        let base = try XCTUnwrap(CoachDataAccess.parseLocalDate(day))
        for h in [8, 12, 18] {
            TestSupport.insertMeasurement(kind: .heartRate, value: Double(60 + h),
                                          timestamp: base.addingTimeInterval(Double(h) * 3600), into: c)
        }
        let raw = CoachDataAccess.seriesPoints(metric: .hr, start: day, end: day, granularity: "raw", context: c)
        XCTAssertEqual(raw.count, 3)  // intraday readings preserved
        let daily = CoachDataAccess.seriesPoints(metric: .hr, start: day, end: day, granularity: "day", context: c)
        XCTAssertEqual(daily.count, 1)  // one daily average
    }

    func testPrepareChartEmbedsData() async throws {
        let c = try context()
        TestSupport.insertActivity(date: TestSupport.day(0), steps: 8000, into: c)
        TestSupport.insertActivity(date: TestSupport.day(-1), steps: 7000, into: c)

        let start = CoachDataAccess.localDateString(TestSupport.day(-6))
        let end = CoachDataAccess.localDateString(TestSupport.day(0))
        let tool = try XCTUnwrap(ToolRegistry(flags: ctx(c).flags).tool(named: "prepare_chart"))
        let result = try await tool.run(Data(#"{"chart_type":"bar","title":"Steps","metric":"steps","start":"\#(start)","end":"\#(end)","granularity":"day","annotations":[]}"#.utf8), ctx(c))
        // The returned `chart` must decode as a CoachChart (verbatim-copy contract).
        let obj = try parse(result)
        let chartData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(obj["chart"]))
        let chart = try XCTUnwrap(CoachChart.decode(chartData))
        XCTAssertEqual(chart.chartType, .bar)
        XCTAssertEqual(chart.data.count, 2)
    }

    func testRegistryHasReadOnlyToolsOnly() {
        let registry = ToolRegistry(flags: CoachFeatureFlags(settings: .default, hasAPIKey: true))
        let names = Set(registry.toolSpecs.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("get_daily_summary"))
        XCTAssertTrue(names.contains("prepare_chart"))
        XCTAssertTrue(names.contains("analyze_trend"))
        XCTAssertFalse(names.contains("set_goal"))           // Milestone B
        XCTAssertFalse(names.contains("delete_activity_session"))
    }

    private func parse(_ result: ToolResult) throws -> [String: Any] {
        let data = Data(result.jsonString.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Orchestrator

@MainActor
final class CoachOrchestratorTests: XCTestCase {
    private func packet(_ c: ModelContext) -> CoachContextPacket { CoachContextBuilder.build(context: c) }

    private func orchestrator(client: ResponsesClient, flags: CoachFeatureFlags, context: ModelContext) -> CoachOrchestrator {
        CoachOrchestrator(client: client, registry: ToolRegistry(flags: flags), flags: flags,
                          toolContext: ToolExecutionContext(modelContext: context, flags: flags))
    }

    func testDisabledCoachUsesScriptedFallback() async throws {
        let c = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 7000, into: c)
        let flags = CoachFeatureFlags(settings: .default, hasAPIKey: false)  // disabled
        let o = orchestrator(client: StubResponsesClient([]), flags: flags, context: c)
        let result = await o.runTurn(userText: "How am I doing?", packet: packet(c), recentMessages: [])
        XCTAssertEqual(result.assistant.responseType, .insight)
        XCTAssertTrue(result.assistant.bullets.contains { $0.contains("7000") })
    }

    func testMessageOnlyResponseIsParsed() async throws {
        let c = try TestSupport.makeContext()
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        let stub = StubResponsesClient([OpenAIResponse(id: "r1", outputItems: [.message(text: validResponseJSON(title: "Hi"))])])
        let o = orchestrator(client: stub, flags: flags, context: c)
        let result = await o.runTurn(userText: "hi", packet: packet(c), recentMessages: [])
        XCTAssertEqual(result.assistant.title, "Hi")
        XCTAssertTrue(result.trace.isEmpty)
    }

    func testToolCallThenFinalRecordsTrace() async throws {
        let c = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 8200, into: c)
        let today = CoachDataAccess.localDateString(Date())
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        let stub = StubResponsesClient([
            OpenAIResponse(id: "r1", outputItems: [.functionCall(.init(name: "get_daily_summary", callID: "c1", arguments: #"{"date":"\#(today)"}"#))]),
            OpenAIResponse(id: "r2", outputItems: [.message(text: validResponseJSON())]),
        ])
        let o = orchestrator(client: stub, flags: flags, context: c)
        var traceEvents: [CoachTraceEvent] = []
        let result = await o.runTurn(userText: "today?", packet: packet(c), recentMessages: []) { traceEvents.append($0) }
        XCTAssertEqual(result.trace.count, 1)
        XCTAssertEqual(result.trace.first?.toolName, "get_daily_summary")
        XCTAssertEqual(result.trace.first?.status, "success")
        XCTAssertTrue(traceEvents.contains { $0.status == .runningTool })
    }

    func testUnparseableFinalFallsBack() async throws {
        let c = try TestSupport.makeContext()
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        // Every response is junk → repair loop exhausts → fallback.
        let junk = OpenAIResponse(id: "x", outputItems: [.message(text: "not json")])
        let o = orchestrator(client: StubResponsesClient([junk, junk, junk, junk]), flags: flags, context: c)
        let result = await o.runTurn(userText: "hi", packet: packet(c), recentMessages: [])
        XCTAssertEqual(result.assistant.responseType, .errorRecovery)
    }
}

// MARK: - HTTP client

final class OpenAIResponsesClientTests: XCTestCase {
    func testParsesFunctionCallAndText() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("""
        {"id":"resp_1","output":[
          {"type":"function_call","name":"get_daily_summary","call_id":"call_1","arguments":"{\\"date\\":\\"2026-06-01\\"}"},
          {"type":"message","content":[{"type":"output_text","text":"hello"}]}
        ]}
        """.utf8)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = OpenAIResponsesClient(apiKey: "sk-test", session: URLSession(configuration: config))

        let body = try OpenAIRequestBuilder.data(model: "gpt-5.4", input: [], tools: [], textFormat: nil, previousResponseId: nil, reasoningEffort: nil)
        let response = try await client.send(requestBody: body)
        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls.first?.name, "get_daily_summary")
        XCTAssertEqual(response.outputText, "hello")
    }

    func testHTTPErrorThrows() async {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseBody = Data(#"{"error":"bad key"}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = OpenAIResponsesClient(apiKey: "sk-test", session: URLSession(configuration: config))
        do {
            _ = try await client.send(requestBody: Data("{}".utf8))
            XCTFail("expected error")
        } catch {
            // expected
        }
    }
}

private extension CoachChart {
    static func decode(_ data: Data) -> CoachChart? { try? JSONDecoder().decode(CoachChart.self, from: data) }
}

// MARK: - Gemini client

/// Verifies the Gemini adapter translates the app's OpenAI-Responses-shaped
/// request/response to/from Gemini's `generateContent`, so every coach feature
/// (tool calls, structured output) works on Gemini exactly as on OpenAI.
final class GeminiClientTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testParsesFunctionCallAndText() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("""
        {"candidates":[{"content":{"parts":[
          {"functionCall":{"name":"get_daily_summary","args":{"date":"2026-06-01"}}},
          {"text":"hello"}
        ]}}]}
        """.utf8)

        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        let response = try await client.send(requestBody: body)

        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls.first?.name, "get_daily_summary")
        XCTAssertTrue(response.functionCalls.first?.arguments.contains("2026-06-01") ?? false)
        XCTAssertFalse(response.functionCalls.first?.callID.isEmpty ?? true)
        XCTAssertEqual(response.outputText, "hello")
    }

    /// Regression test: the user-selected model in the request body must drive the
    /// Gemini endpoint, not the client's hardcoded default.
    func testUsesModelFromRequestBody() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)

        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-pro", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let url = StubURLProtocol.lastRequestURL?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/models/gemini-2.5-pro:generateContent"),
                      "expected gemini-2.5-pro endpoint, got \(url)")
    }

    /// The request the orchestrator builds carries OpenAI tool specs and a strict
    /// JSON schema; the Gemini body must convert tools to `functionDeclarations`
    /// and strip schema keywords Gemini rejects.
    func testConvertsToolsAndCleansSchema() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)

        let tool: [String: Any] = [
            "type": "function",
            "name": "get_metric_series",
            "description": "series",
            "parameters": [
                "type": "object",
                "additionalProperties": false,
                "strict": true,
                "properties": [
                    "metric": ["type": "string"],
                    "note": ["type": ["string", "null"]],
                ],
            ],
        ]
        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [], tools: [tool], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let sent = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let decls = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        let decl = try XCTUnwrap(decls.first)
        XCTAssertEqual(decl["name"] as? String, "get_metric_series")

        let params = try XCTUnwrap(decl["parameters"] as? [String: Any])
        XCTAssertNil(params["additionalProperties"], "additionalProperties must be stripped")
        XCTAssertNil(params["strict"], "strict must be stripped")
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        let note = try XCTUnwrap(props["note"] as? [String: Any])
        XCTAssertEqual(note["type"] as? String, "string", "union type must collapse to a single type")
        XCTAssertEqual(note["nullable"] as? Bool, true, "null member must become nullable: true")

        // Regression: VALIDATED mode (constrained decoding) must be requested when
        // tools are present, so Gemini emits all required fields like OpenAI strict.
        let toolConfig = try XCTUnwrap(json["toolConfig"] as? [String: Any])
        let fcConfig = try XCTUnwrap(toolConfig["functionCallingConfig"] as? [String: Any])
        XCTAssertEqual(fcConfig["mode"] as? String, "VALIDATED")
    }

    /// Tool-less turns (the structured-output / repair turn) must NOT set VALIDATED
    /// — Gemini rejects toolConfig with no tools.
    func testNoToolConfigWhenToolless() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)

        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let sent = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertNil(json["toolConfig"], "toolConfig must be omitted on tool-less turns")
    }

    func testHTTPErrorThrows() async {
        StubURLProtocol.statusCode = 403
        StubURLProtocol.responseBody = Data(#"{"error":"bad key"}"#.utf8)
        let client = GeminiClient(apiKey: "AIza-test", session: session())
        do {
            let body = try OpenAIRequestBuilder.data(
                model: "gemini-2.5-flash", input: [], tools: [], textFormat: nil,
                previousResponseId: nil, reasoningEffort: nil)
            _ = try await client.send(requestBody: body)
            XCTFail("expected error")
        } catch {
            // expected
        }
    }

    /// When the OpenAI web_search spec is present, the tool-less turn must attach
    /// google_search (and drop the JSON responseSchema, which Gemini rejects
    /// alongside it). The function-tool turn must NOT carry google_search.
    func testWebSearchAttachesGoogleSearchOnToollessTurn() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)

        // Turn 1: function tools + web_search spec present → no google_search yet.
        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let fnTool: [String: Any] = ["type": "function", "name": "get_daily_summary",
                                     "parameters": ["type": "object", "properties": [:]]]
        let withTools = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [], tools: [fnTool, WebSearchTool.spec],
            textFormat: CoachResponseSchema.textFormat, previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: withTools)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequestBody)) as? [String: Any])
        let toolsTurn = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertNil(toolsTurn.first { $0["google_search"] != nil }, "no google_search while function tools present")

        // Turn 2: tool-less repair turn → google_search attached, schema dropped.
        let repair = OpenAIRequestBuilder.message(role: "user", content: "fix it")
        let toolless = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [repair], tools: [],
            textFormat: CoachResponseSchema.textFormat, previousResponseId: "r1", reasoningEffort: nil)
        _ = try await client.send(requestBody: toolless)
        json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequestBody)) as? [String: Any])
        let groundTools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertNotNil(groundTools.first { $0["google_search"] != nil }, "google_search must be attached on the tool-less grounding turn")
        XCTAssertNil((json["generationConfig"] as? [String: Any])?["responseSchema"], "responseSchema must be dropped on the grounding turn")
    }

    /// Sources cited via groundingMetadata are extracted into the next turn so the
    /// schema turn can fill the response `sources` array.
    func testGroundingSourcesAreCarriedForward() async throws {
        // First (grounding) response carries groundingMetadata.
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("""
        {"candidates":[{"content":{"parts":[{"text":"grounded answer"}]},
          "groundingMetadata":{"groundingChunks":[
            {"web":{"uri":"https://example.com/a","title":"Source A"}},
            {"web":{"uri":"https://example.com/b","title":"Source B"}}
          ]}}]}
        """.utf8)

        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let withSearch = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [], tools: [WebSearchTool.spec],
            textFormat: nil, previousResponseId: nil, reasoningEffort: nil)
        let resp = try await client.send(requestBody: withSearch)
        let respId = resp.id

        // Next continuation must include a user note listing the cited sources.
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)
        let next = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [OpenAIRequestBuilder.message(role: "user", content: "now JSON")],
            tools: [], textFormat: nil, previousResponseId: respId, reasoningEffort: nil)
        _ = try await client.send(requestBody: next)

        let sent = String(data: try XCTUnwrap(StubURLProtocol.lastRequestBody), encoding: .utf8) ?? ""
        // (URLs are JSON-escaped in the body, so match host + title, not the raw slash.)
        XCTAssertTrue(sent.contains("example.com") && sent.contains("Source A") && sent.contains("Source B"),
                      "grounding sources must be carried into the follow-up turn")
    }
}

// MARK: - OpenRouterClient

final class OpenRouterClientTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let okBody = Data(#"{"id":"gen-1","choices":[{"message":{"content":"ok"}}]}"#.utf8)

    /// Decodes the body the client actually sent to OpenRouter.
    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testParsesContentAndToolCalls() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("""
        {"id":"gen-2","choices":[{"message":{"content":null,"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"get_daily_summary","arguments":"{\\"date\\":\\"2026-06-01\\"}"}}
        ]}}]}
        """.utf8)

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "anthropic/claude-sonnet-4.6", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "ignored-by-openrouter", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        let response = try await client.send(requestBody: body)

        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls.first?.name, "get_daily_summary")
        XCTAssertEqual(response.functionCalls.first?.callID, "call_1")
        XCTAssertTrue(response.functionCalls.first?.arguments.contains("2026-06-01") ?? false)
    }

    /// Web search: the hosted `web_search` tool spec must be dropped from the
    /// function tools and instead route via the `:online` model suffix.
    func testWebSearchAddsOnlineSuffixAndDropsHostedTool() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "anthropic/claude-sonnet-4.6", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [["type": "web_search"]], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try sentBody()
        XCTAssertEqual(json["model"] as? String, "anthropic/claude-sonnet-4.6:online")
        // web_search is a hosted tool, not a function — it must not appear in tools.
        XCTAssertNil(json["tools"], "hosted web_search must be dropped, not forwarded as a function tool")
    }

    func testNoWebSearchKeepsBareModelSlug() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "anthropic/claude-sonnet-4.6", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        XCTAssertEqual(try sentBody()["model"] as? String, "anthropic/claude-sonnet-4.6")
    }

    /// A user-typed Custom slug already ending in `:online` must not be doubled.
    func testOnlineSuffixNotDoubled() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "anthropic/claude-sonnet-4.6:online", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [["type": "web_search"]], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        XCTAssertEqual(try sentBody()["model"] as? String, "anthropic/claude-sonnet-4.6:online")
    }

    func testPrivacyRoutingAddsDataCollectionDeny() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "x/y", privacyRouting: true, session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let provider = try XCTUnwrap(try sentBody()["provider"] as? [String: Any])
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
    }

    func testProviderSortAndPrivacyMergeIntoOneProviderObject() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(
            apiKey: "sk-or-v1-test", model: "x/y", privacyRouting: true, providerSort: "price", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let provider = try XCTUnwrap(try sentBody()["provider"] as? [String: Any])
        XCTAssertEqual(provider["sort"] as? String, "price")
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
    }

    func testNoProviderObjectWhenRoutingUnset() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "x/y", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        XCTAssertNil(try sentBody()["provider"], "provider object must be omitted when no routing options are set")
    }

    /// Regression: the unified `reasoning` object the app builds must still be
    /// forwarded as-is.
    func testReasoningForwarded() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "x/y", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: "high")
        _ = try await client.send(requestBody: body)

        let reasoning = try XCTUnwrap(try sentBody()["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
    }

    /// Structured outputs: the Responses-API `text.format` schema must be sent as
    /// Chat Completions `response_format` with `strict: true`, and the provider
    /// object must carry `require_parameters: true` so OpenRouter only routes to
    /// providers that actually enforce the schema.
    func testStructuredOutputSendsResponseFormatAndRequireParameters() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "x/y", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: CoachResponseSchema.textFormat,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try sentBody()
        let rf = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(rf["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(rf["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        XCTAssertEqual(jsonSchema["name"] as? String, "coach_response")
        XCTAssertNotNil(jsonSchema["schema"] as? [String: Any], "the coach_response schema must be carried")

        let provider = try XCTUnwrap(json["provider"] as? [String: Any])
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    }

    /// No `text.format` (e.g. a turn that doesn't constrain output) → no
    /// `response_format` and no `require_parameters`-only provider object.
    func testNoResponseFormatWhenNoSchema() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = OpenRouterClient(apiKey: "sk-or-v1-test", model: "x/y", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try sentBody()
        XCTAssertNil(json["response_format"])
        XCTAssertNil(json["provider"], "require_parameters must not be set without a schema to enforce")
    }
}

// MARK: - MiniMaxClient

final class MiniMaxClientTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let okBody = Data(#"{"id":"mm-1","choices":[{"message":{"content":"ok"}}]}"#.utf8)

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Requests hit MiniMax's OpenAI-compatible endpoint with the model sent as-is
    /// (no `:online` suffix — MiniMax has no hosted web search).
    func testEndpointAndModelSentAsIs() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = MiniMaxClient(apiKey: "mm-test", model: "MiniMax-M3", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "ignored", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        XCTAssertEqual(StubURLProtocol.lastRequestURL?.absoluteString, "https://api.minimax.io/v1/chat/completions")
        XCTAssertEqual(try sentBody()["model"] as? String, "MiniMax-M3")
    }

    func testParsesContentAndToolCalls() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("""
        {"id":"mm-2","choices":[{"message":{"content":null,"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"get_daily_summary","arguments":"{\\"date\\":\\"2026-06-01\\"}"}}
        ]}}]}
        """.utf8)

        let client = MiniMaxClient(apiKey: "mm-test", model: "MiniMax-M3", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        let response = try await client.send(requestBody: body)

        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls.first?.name, "get_daily_summary")
        XCTAssertEqual(response.functionCalls.first?.callID, "call_1")
        XCTAssertTrue(response.functionCalls.first?.arguments.contains("2026-06-01") ?? false)
    }

    /// The hosted `web_search` tool has no MiniMax equivalent, so it must be
    /// dropped (not forwarded as a function tool) and the model left unchanged.
    func testDropsHostedWebSearchTool() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = MiniMaxClient(apiKey: "mm-test", model: "MiniMax-M3", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [["type": "web_search"]], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try sentBody()
        XCTAssertEqual(json["model"] as? String, "MiniMax-M3")
        XCTAssertNil(json["tools"], "hosted web_search must be dropped, not forwarded")
    }

    /// MiniMax's compat endpoint doesn't document `response_format`, the OpenAI
    /// `reasoning` object, or a provider-routing block, so none are sent even when
    /// the app supplies a schema and reasoning effort.
    func testOmitsResponseFormatReasoningAndProvider() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = okBody

        let client = MiniMaxClient(apiKey: "mm-test", model: "MiniMax-M3", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: CoachResponseSchema.textFormat,
            previousResponseId: nil, reasoningEffort: "high")
        _ = try await client.send(requestBody: body)

        let json = try sentBody()
        XCTAssertNil(json["response_format"])
        XCTAssertNil(json["reasoning"])
        XCTAssertNil(json["provider"])
    }

    /// M-series models emit reasoning inline as `<think>…</think>`; those blocks
    /// must be stripped so the coach_response JSON parses.
    func testStripsThinkingBlocks() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(
            #"{"id":"mm-3","choices":[{"message":{"content":"<think>let me reason</think>the answer"}}]}"#.utf8)

        let client = MiniMaxClient(apiKey: "mm-test", model: "MiniMax-M3", session: session())
        let body = try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        let response = try await client.send(requestBody: body)

        XCTAssertEqual(response.outputText, "the answer")
    }

    /// Continuation turn: the assistant `tool_calls` message must be replayed
    /// before the `tool` result answering it (Chat Completions ordering), on the
    /// same client instance.
    func testReplaysAssistantToolCallsOnContinuation() async throws {
        let client = MiniMaxClient(apiKey: "mm-test", model: "MiniMax-M3", session: session())

        // Turn 1: the model asks for a tool call.
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("""
        {"id":"mm-turn1","choices":[{"message":{"content":null,"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"get_daily_summary","arguments":"{}"}}
        ]}}]}
        """.utf8)
        let first = try await client.send(requestBody: try OpenAIRequestBuilder.data(
            model: "x", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil))
        let callID = try XCTUnwrap(first.functionCalls.first).callID

        // Turn 2: we feed the tool result back, keyed by the prior response id.
        StubURLProtocol.responseBody = okBody
        _ = try await client.send(requestBody: try OpenAIRequestBuilder.data(
            model: "x",
            input: [["type": "function_call_output", "call_id": "call_1", "output": "{\"steps\":100}"]],
            tools: [], textFormat: nil, previousResponseId: "mm-turn1", reasoningEffort: nil))

        let messages = try XCTUnwrap(try sentBody()["messages"] as? [[String: Any]])
        // The replayed assistant message carrying the tool call.
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_1")
        // The tool result, ordered after the assistant message.
        let toolMsg = try XCTUnwrap(messages.first { ($0["role"] as? String) == "tool" })
        XCTAssertEqual(toolMsg["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(toolMsg["content"] as? String, "{\"steps\":100}")

        let assistantIdx = try XCTUnwrap(messages.firstIndex { ($0["role"] as? String) == "assistant" })
        let toolIdx = try XCTUnwrap(messages.firstIndex { ($0["role"] as? String) == "tool" })
        XCTAssertLessThan(assistantIdx, toolIdx, "assistant tool_calls must precede the tool result")
        XCTAssertEqual(callID, "call_1")
    }
}

// MARK: - CoachTurnError mapping

final class CoachTurnErrorTests: XCTestCase {
    func testHTTPErrorExtractsCodeAndJSONMessage() {
        let err = CoachTurnError(ResponsesError.http(
            status: 401,
            body: #"{"error":{"message":"No auth credentials found","code":401}}"#))
        XCTAssertEqual(err.code, "HTTP 401")
        XCTAssertEqual(err.reason, "No auth credentials found")
    }

    func testHTTPErrorWithPlainBodyFallsBackToBody() {
        let err = CoachTurnError(ResponsesError.http(status: 502, body: "Bad gateway"))
        XCTAssertEqual(err.code, "HTTP 502")
        XCTAssertEqual(err.reason, "Bad gateway")
    }

    func testHTTPErrorWithEmptyBodyHasReadableReason() {
        let err = CoachTurnError(ResponsesError.http(status: 500, body: ""))
        XCTAssertEqual(err.code, "HTTP 500")
        XCTAssertTrue(err.reason.contains("500"))
    }

    func testMissingAPIKeyMapsToFriendlyMessage() {
        let err = CoachTurnError(ResponsesError.missingAPIKey)
        XCTAssertEqual(err.code, "No API key")
        XCTAssertFalse(err.reason.isEmpty)
    }

    func testEmptyOutputMapsToNoOutput() {
        XCTAssertEqual(CoachTurnError(ResponsesError.emptyOutput).code, "No output")
    }

    func testRoundTripsThroughJSONForPersistence() throws {
        let original = CoachTurnError(code: "HTTP 429", reason: "Rate limited")
        let json = try XCTUnwrap(original.encodedJSON())
        XCTAssertEqual(CoachTurnError.decode(fromJSON: json), original)
    }
}
