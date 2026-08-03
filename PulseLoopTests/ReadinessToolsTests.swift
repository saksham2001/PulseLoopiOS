import XCTest
import SwiftData
@testable import PulseLoop

/// The `get_readiness` coach tool and the readiness slice of the context packet.
///
/// The contributor breakdown is what these tests really guard. A tool that returned only a score
/// would leave the model to invent a reason for it, which is exactly the failure mode the whole
/// feature is designed to avoid.
@MainActor
final class ReadinessToolsTests: XCTestCase {

    private var savedPrefs: ReadinessPrefs?

    override func setUp() async throws {
        try await super.setUp()
        savedPrefs = ReadinessPrefsStore.shared.prefs
        ReadinessPrefsStore.shared.prefs = ReadinessPrefs.default   // on + shared
    }

    override func tearDown() async throws {
        if let savedPrefs { ReadinessPrefsStore.shared.prefs = savedPrefs }
        try await super.tearDown()
    }

    // MARK: - Harness

    private func flags(enabled: Bool = true, share: Bool = true) -> CoachFeatureFlags {
        var s = CoachSettings.default
        s.coachMasterEnabled = true
        var r = ReadinessPrefs.default
        r.masterEnabled = enabled
        r.shareWithCoach = share
        return CoachFeatureFlags(settings: s, hasAPIKey: true, readinessPrefs: r)
    }

    private func tool(_ name: String, enabled: Bool = true, share: Bool = true) throws -> AnyCoachTool {
        try XCTUnwrap(ToolRegistry(flags: flags(enabled: enabled, share: share)).tool(named: name))
    }

    private func ctx(_ c: ModelContext, enabled: Bool = true, share: Bool = true) -> ToolExecutionContext {
        ToolExecutionContext(modelContext: c, flags: flags(enabled: enabled, share: share))
    }

    private func parse(_ result: ToolResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any])
    }

    private let sampleContributors = #"""
    [{"kindRaw":"hrv","earned":18,"maxPoints":30,"value":44,"baseline":50,"deviation":-12,"detail":"HRV 12% below your baseline"},
     {"kindRaw":"sleep","earned":28,"maxPoints":30,"value":85,"detail":"Sleep score 85"},
     {"kindRaw":"restingHeartRate","earned":25,"maxPoints":25,"value":54,"baseline":55,"deviation":-1,"detail":"Resting HR at your baseline"}]
    """#

    @discardableResult
    private func insertScore(_ dayOffset: Int, score: Int = 74, into context: ModelContext) -> ReadinessDaily {
        let row = ReadinessDaily(
            date: TestSupport.day(dayOffset),
            score: score,
            band: ReadinessScore.band(score),
            availablePoints: 85,
            contributorsJSON: sampleContributors
        )
        context.insert(row)
        try? context.save()
        return row
    }

    private func isoDay(_ offset: Int) -> String {
        CoachDataAccess.localDateString(TestSupport.day(offset))
    }

    // MARK: - Registration

    func testToolIsRegisteredOnlyWhenSharedWithTheCoach() {
        XCTAssertNotNil(ToolRegistry(flags: flags()).tool(named: "get_readiness"))
        XCTAssertNil(ToolRegistry(flags: flags(enabled: false)).tool(named: "get_readiness"),
                     "feature off must remove the tool entirely")
        XCTAssertNil(ToolRegistry(flags: flags(share: false)).tool(named: "get_readiness"),
                     "sharing off must remove the tool entirely")
    }

    /// The tool is read-only on purpose: a readiness score is derived, so there is nothing for the
    /// model to write. Guard against a write tool appearing later by accident.
    func testThereIsNoReadinessWriteTool() {
        let registry = ToolRegistry(flags: flags())
        for name in ["set_readiness", "log_readiness", "update_readiness", "delete_readiness"] {
            XCTAssertNil(registry.tool(named: name))
        }
    }

    // MARK: - Payload

    func testReturnsScoresWithTheContributorBreakdown() async throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 74, into: context)

        let result = try await tool("get_readiness").run(
            Data(#"{"start_date":null,"end_date":null}"#.utf8), ctx(context)
        )
        XCTAssertFalse(result.isError)
        let json = try parse(result)
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 1)

        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day["score"] as? Int, 74)
        XCTAssertEqual(day["band"] as? String, "Ready")
        XCTAssertEqual(day["coverage"] as? Double ?? 0, 0.85, accuracy: 0.0001)

        let contributors = try XCTUnwrap(day["contributors"] as? [[String: Any]])
        XCTAssertEqual(contributors.count, 3)
        // Biggest drag first, so the model leads with the thing that actually mattered.
        XCTAssertEqual(contributors.first?["signal"] as? String, "hrv")
        XCTAssertEqual(contributors.first?["detail"] as? String, "HRV 12% below your baseline")
        XCTAssertEqual(json["algorithm_version"] as? Int, ReadinessScore.algorithmVersion)
    }

    /// Absent signals must be named. If the model can't tell "temperature was normal" from
    /// "temperature wasn't measured", it will confidently report the first when the second is true.
    func testNotMeasuredSignalsAreNamed() async throws {
        let context = try TestSupport.makeContext()
        insertScore(0, into: context)

        let result = try await tool("get_readiness").run(
            Data(#"{"start_date":null,"end_date":null}"#.utf8), ctx(context)
        )
        let days = try XCTUnwrap(try parse(result)["days"] as? [[String: Any]])
        let notMeasured = try XCTUnwrap(days.first?["not_measured"] as? [String])
        XCTAssertEqual(Set(notMeasured), ["skinTemperature", "trainingLoad"])
    }

    func testRespectsAnExplicitDateRange() async throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 80, into: context)
        insertScore(-2, score: 70, into: context)
        insertScore(-20, score: 60, into: context)

        let args = #"{"start_date":"\#(isoDay(-3))","end_date":"\#(isoDay(0))"}"#
        let result = try await tool("get_readiness").run(Data(args.utf8), ctx(context))
        let days = try XCTUnwrap(try parse(result)["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 2, "the 20-day-old score is outside the requested range")
        XCTAssertEqual(try parse(result)["average_score"] as? Int, 75)
    }

    /// The model occasionally swaps the bounds. Returning nothing would read as "no recovery data",
    /// which is a materially wrong answer, so a reversed range is normalized instead.
    func testReversedRangeIsNormalizedRatherThanReturningNothing() async throws {
        let context = try TestSupport.makeContext()
        insertScore(-1, score: 66, into: context)

        let args = #"{"start_date":"\#(isoDay(0))","end_date":"\#(isoDay(-3))"}"#
        let result = try await tool("get_readiness").run(Data(args.utf8), ctx(context))
        let days = try XCTUnwrap(try parse(result)["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 1)
    }

    /// An empty result must say so explicitly, or "no scores" reads as "bad recovery".
    func testEmptyRangeCarriesAnExplanatoryNote() async throws {
        let context = try TestSupport.makeContext()
        let result = try await tool("get_readiness").run(
            Data(#"{"start_date":null,"end_date":null}"#.utf8), ctx(context)
        )
        let json = try parse(result)
        XCTAssertEqual((json["days"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(json["average_score"] as? Int)
        let note = try XCTUnwrap(json["note"] as? String)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("no readiness scores"))
    }

    /// Belt and braces: even if the tool were somehow reachable with sharing off, it must refuse.
    func testToolRefusesWhenSharingIsOff() async throws {
        let context = try TestSupport.makeContext()
        insertScore(0, into: context)
        let result = try await tool("get_readiness").run(
            Data(#"{"start_date":null,"end_date":null}"#.utf8),
            ctx(context, share: false)
        )
        XCTAssertTrue(result.isError)
    }

    // MARK: - Context packet

    func testContextPacketCarriesReadinessWhenShared() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 74, into: context)

        let packet = CoachContextBuilder.build(context: context)
        let readiness = try XCTUnwrap(packet.readiness)
        XCTAssertEqual(readiness.score, 74)
        XCTAssertEqual(readiness.band, "Ready")
        XCTAssertEqual(readiness.contributors.first?.signal, "hrv")
        XCTAssertEqual(Set(readiness.notMeasured), ["skinTemperature", "trainingLoad"])
    }

    func testContextPacketOmitsReadinessWhenSharingIsOff() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, into: context)

        var prefs = ReadinessPrefs.default
        prefs.shareWithCoach = false
        ReadinessPrefsStore.shared.prefs = prefs

        XCTAssertNil(CoachContextBuilder.build(context: context).readiness)
    }

    func testContextPacketOmitsReadinessWhenTheCallerOptsOut() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, into: context)
        XCTAssertNil(CoachContextBuilder.build(context: context, includeReadiness: false).readiness)
    }

    /// Absent from the JSON entirely, not present-and-null — the model should see no readiness key
    /// at all rather than something it might try to reason about.
    func testReadinessIsAbsentFromEncodedJSONWhenNotShared() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, into: context)
        let packet = CoachContextBuilder.build(context: context, includeReadiness: false)
        let data = try JSONEncoder().encode(packet)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["readiness"])
    }
}
