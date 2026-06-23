import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

@MainActor
final class CoachActionTests: XCTestCase {

    private func writeFlags() -> CoachFeatureFlags {
        var s = CoachSettings.default
        s.enableWriteTools = true
        return CoachFeatureFlags(settings: s, hasAPIKey: true)
    }

    private func ctx(_ c: ModelContext) -> ToolExecutionContext {
        ToolExecutionContext(modelContext: c, flags: writeFlags())
    }

    private func tool(_ name: String, _ c: ModelContext) throws -> AnyCoachTool {
        try XCTUnwrap(ToolRegistry(flags: writeFlags()).tool(named: name))
    }

    private func parse(_ result: ToolResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any])
    }

    // MARK: set_goal

    func testSetGoalUpdatesUserGoal() async throws {
        let c = try TestSupport.makeContext()
        let result = try await tool("set_goal", c).run(Data(#"{"goal_type":"steps","target":12000,"reason":"more active"}"#.utf8), ctx(c))
        XCTAssertEqual((try parse(result))["ok"] as? Bool, true)
        let goal = try XCTUnwrap(MetricsRepository.goals(context: c))
        XCTAssertEqual(goal.steps, 12000)
    }

    // MARK: create session

    func testCreateSessionNeedsDurationThenCreates() async throws {
        let c = try TestSupport.makeContext()
        let t = try tool("create_activity_session_from_description", c)

        let noDur = try await t.run(Data(#"{"activity_type":"run","date":"2026-06-01","start_time":null,"duration_min":null,"distance_km":null,"notes":"","confidence":"medium"}"#.utf8), ctx(c))
        XCTAssertEqual((try parse(noDur))["needs_follow_up"] as? Bool, true)
        XCTAssertTrue(ActivityRepository.sessions(context: c).isEmpty)

        let created = try await t.run(Data(#"{"activity_type":"run","date":"2026-06-01","start_time":null,"duration_min":30,"distance_km":5,"notes":"morning","confidence":"high"}"#.utf8), ctx(c))
        XCTAssertEqual((try parse(created))["created"] as? Bool, true)
        let sessions = ActivityRepository.sessions(context: c)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.type, "run")
    }

    // MARK: log_user_note → typed memory

    func testLogUserNoteWritesTypedMemory() async throws {
        let c = try TestSupport.makeContext()
        _ = try await tool("log_user_note", c).run(Data(#"{"date":"2026-06-01","note_type":"symptom","content":"felt dizzy after lunch"}"#.utf8), ctx(c))
        let mems = (try? c.fetch(FetchDescriptor<CoachMemory>())) ?? []
        XCTAssertEqual(mems.count, 1)
        XCTAssertEqual(mems.first?.memoryType, "health_note")
        XCTAssertEqual(mems.first?.value, "felt dizzy after lunch")
    }

    // MARK: delete → confirmation card (no immediate delete)

    func testDeleteReturnsConfirmationAndExecutorDeletes() async throws {
        let c = try TestSupport.makeContext()
        let session = ActivitySession(type: "run", status: .finished, startedAt: TestSupport.day(-2), endedAt: TestSupport.day(-2))
        c.insert(session)
        try c.save()

        let context = ctx(c)
        let result = try await tool("delete_activity_session", c).run(Data(#"{"activity_id":"\#(session.id.uuidString)","reason":"duplicate"}"#.utf8), context)
        XCTAssertEqual((try parse(result))["needs_confirmation"] as? Bool, true)
        XCTAssertEqual(context.pendingActions.count, 1)
        // NOT deleted yet.
        XCTAssertEqual(ActivityRepository.sessions(context: c).count, 1)

        // Confirm → executor deletes.
        let action = try XCTUnwrap(context.pendingActions.first)
        _ = PendingActionExecutor.execute(action, context: c)
        XCTAssertTrue(ActivityRepository.sessions(context: c).isEmpty)
    }

    func testUpdateOldSessionRequiresConfirmation() async throws {
        let c = try TestSupport.makeContext()
        let session = ActivitySession(type: "run", status: .finished, startedAt: TestSupport.day(-5), endedAt: TestSupport.day(-5))
        c.insert(session)
        try c.save()
        let context = ctx(c)
        let json = #"{"activity_id":"\#(session.id.uuidString)","type":"cycle","notes":null,"distance_km":null,"duration_min":null,"perceived_effort":null,"start_time":null,"reason":"misclassified"}"#
        let result = try await tool("update_activity_session", c).run(Data(json.utf8), context)
        XCTAssertEqual((try parse(result))["needs_confirmation"] as? Bool, true)
        XCTAssertEqual(context.pendingActions.first?.kind, .updateActivitySession)
        XCTAssertEqual(session.type, "run")  // unchanged until confirmed
    }

    // MARK: gating

    func testWriteToolsHiddenWhenDisabled() {
        let readOnly = CoachFeatureFlags(settings: .default, hasAPIKey: true)  // writes off
        let names = Set(ToolRegistry(flags: readOnly).toolSpecs.compactMap { $0["name"] as? String })
        XCTAssertFalse(names.contains("set_goal"))
        XCTAssertFalse(names.contains("delete_activity_session"))
        XCTAssertFalse(names.contains("trigger_measurement"))
    }

    func testWriteToolsPresentWhenEnabled() {
        let names = Set(ToolRegistry(flags: writeFlags()).toolSpecs.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("set_goal"))
        XCTAssertTrue(names.contains("save_memory"))
        XCTAssertTrue(names.contains("delete_activity_session"))
        XCTAssertFalse(names.contains("trigger_measurement"))  // live still off
    }

    // MARK: memory retrieval (drop expired, rank by importance)

    func testContextMemoriesDropExpiredAndRankByImportance() throws {
        let c = try TestSupport.makeContext()
        c.insert(CoachMemory(key: "low", value: "v", memoryType: "note", importance: 1))
        c.insert(CoachMemory(key: "top", value: "v", memoryType: "goal", importance: 5))
        c.insert(CoachMemory(key: "gone", value: "v", memoryType: "note", importance: 4,
                             expiresAt: Date().addingTimeInterval(-3600)))
        try c.save()

        let packet = CoachContextBuilder.build(context: c)
        let keys = packet.memories.map(\.key)
        XCTAssertFalse(keys.contains("gone"))      // expired dropped
        XCTAssertEqual(keys.first, "top")          // importance-ranked
    }
}

@MainActor
final class CoachChartDomainTests: XCTestCase {
    func testTrendLineAutoscalesAwayFromZero() {
        let d = CoachChartView.yDomain(values: [70, 72, 75, 71], chartType: .line, metric: .hr)
        XCTAssertGreaterThan(d.lowerBound, 50)  // not anchored at 0
        XCTAssertLessThan(d.lowerBound, 70)
        XCTAssertGreaterThan(d.upperBound, 75)
    }

    func testMagnitudeBarStartsAtZero() {
        let d = CoachChartView.yDomain(values: [4000, 8000, 12000], chartType: .bar, metric: .steps)
        XCTAssertEqual(d.lowerBound, 0)
        XCTAssertGreaterThan(d.upperBound, 12000)
    }

    func testSpO2ClampedTo100() {
        let d = CoachChartView.yDomain(values: [96, 98, 99], chartType: .dot, metric: .spo2)
        XCTAssertLessThanOrEqual(d.upperBound, 100)
        XCTAssertLessThan(d.lowerBound, 96)
    }
}
