import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// A valid coach_response JSON body (mirrors the one in CoachTests) so a stubbed
/// final turn parses. Duplicated here to keep this file self-contained.
private func usageFinalJSON() -> String {
    """
    {"response_type":"insight","title":"Today","summary":"You did well.","bullets":["A","B"],\
    "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
    "follow_up_chips":["More"],"actions_taken":[],"confidence":"high"}
    """
}

// MARK: - Usage summation across a turn

@MainActor
final class CoachUsageTallyTests: XCTestCase {
    private func packet(_ c: ModelContext) -> CoachContextPacket { CoachContextBuilder.build(context: c) }

    /// A multi-call tool-loop turn must sum usage across every model call: the
    /// initial tool-call send + the final send that returns the answer.
    func testUsageSummedAcrossToolLoopTurn() async throws {
        let c = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 8200, into: c)
        let today = CoachDataAccess.localDateString(Date())
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)

        // Two model calls, each reporting usage (including a cached-input hit).
        let call1 = OpenAIResponse(
            id: "r1",
            outputItems: [.functionCall(.init(name: "get_daily_summary", callID: "c1", arguments: #"{"date":"\#(today)"}"#))],
            usage: CoachTokenUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 10))
        let call2 = OpenAIResponse(
            id: "r2",
            outputItems: [.message(text: usageFinalJSON())],
            usage: CoachTokenUsage(inputTokens: 200, outputTokens: 40, cachedInputTokens: 30))
        let stub = StubResponsesClient([call1, call2])

        let o = CoachOrchestrator(client: stub, registry: ToolRegistry(flags: flags), flags: flags,
                                  toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await o.runTurn(userText: "today?", packet: packet(c), recentMessages: [])

        let usage = try XCTUnwrap(result.usage)
        XCTAssertEqual(usage.inputTokens, 300)        // 100 + 200
        XCTAssertEqual(usage.outputTokens, 60)         // 20 + 40
        XCTAssertEqual(usage.cachedInputTokens, 40)    // 10 + 30
    }

    /// A turn whose calls report no usage (e.g. on-device) leaves `usage` nil.
    func testNilUsageWhenNoCallReports() async throws {
        let c = try TestSupport.makeContext()
        let flags = CoachFeatureFlags(settings: TestSupport.enabledCoachSettings(), hasAPIKey: true)
        let stub = StubResponsesClient([OpenAIResponse(id: "r1", outputItems: [.message(text: usageFinalJSON())])])
        let o = CoachOrchestrator(client: stub, registry: ToolRegistry(flags: flags), flags: flags,
                                  toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await o.runTurn(userText: "hi", packet: packet(c), recentMessages: [])
        XCTAssertNil(result.usage)
    }
}

// MARK: - OpenAIResponse.parse usage fixture

final class OpenAIResponseUsageParseTests: XCTestCase {
    func testParsesUsageBlock() throws {
        let data = Data("""
        {"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}],
         "usage":{"input_tokens":1234,"output_tokens":567,"input_tokens_details":{"cached_tokens":800}}}
        """.utf8)
        let response = try OpenAIResponse.parse(data)
        let usage = try XCTUnwrap(response.usage)
        XCTAssertEqual(usage.inputTokens, 1234)
        XCTAssertEqual(usage.outputTokens, 567)
        XCTAssertEqual(usage.cachedInputTokens, 800)
        XCTAssertNil(usage.reportedCostUSD)
    }

    func testNoUsageBlockLeavesNil() throws {
        let data = Data(#"{"id":"resp_2","output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}]}"#.utf8)
        let response = try OpenAIResponse.parse(data)
        XCTAssertNil(response.usage)
    }
}

// MARK: - Pricing catalog lookup

final class CoachPricingCatalogTests: XCTestCase {
    /// 1M input tokens (no cache) prices at exactly the catalog's input rate.
    func testExactMatchUsesCatalogRate() throws {
        let price = try XCTUnwrap(CoachPricingCatalog.price(for: "gpt-5.4"))
        let cost = try XCTUnwrap(CoachPricingCatalog.cost(
            model: "gpt-5.4", usage: CoachTokenUsage(inputTokens: 1_000_000, outputTokens: 0)))
        XCTAssertEqual(cost, price.inputPer1M, accuracy: 1e-9)
    }

    /// A Custom slug that isn't an exact key prices off its longest matching prefix.
    func testLongestPrefixFallback() throws {
        let base = try XCTUnwrap(CoachPricingCatalog.price(for: "openai/gpt-5.5"))
        let variant = try XCTUnwrap(CoachPricingCatalog.price(for: "openai/gpt-5.5-preview"))
        XCTAssertEqual(variant, base)
    }

    /// The `:online` web-search suffix is stripped before lookup.
    func testOnlineSuffixStripped() throws {
        let plain = try XCTUnwrap(CoachPricingCatalog.price(for: "anthropic/claude-sonnet-4.6"))
        let online = try XCTUnwrap(CoachPricingCatalog.price(for: "anthropic/claude-sonnet-4.6:online"))
        XCTAssertEqual(online, plain)
    }

    /// An unknown free-form model returns nil (UI shows "cost unavailable").
    func testUnknownModelReturnsNil() {
        XCTAssertNil(CoachPricingCatalog.price(for: "totally-made-up/model-x"))
        XCTAssertNil(CoachPricingCatalog.cost(
            model: "totally-made-up/model-x", usage: CoachTokenUsage(inputTokens: 1000, outputTokens: 100)))
    }

    /// On-device / offline models always cost $0.
    func testOnDeviceIsZero() throws {
        let cost = try XCTUnwrap(CoachPricingCatalog.cost(
            model: "apple-on-device", usage: CoachTokenUsage(inputTokens: 5000, outputTokens: 500)))
        XCTAssertEqual(cost, 0, accuracy: 1e-12)
        let offline = try XCTUnwrap(CoachPricingCatalog.cost(
            model: "offline-stub", usage: CoachTokenUsage(inputTokens: 5000, outputTokens: 500)))
        XCTAssertEqual(offline, 0, accuracy: 1e-12)
    }

    /// Cached input bills at the (cheaper) cached rate; the cost formula combines
    /// uncached input + cached input + output. Asserted via the catalog's own
    /// rates so the check survives a later real-pricing fill.
    func testCachedInputUsesCachedRate() throws {
        let model = "gpt-5.4"
        let price = try XCTUnwrap(CoachPricingCatalog.price(for: model))
        let usage = CoachTokenUsage(inputTokens: 1_000_000, outputTokens: 500_000, cachedInputTokens: 400_000)
        let expected = (600_000 * price.inputPer1M
            + 400_000 * (price.cachedInputPer1M ?? price.inputPer1M)
            + 500_000 * price.outputPer1M) / 1_000_000
        let cost = try XCTUnwrap(CoachPricingCatalog.cost(model: model, usage: usage))
        XCTAssertEqual(cost, expected, accuracy: 1e-9)
    }
}

// MARK: - Compact context builder limits

@MainActor
final class CoachContextBudgetTests: XCTestCase {
    func testCompactBudgetLimitsPacketContents() throws {
        let c = try TestSupport.makeContext()
        let now = Date()

        // 5 memories (compact keeps ≤3), 4 finished workouts (compact keeps ≤2).
        for i in 0..<5 {
            c.insert(CoachMemory(key: "k\(i)", value: String(repeating: "x", count: 300), importance: 5 - i))
        }
        for i in 0..<4 {
            let start = now.addingTimeInterval(Double(-i) * 3600)
            c.insert(ActivitySession(
                type: "run", status: .finished, startedAt: start, endedAt: start.addingTimeInterval(1800)))
        }
        try? c.save()

        let compact = CoachContextBuilder.build(context: c, now: now, budget: .compact)
        XCTAssertLessThanOrEqual(compact.memories.count, 3)
        XCTAssertLessThanOrEqual(compact.recentWorkouts.count, 2)
        XCTAssertLessThanOrEqual(compact.dataQualityWarnings.count, 2)
        // Long memory values are truncated under the compact value cap (120 chars).
        for memory in compact.memories {
            XCTAssertLessThanOrEqual(memory.value.count, 121)  // 120 + ellipsis
        }

        // Full budget keeps more.
        let full = CoachContextBuilder.build(context: c, now: now, budget: .full)
        XCTAssertGreaterThan(full.memories.count, compact.memories.count)
    }

    func testCompactBudgetCapsConversationSummary() throws {
        let c = try TestSupport.makeContext()
        let long = String(repeating: "summary ", count: 200)  // >400 chars
        let compact = CoachContextBuilder.build(context: c, conversationSummary: long, budget: .compact)
        XCTAssertLessThanOrEqual((compact.conversationSummary ?? "").count, 401)  // 400 + ellipsis
    }
}
