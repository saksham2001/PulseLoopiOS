import Foundation
import XCTest
@testable import PulseLoop

/// Answers model-list requests through a handler and records each request.
final class CatalogStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (status: Int, body: String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() { handler = nil; requests = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (200, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Port of Android CoachModelCatalogTest: the live model listings (OpenAI / Gemini /
/// OpenRouter / MiniMax), what counts as unlisted, and live OpenRouter reasoning levels.
final class CoachModelCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CatalogStubProtocol.reset()
        for provider in [CoachProviderMode.userOpenAIKey, .userGeminiKey, .userOpenRouterKey, .userMiniMaxKey] {
            CoachModelCatalog.store(nil, for: provider, apiKey: "")
        }
    }

    override func tearDown() {
        CatalogStubProtocol.reset()
        CoachModelCatalog.store(nil, for: .userOpenRouterKey, apiKey: "")
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func listing(_ ids: [String]) -> CoachModelCatalog.Listing {
        CoachModelCatalog.Listing(entries: ids.map { CoachModelCatalog.Entry(id: $0) }, fetchedAt: Date())
    }

    // MARK: OpenAI

    func testOpenAIKeepsChatModelsAndDropsEverythingElse() throws {
        let body = """
        {"object":"list","data":[
            {"id":"gpt-6.1-sol"},{"id":"gpt-6-luna"},{"id":"o5"},{"id":"o5-mini"},
            {"id":"gpt-6.1-sol-2026-09-30"},{"id":"text-embedding-4-large"},{"id":"gpt-6-realtime"},
            {"id":"gpt-image-2"},{"id":"gpt-6-mini-tts"},{"id":"whisper-1"},{"id":"omni-moderation-latest"},
            {"id":"gpt-4o"},{"id":"dall-e-3"},{"id":"gpt-6-luna"}
        ]}
        """
        XCTAssertEqual(try CoachModelCatalog.parseOpenAI(Data(body.utf8)).map(\.id),
                       ["gpt-6-luna", "gpt-6.1-sol", "o5", "o5-mini"])
    }

    // MARK: Gemini

    func testGeminiKeepsGenerateContentModelsAndStripsTheModelsPrefix() throws {
        let body = """
        {"models":[
            {"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
            {"name":"models/gemini-flash-latest","displayName":"Gemini Flash Latest","supportedGenerationMethods":["generateContent"]},
            {"name":"models/gemini-embedding-002","supportedGenerationMethods":["embedContent"]},
            {"name":"models/gemini-3.8-flash-preview-tts","supportedGenerationMethods":["generateContent"]},
            {"name":"models/imagen-5","supportedGenerationMethods":["predict"]}
        ],"nextPageToken":"abc"}
        """
        let page = try CoachModelCatalog.parseGeminiPage(Data(body.utf8))
        XCTAssertEqual(page.entries.map(\.id), ["gemini-3.8-flash", "gemini-flash-latest"])
        XCTAssertEqual(page.entries.first?.name, "Gemini 3.8 Flash")
        XCTAssertEqual(page.nextPageToken, "abc")
        XCTAssertNil(try CoachModelCatalog.parseGeminiPage(Data(#"{"models":[]}"#.utf8)).nextPageToken)
    }

    func testGeminiFetchPagesWithTheKeyInAHeaderNotTheURL() async throws {
        CatalogStubProtocol.handler = { request in
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "pageToken" }?.value
            if token == nil {
                return (200, #"{"models":[{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"p 2"}"#)
            }
            return (200, #"{"models":[{"name":"models/gemini-4-argon","supportedGenerationMethods":["generateContent"]}]}"#)
        }
        let result = await CoachModelCatalog.fetch(.userGeminiKey, apiKey: "AIza-secret", session: session())

        XCTAssertEqual(result.listing?.entries.map(\.id), ["gemini-3.8-flash", "gemini-4-argon"])
        XCTAssertEqual(CatalogStubProtocol.requests.count, 2)
        for request in CatalogStubProtocol.requests {
            XCTAssertFalse(request.url!.absoluteString.contains("AIza-secret"), "the key must not be in the URL")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-secret")
        }
        XCTAssertTrue(CatalogStubProtocol.requests[1].url!.absoluteString.contains("pageToken=p%202"))
    }

    // MARK: OpenRouter

    /// Trimmed from openrouter.ai/api/v1/models on 2026-10-14.
    private let openRouterBody = """
    {"data":[
        {"id":"anthropic/claude-haiku-5.5","name":"Anthropic: Claude Haiku 5.5",
         "supported_parameters":["reasoning","reasoning_effort","tools","structured_outputs"],
         "reasoning":{"mandatory":false,"supported_efforts":["max","xhigh","high","medium","low"],"default_effort":"medium"},
         "expiration_date":null},
        {"id":"anthropic/claude-haiku-5.5:batch","name":"batch","supported_parameters":["tools"]},
        {"id":"deepseek/deepseek-v4.1-flash","name":"DeepSeek V4.1 Flash","supported_parameters":["reasoning","tools"],
         "reasoning":{"supported_efforts":["max","high","low"]}},
        {"id":"xiaomi/mimo-v2.5","name":"MiMo V2.5","supported_parameters":["tools"],"expiration_date":"2026-10-21"},
        {"id":"some/vision-only","name":"No tools","supported_parameters":["max_tokens"]}
    ]}
    """

    func testOpenRouterKeepsToolCapableModelsWithTheirLevelsAndExpiry() throws {
        let entries = Dictionary(uniqueKeysWithValues:
            try CoachModelCatalog.parseOpenRouter(Data(openRouterBody.utf8)).map { ($0.id, $0) })
        XCTAssertEqual(Set(entries.keys), ["anthropic/claude-haiku-5.5", "deepseek/deepseek-v4.1-flash", "xiaomi/mimo-v2.5"])
        XCTAssertEqual(entries["anthropic/claude-haiku-5.5"]?.reasoningEfforts, ReasoningEffort.lowToMax)
        XCTAssertEqual(entries["deepseek/deepseek-v4.1-flash"]?.reasoningEfforts, [.low, .high, .max])
        // No `reasoning` parameter at all: the model takes no effort hint.
        XCTAssertEqual(entries["xiaomi/mimo-v2.5"]?.reasoningEfforts, [])
        XCTAssertEqual(entries["xiaomi/mimo-v2.5"]?.expiresOn, "2026-10-21")
        XCTAssertNil(entries["anthropic/claude-haiku-5.5"]?.expiresOn)
    }

    func testOpenRouterUsesTheLiveLevelsForAModelOutsideThePresets() async throws {
        CatalogStubProtocol.handler = { _ in (200, self.openRouterBody) }
        let result = await CoachModelCatalog.fetch(.userOpenRouterKey, apiKey: "sk-or-test", session: session())
        XCTAssertNotNil(result.listing)
        XCTAssertEqual(CatalogStubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")

        var settings = CoachSettings()
        settings.providerMode = .userOpenRouterKey
        settings.model = "xiaomi/mimo-v2.5"
        settings.reasoningEffort = "high"
        XCTAssertEqual(settings.reasoningEffortOptions, [], "a model without reasoning hides the picker")
        XCTAssertNil(settings.resolvedReasoningEffort)

        settings.model = "some/unlisted-model"
        XCTAssertEqual(settings.reasoningEffortOptions, ReasoningEffort.common)
        XCTAssertEqual(settings.resolvedReasoningEffort, "high", "an unknown model passes the hint through")

        // Presets keep their own levels: DeepSeek has no `medium`.
        settings.model = OpenRouterModel.deepseek.rawValue
        settings.reasoningEffort = "medium"
        XCTAssertNil(settings.resolvedReasoningEffort)
    }

    // MARK: MiniMax

    func testMiniMaxListingReadsTheOpenAIEnvelope() throws {
        XCTAssertEqual(try CoachModelCatalog.parseIds(Data(#"{"data":[{"id":"MiniMax-M3"},{"id":"MiniMax-M2.1"}]}"#.utf8)).map(\.id),
                       ["MiniMax-M2.1", "MiniMax-M3"])
    }

    // MARK: Unlisted (retired) models

    func testAStoredModelTheListingOmitsIsFlaggedExceptAliasesAndSnapshots() throws {
        let openAI = CoachModelCatalog.Listing(
            entries: try CoachModelCatalog.parseOpenAI(Data(#"{"data":[{"id":"gpt-6.1-sol"}]}"#.utf8)), fetchedAt: Date())
        XCTAssertTrue(CoachModelCatalog.isUnlisted(.userOpenAIKey, listing: openAI, model: "gpt-5.4"))
        XCTAssertFalse(CoachModelCatalog.isUnlisted(.userOpenAIKey, listing: openAI, model: "gpt-6.1-sol"))
        XCTAssertFalse(CoachModelCatalog.isUnlisted(.userOpenAIKey, listing: openAI, model: "gpt-6.1-sol-2026-09-30"))
        let gemini = listing(["gemini-3.8-flash"])
        XCTAssertFalse(CoachModelCatalog.isUnlisted(.userGeminiKey, listing: gemini, model: "gemini-flash-latest"))
        XCTAssertTrue(CoachModelCatalog.isUnlisted(.userGeminiKey, listing: gemini, model: "gemini-2.0-flash"))
    }

    func testMiniMaxPresetsAreNeverFlaggedARetiredFamilyIs() {
        let minimax = listing(["MiniMax-M3"])
        XCTAssertFalse(CoachModelCatalog.isUnlisted(.userMiniMaxKey, listing: minimax, model: "MiniMax-M2.1-highspeed"))
        XCTAssertTrue(CoachModelCatalog.isUnlisted(.userMiniMaxKey, listing: minimax, model: "MiniMax-M2.7"))
    }

    // MARK: Fetch, cache and failures

    func testListingIsCachedPerProviderAndKeyUntilForcedOrStale() async throws {
        CatalogStubProtocol.handler = { _ in (200, #"{"data":[{"id":"gpt-6.1-sol"}]}"#) }
        _ = await CoachModelCatalog.fetch(.userOpenAIKey, apiKey: "sk-a", session: session())
        _ = await CoachModelCatalog.fetch(.userOpenAIKey, apiKey: "sk-a", session: session())
        XCTAssertEqual(CatalogStubProtocol.requests.count, 1, "a fresh listing is served from the cache")

        _ = await CoachModelCatalog.fetch(.userOpenAIKey, apiKey: "sk-b", session: session())
        XCTAssertEqual(CatalogStubProtocol.requests.count, 2, "a different key misses the cache")

        _ = await CoachModelCatalog.fetch(.userOpenAIKey, apiKey: "sk-b", force: true, session: session())
        XCTAssertEqual(CatalogStubProtocol.requests.count, 3, "Refresh refetches")

        XCTAssertNotNil(CoachModelCatalog.cached(.userOpenAIKey, apiKey: "sk-b"))
        XCTAssertNil(CoachModelCatalog.cached(.userOpenAIKey, apiKey: "sk-b", now: Date().addingTimeInterval(6 * 3600 + 1)))
        XCTAssertNil(CoachModelCatalog.cached(.userGeminiKey, apiKey: "sk-b"))
    }

    func testFailuresComeBackAsUserFacingText() async {
        CatalogStubProtocol.handler = { _ in (401, #"{"error":"bad key"}"#) }
        guard case .failure(let rejected) = await CoachModelCatalog.fetch(.userOpenAIKey, apiKey: "sk-x", session: session()) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(rejected, "The provider rejected the key (HTTP 401).")

        CatalogStubProtocol.handler = { _ in (200, #"{"data":[{"id":"text-embedding-4-large"}]}"#) }
        guard case .failure(let empty) = await CoachModelCatalog.fetch(.userOpenAIKey, apiKey: "sk-x", session: session()) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(empty, "The provider listed no usable models.")

        guard case .failure(let noKey) = await CoachModelCatalog.fetch(.userMiniMaxKey, apiKey: "  ", session: session()) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(noKey, "Save an API key to load the model list.")
        XCTAssertFalse(CoachModelCatalog.supports(.localOpenAICompat))
    }
}
