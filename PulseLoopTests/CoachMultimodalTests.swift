import XCTest
@testable import PulseLoop

/// Verifies multimodal (image) input across the canonical request builder and the
/// Gemini / OpenRouter adapters. Two invariants matter:
///   1. Image-bearing user turns serialize to each provider's correct image shape.
///   2. Text-only turns serialize to the *old* `"content": "<string>"` form — proof
///      that adding images didn't change the existing (text + tool-call) path.
///
/// Reuses `StubURLProtocol` from CoachTests to capture the translated request body.
final class CoachMultimodalTests: XCTestCase {

    private let img = CoachImagePayload(
        dataURL: "data:image/jpeg;base64,QUJD",  // base64 of "ABC"
        rawBase64: "QUJD",
        mimeType: "image/jpeg"
    )

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Canonical builder (OpenAI Responses shape)

    func testBuilder_textOnly_keepsStringContent() {
        let msg = OpenAIRequestBuilder.message(role: "user", content: "hello")
        XCTAssertEqual(msg["content"] as? String, "hello",
                       "Text-only content must remain a plain String (unchanged path).")
    }

    func testBuilder_withImage_emitsInputImagePart() throws {
        let msg = OpenAIRequestBuilder.message(role: "user", content: "what is this?", images: [img])
        let parts = try XCTUnwrap(msg["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "input_text")
        XCTAssertEqual(parts[0]["text"] as? String, "what is this?")
        XCTAssertEqual(parts[1]["type"] as? String, "input_image")
        XCTAssertEqual(parts[1]["image_url"] as? String, "data:image/jpeg;base64,QUJD")
    }

    // MARK: - Attachment ref round-trip

    func testAttachmentRef_encodeDecodeRoundTrip() {
        let refs = [CoachAttachmentRef(file: "a.jpg", width: 100, height: 80)]
        let json = CoachAttachmentRef.encode(refs)
        XCTAssertNotNil(json)
        XCTAssertEqual(CoachAttachmentRef.decode(fromJSON: json), refs)
        XCTAssertNil(CoachAttachmentRef.encode([]), "Empty refs encode to nil (no field written).")
        XCTAssertEqual(CoachAttachmentRef.decode(fromJSON: nil), [])
    }

    // MARK: - Gemini adapter translation

    func testGemini_imageItem_emitsInlineDataPart() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)

        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let input = [OpenAIRequestBuilder.message(role: "user", content: "describe", images: [img])]
        let body = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: input, tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try captured()
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "describe")
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inline["data"] as? String, "QUJD", "Gemini gets bare base64, no data: prefix.")
    }

    func testGemini_textOnly_emitsPlainTextPart() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)

        let client = GeminiClient(apiKey: "AIza-test", session: session())
        let input = [OpenAIRequestBuilder.message(role: "user", content: "hi")]
        let body = try OpenAIRequestBuilder.data(
            model: "gemini-2.5-flash", input: input, tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try captured()
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["text"] as? String, "hi")
        XCTAssertNil(parts[0]["inlineData"])
    }

    // MARK: - OpenRouter adapter translation

    func testOpenRouter_imageItem_emitsImageURLPart() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)

        let client = OpenRouterClient(apiKey: "sk-or-test", session: session())
        let input = [OpenAIRequestBuilder.message(role: "user", content: "look", images: [img])]
        let body = try OpenAIRequestBuilder.data(
            model: "anthropic/claude-sonnet-4.6", input: input, tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try captured()
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMsg = try XCTUnwrap(messages.first { ($0["role"] as? String) == "user" })
        let parts = try XCTUnwrap(userMsg["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,QUJD")
    }

    func testOpenRouter_textOnly_keepsStringContent() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)

        let client = OpenRouterClient(apiKey: "sk-or-test", session: session())
        let input = [OpenAIRequestBuilder.message(role: "user", content: "hi")]
        let body = try OpenAIRequestBuilder.data(
            model: "anthropic/claude-sonnet-4.6", input: input, tools: [], textFormat: nil,
            previousResponseId: nil, reasoningEffort: nil)
        _ = try await client.send(requestBody: body)

        let json = try captured()
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMsg = try XCTUnwrap(messages.first { ($0["role"] as? String) == "user" })
        XCTAssertEqual(userMsg["content"] as? String, "hi",
                       "Text-only user content must stay a String so cache-control still applies.")
    }

    // MARK: - Helper

    private func captured() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
