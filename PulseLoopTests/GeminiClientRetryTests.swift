import Foundation
import XCTest
@testable import PulseLoop

/// URLProtocol that answers each request through a handler, so a test can fail
/// some requests (e.g. only the grounding turn) and record every body sent.
final class GeminiRoutingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (([String: Any]) -> (status: Int, body: String))?
    nonisolated(unsafe) static var sentBodies: [[String: Any]] = []

    static func reset() { handler = nil; sentBodies = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.sentBodies.append(json)
        let (status, body) = Self.handler?(json) ?? (200, Self.text("ok"))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func text(_ text: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"candidates":[{"content":{"parts":[{"text":"# + escaped + #"}]}}]}"#
    }

    nonisolated private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: 4096)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Port of Android GeminiClientTest's overload-retry (503) and refused-grounding (429) cases.
final class GeminiClientRetryTests: XCTestCase {
    override func setUp() { super.setUp(); GeminiRoutingURLProtocol.reset() }
    override func tearDown() { GeminiRoutingURLProtocol.reset(); super.tearDown() }

    private var sent: [[String: Any]] { GeminiRoutingURLProtocol.sentBodies }

    private func client(_ key: String) -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiRoutingURLProtocol.self]
        return GeminiClient(apiKey: key, session: URLSession(configuration: config), overloadBackoff: .milliseconds(1))
    }

    private func respond(_ handler: @escaping ([String: Any]) -> (status: Int, body: String)) {
        GeminiRoutingURLProtocol.handler = handler
    }

    private static func isGrounding(_ body: [String: Any]) -> Bool {
        (body["tools"] as? [[String: Any]])?.contains { $0["google_search"] != nil } == true
    }

    private static func lastUserText(_ body: [String: Any]) -> String {
        let last = (body["contents"] as? [[String: Any]])?.last
        return ((last?["parts"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private static func responseSchema(_ body: [String: Any]) -> Any? {
        (body["generationConfig"] as? [String: Any])?["responseSchema"]
    }

    private let fnTool: [String: Any] = ["type": "function", "name": "t",
                                         "parameters": ["type": "object", "properties": [:]]]

    /// Tool turn (web search requested) answered with prose; returns its response id.
    private func toolTurn(_ client: GeminiClient) async throws -> String {
        try await client.send(requestBody: OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [OpenAIRequestBuilder.message(role: "user", content: "hi")],
            tools: [WebSearchTool.spec, fnTool], textFormat: CoachResponseSchema.textFormat,
            previousResponseId: nil, reasoningEffort: nil)).id
    }

    private func repairTurn(_ client: GeminiClient, _ previousId: String) async throws -> OpenAIResponse {
        try await client.send(requestBody: OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [OpenAIRequestBuilder.message(role: "user", content: "format it")],
            tools: [], textFormat: CoachResponseSchema.textFormat, previousResponseId: previousId, reasoningEffort: nil))
    }

    private func plainTurn(_ client: GeminiClient) async throws -> OpenAIResponse {
        try await client.send(requestBody: OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: [], tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil))
    }

    // MARK: Overload retry (503)

    func testA503IsRetriedAndTheTurnSurvives() async throws {
        var attempts = 0
        respond { _ in
            attempts += 1
            return attempts <= 2 ? (503, "This model is currently experiencing high demand.") : (200, GeminiRoutingURLProtocol.text("ok"))
        }
        let response = try await plainTurn(client("key-503-ok"))
        XCTAssertEqual(response.outputText, "ok")
        XCTAssertEqual(attempts, 3)
    }

    func testTheLast503StillSurfaces() async throws {
        respond { _ in (503, "still overloaded") }
        do {
            _ = try await plainTurn(client("key-503-down"))
            XCTFail("a persistently overloaded model must surface, not hang")
        } catch ResponsesError.http(let status, _) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(sent.count, 3)
    }

    func testA429IsNeverRetriedOnAPlainTurn() async throws {
        respond { _ in (429, "You exceeded your current quota.") }
        do {
            _ = try await toolTurn(client("key-429-plain"))
            XCTFail("a quota refusal on a normal turn must surface")
        } catch ResponsesError.http(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(sent.count, 1)
    }

    func testOverloadBackoffIsCancellable() async throws {
        respond { _ in (503, "busy") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiRoutingURLProtocol.self]
        let slow = GeminiClient(apiKey: "key-503-cancel", session: URLSession(configuration: config),
                                overloadBackoff: .seconds(30))
        let task = Task { try await self.plainTurn(slow) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("a cancelled turn must not complete")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: Refused grounding turn (429)

    func testA429OnTheGroundingTurnIsRetriedOnceWithoutGoogleSearch() async throws {
        respond { body in
            if Self.isGrounding(body) { return (429, "You exceeded your current quota") }
            return (200, GeminiRoutingURLProtocol.text(GeminiRoutingURLProtocol.sentBodies.count == 1 ? "prose" : #"{"title":"ok"}"#))
        }
        let c = client("key-123-retry")
        let answer = try await repairTurn(c, try await toolTurn(c))

        XCTAssertEqual(answer.outputText, #"{"title":"ok"}"#)
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(Self.isGrounding(sent[1]))
        let retry = sent[2]
        XCTAssertFalse(Self.isGrounding(retry))
        XCTAssertNil(retry["tools"])
        // The retry is the schema turn it would otherwise have been, and says search was skipped.
        XCTAssertNotNil(Self.responseSchema(retry))
        XCTAssertTrue(Self.lastUserText(retry).contains("Web search was not available"))
    }

    func testARefusedKeySkipsGroundingOnLaterTurnsWithoutTheExtraRoundTrip() async throws {
        let key = "key-123-remembered"
        var refusals = 0
        respond { body in
            if Self.isGrounding(body) { refusals += 1; return (429, "quota") }
            return (200, GeminiRoutingURLProtocol.text("prose"))
        }
        let first = client(key)
        _ = try await repairTurn(first, try await toolTurn(first))
        XCTAssertEqual(refusals, 1)

        // Next agent turn: a fresh client (the orchestrator builds one per turn).
        GeminiRoutingURLProtocol.sentBodies = []
        let second = client(key)
        _ = try await repairTurn(second, try await toolTurn(second))
        XCTAssertEqual(refusals, 1)
        XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(Self.isGrounding(sent[1]))
        XCTAssertNotNil(Self.responseSchema(sent[1]))
        XCTAssertTrue(Self.lastUserText(sent[1]).contains("Web search was not available"))

        // A different key is unaffected.
        respond { _ in (200, GeminiRoutingURLProtocol.text("prose")) }
        let other = client("key-123-other")
        _ = try await repairTurn(other, try await toolTurn(other))
        XCTAssertTrue(Self.isGrounding(try XCTUnwrap(sent.last)))
    }

    func testA429OnTheUngroundedRetrySurfacesAndIsNotRemembered() async throws {
        // The key itself is out of quota: the retry fails too, and grounding is not blamed.
        let key = "key-123-exhausted"
        var calls = 0
        respond { _ in
            calls += 1
            return calls == 1 ? (200, GeminiRoutingURLProtocol.text("prose")) : (429, "You exceeded your current quota")
        }
        let c = client(key)
        let id = try await toolTurn(c)
        do {
            _ = try await repairTurn(c, id)
            XCTFail("a 429 on the retry must surface, not loop")
        } catch ResponsesError.http(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(calls, 3)   // tool turn, grounding turn, one retry

        // Not marked as grounding-refused: a later turn on the same key still grounds.
        respond { _ in (200, GeminiRoutingURLProtocol.text("prose")) }
        let next = client(key)
        _ = try await repairTurn(next, try await toolTurn(next))
        XCTAssertTrue(Self.isGrounding(try XCTUnwrap(sent.last)))
    }
}
