import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// WS2 — chat transparency: persisted tool-call metadata (label/status/sequence)
/// and the workout ids a turn logs (`TurnResult.loggedActivityIds`).
@MainActor
final class CoachTransparencyTests: XCTestCase {

    private func writeFlags() -> CoachFeatureFlags {
        var s = TestSupport.enabledCoachSettings()
        s.enableWriteTools = true
        return CoachFeatureFlags(settings: s, hasAPIKey: true)
    }

    private func packet(_ c: ModelContext) -> CoachContextPacket { CoachContextBuilder.build(context: c) }

    private func finalJSON() -> String {
        """
        {"response_type":"insight","title":"Done","summary":"Logged it.","bullets":[],\
        "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
        "follow_up_chips":[],"actions_taken":[],"confidence":"high"}
        """
    }

    // MARK: persistTrace writes label / status / sequence

    func testPersistTraceWritesLabelStatusSequence() throws {
        let c = try TestSupport.makeContext()
        let vm = CoachViewModel()
        let convoId = UUID()
        let messageId = UUID()
        let now = Date()

        let trace = [
            CoachToolCallTrace(toolName: "get_daily_summary", label: "Got HR data", status: "success",
                               argsRedacted: "{}", resultSummary: "hr, steps", startedAt: now, finishedAt: now),
            CoachToolCallTrace(toolName: "make_chart", label: "Drew chart", status: "error",
                               argsRedacted: "{}", resultSummary: "error: boom", startedAt: now, finishedAt: now),
        ]
        vm.persistTrace(trace, messageId: messageId, conversationId: convoId, context: c)
        try c.save()

        let saved = try c.fetch(FetchDescriptor<CoachToolCall>(
            sortBy: [SortDescriptor(\.sequence, order: .forward)]))
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved[0].label, "Got HR data")
        XCTAssertEqual(saved[0].statusRaw, "success")
        XCTAssertEqual(saved[0].sequence, 0)
        XCTAssertEqual(saved[1].label, "Drew chart")
        XCTAssertEqual(saved[1].statusRaw, "error")
        XCTAssertEqual(saved[1].sequence, 1)
        XCTAssertTrue(saved.allSatisfy { $0.messageId == messageId })
    }

    // MARK: TurnResult.loggedActivityIds populated by create tool

    func testCreateActivityPopulatesLoggedActivityIds() async throws {
        let c = try TestSupport.makeContext()
        let flags = writeFlags()
        let today = CoachDataAccess.localDateString(Date())
        let createArgs = #"{"activity_type":"run","date":"\#(today)","start_time":null,"duration_min":30,"distance_km":5,"notes":"","confidence":"high"}"#
        let stub = StubResponsesClient([
            OpenAIResponse(id: "r1", outputItems: [
                .functionCall(.init(name: "create_activity_session_from_description", callID: "c1", arguments: createArgs))]),
            OpenAIResponse(id: "r2", outputItems: [.message(text: finalJSON())]),
        ])
        let o = CoachOrchestrator(client: stub, registry: ToolRegistry(flags: flags), flags: flags,
                                  toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await o.runTurn(userText: "log a 30 min run today", packet: packet(c), recentMessages: [])

        XCTAssertEqual(result.loggedActivityIds.count, 1)
        let sessions = ActivityRepository.sessions(context: c)
        XCTAssertEqual(result.loggedActivityIds.first, sessions.first?.id)
    }

    // MARK: TurnResult.loggedActivityIds populated by an immediate (today) update

    func testUpdateTodaySessionPopulatesLoggedActivityIds() async throws {
        let c = try TestSupport.makeContext()
        let flags = writeFlags()
        let session = ActivitySession(type: "run", status: .finished, startedAt: Date(), endedAt: Date())
        c.insert(session)
        try c.save()

        let updateArgs = #"{"activity_id":"\#(session.id.uuidString)","type":"cycle","notes":null,"distance_km":null,"duration_min":null,"perceived_effort":null,"start_time":null,"reason":"fix"}"#
        let stub = StubResponsesClient([
            OpenAIResponse(id: "r1", outputItems: [
                .functionCall(.init(name: "update_activity_session", callID: "c1", arguments: updateArgs))]),
            OpenAIResponse(id: "r2", outputItems: [.message(text: finalJSON())]),
        ])
        let o = CoachOrchestrator(client: stub, registry: ToolRegistry(flags: flags), flags: flags,
                                  toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await o.runTurn(userText: "change today's run to a ride", packet: packet(c), recentMessages: [])

        XCTAssertEqual(result.loggedActivityIds, [session.id])
    }

    // MARK: an old-session update stays a pending confirmation, not a logged id

    func testUpdateOldSessionDoesNotLogActivityId() async throws {
        let c = try TestSupport.makeContext()
        let flags = writeFlags()
        let session = ActivitySession(type: "run", status: .finished, startedAt: TestSupport.day(-5), endedAt: TestSupport.day(-5))
        c.insert(session)
        try c.save()

        let updateArgs = #"{"activity_id":"\#(session.id.uuidString)","type":"cycle","notes":null,"distance_km":null,"duration_min":null,"perceived_effort":null,"start_time":null,"reason":"fix"}"#
        let stub = StubResponsesClient([
            OpenAIResponse(id: "r1", outputItems: [
                .functionCall(.init(name: "update_activity_session", callID: "c1", arguments: updateArgs))]),
            OpenAIResponse(id: "r2", outputItems: [.message(text: finalJSON())]),
        ])
        let o = CoachOrchestrator(client: stub, registry: ToolRegistry(flags: flags), flags: flags,
                                  toolContext: ToolExecutionContext(modelContext: c, flags: flags))
        let result = await o.runTurn(userText: "fix that old run", packet: packet(c), recentMessages: [])

        XCTAssertTrue(result.loggedActivityIds.isEmpty)
        XCTAssertEqual(result.pendingActions.first?.kind, .updateActivitySession)
    }

    // MARK: encodeActivityIds round-trips (and stays nil for the empty case)

    func testEncodeActivityIdsRoundTrips() throws {
        XCTAssertNil(CoachViewModel.encodeActivityIds([]))
        let ids = [UUID(), UUID()]
        let json = try XCTUnwrap(CoachViewModel.encodeActivityIds(ids))
        let decoded = try JSONDecoder().decode([UUID].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, ids)
    }
}
