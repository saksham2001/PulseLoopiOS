import XCTest
import SwiftData
@testable import PulseLoop

/// The view-model layer behind the pinned Today readiness card: summary plumbing, the
/// master-toggle gate, snapshot derivation, band agreement, and — most importantly — that `TodayStore`'s cheap
/// signature actually notices readiness changing.
///
/// The rendered card itself is not covered; this project has no UI test target.
@MainActor
final class ReadinessCardTests: XCTestCase {

    private var savedPrefs: ReadinessPrefs?

    /// HRV is 12 points down, sleep 2 — so HRV is unambiguously the top drag.
    private static let draggingContributors = #"""
    [{"kindRaw":"hrv","earned":18,"maxPoints":30,"value":44,"baseline":50,"deviation":-12,"detail":"HRV 12% below your baseline"},
     {"kindRaw":"sleep","earned":28,"maxPoints":30,"value":85,"detail":"Sleep score 85"}]
    """#

    /// Every contributor at full marks, so there is nothing for the card to blame.
    private static let perfectContributors = #"""
    [{"kindRaw":"sleep","earned":30,"maxPoints":30,"value":92,"detail":"Sleep score 92"},
     {"kindRaw":"restingHeartRate","earned":25,"maxPoints":25,"value":54,"baseline":55,"deviation":-1,"detail":"Resting HR at your baseline"}]
    """#

    override func setUp() async throws {
        try await super.setUp()
        savedPrefs = ReadinessPrefsStore.shared.prefs
        var prefs = ReadinessPrefs.default
        prefs.masterEnabled = true
        ReadinessPrefsStore.shared.prefs = prefs
    }

    override func tearDown() async throws {
        if let savedPrefs { ReadinessPrefsStore.shared.prefs = savedPrefs }
        try await super.tearDown()
    }

    @discardableResult
    private func insertScore(
        _ dayOffset: Int = 0,
        score: Int = 74,
        band: ReadinessBand = .ready,
        availablePoints: Double = 90,
        contributorsJSON: String = draggingContributors,
        into context: ModelContext
    ) -> ReadinessDaily {
        let row = ReadinessDaily(
            date: TestSupport.day(dayOffset),
            score: score, band: band,
            availablePoints: availablePoints,
            contributorsJSON: contributorsJSON
        )
        context.insert(row)
        try? context.save()
        return row
    }

    // MARK: - Summary plumbing

    func testTodaySummaryCarriesTheReadinessSnapshot() throws {
        let context = try TestSupport.makeContext()
        insertScore(into: context)

        let summary = MetricsService.buildTodaySummary(context: context, scope: .today)
        let readiness = try XCTUnwrap(summary.readiness, "buildTodaySummary should surface the day's score")
        XCTAssertEqual(readiness.score, 74)
        XCTAssertEqual(readiness.band, .ready)
        XCTAssertEqual(readiness.coverage, 0.9, accuracy: 0.0001)
    }

    func testMasterToggleOffKeepsReadinessOutOfTheSummary() throws {
        let context = try TestSupport.makeContext()
        insertScore(into: context)

        var prefs = ReadinessPrefs.default
        prefs.masterEnabled = false
        ReadinessPrefsStore.shared.prefs = prefs

        let summary = MetricsService.buildTodaySummary(context: context, scope: .today)
        XCTAssertNil(summary.readiness, "every consumer must inherit the master-toggle gate")
    }

    func testSummaryIsNilWhenTheDayWasNeverScored() throws {
        let context = try TestSupport.makeContext()
        let summary = MetricsService.buildTodaySummary(context: context, scope: .today)
        XCTAssertNil(summary.readiness)
    }

    // MARK: - Snapshot

    /// Drives the card's lead reason. Picking the wrong contributor would explain the score wrongly.
    func testTopDragIsTheContributorThatCostTheMostPoints() throws {
        let context = try TestSupport.makeContext()
        insertScore(into: context)
        let readiness = try XCTUnwrap(
            MetricsService.buildTodaySummary(context: context, scope: .today).readiness
        )
        let top = try XCTUnwrap(readiness.topDrag)
        XCTAssertEqual(top.kind, .hrv, "HRV lost 12 points; sleep lost 2")
        XCTAssertEqual(top.detail, "HRV 12% below your baseline")
    }

    /// A perfect night has nothing to blame, and the card must not invent something.
    func testTopDragIsNilWhenEveryContributorEarnedFullMarks() throws {
        let context = try TestSupport.makeContext()
        insertScore(
            score: 100, band: .primed, availablePoints: 60,
            contributorsJSON: Self.perfectContributors,
            into: context
        )
        let readiness = try XCTUnwrap(
            MetricsService.buildTodaySummary(context: context, scope: .today).readiness
        )
        XCTAssertNil(readiness.topDrag)
    }

    /// A row whose JSON is unreadable is still a usable score — the breakdown degrades, not the card.
    func testUnreadableContributorsDegradeToAnEmptyBreakdown() throws {
        let context = try TestSupport.makeContext()
        insertScore(contributorsJSON: "not json at all", into: context)
        let readiness = try XCTUnwrap(
            MetricsService.buildTodaySummary(context: context, scope: .today).readiness
        )
        XCTAssertEqual(readiness.score, 74, "the score must survive an unreadable breakdown")
        XCTAssertTrue(readiness.contributors.isEmpty)
        XCTAssertNil(readiness.topDrag)
    }

    // MARK: - TodayStore signature

    /// The signature is what decides whether the grid rebuilds. If readiness isn't in it, a new
    /// score lands in the database and the card keeps showing yesterday's until an unrelated sync
    /// happens to bump something else.
    func testStoreRebuildsWhenAScoreIsWritten() throws {
        let context = try TestSupport.makeContext()
        let store = TodayStore(modelContext: context)
        XCTAssertNil(store.summary.readiness)

        insertScore(score: 81, band: .ready, into: context)
        store.refreshIfNeeded()

        XCTAssertEqual(store.summary.readiness?.score, 81)
    }

    func testStoreRebuildsWhenTheScoreChanges() throws {
        let context = try TestSupport.makeContext()
        let row = insertScore(score: 60, band: .moderate, into: context)
        let store = TodayStore(modelContext: context)
        XCTAssertEqual(store.summary.readiness?.score, 60)

        row.score = 88
        row.bandRaw = ReadinessBand.primed.rawValue
        row.updatedAt = Date().addingTimeInterval(60)
        try? context.save()
        store.refreshIfNeeded()

        XCTAssertEqual(store.summary.readiness?.score, 88)
        XCTAssertEqual(store.summary.readiness?.band, .primed)
    }

    /// Toggling visibility in Settings must take effect on the tab immediately, not on next sync.
    func testStoreRebuildsWhenThePrefsToggleChanges() throws {
        let context = try TestSupport.makeContext()
        insertScore(into: context)
        let store = TodayStore(modelContext: context)
        XCTAssertNotNil(store.summary.readiness)

        var prefs = ReadinessPrefsStore.shared.prefs
        prefs.masterEnabled = false
        ReadinessPrefsStore.shared.prefs = prefs
        store.refreshIfNeeded()

        XCTAssertNil(store.summary.readiness)
    }

    // MARK: - Not a grid metric

    /// Readiness is a verdict over the other metrics, not a metric of its own, so it is pinned
    /// above the grid rather than living in it. Guard against it being reintroduced as a grid tile:
    /// that would make it reorderable and hideable via the tray, contradicting the pinning.
    func testReadinessIsNotAGridMetric() {
        XCTAssertNil(MetricKey(rawValue: "readiness"))
        XCTAssertFalse(MetricKey.allCases.contains { $0.rawValue == "readiness" })
    }

    // MARK: - Card bands

    /// The card's arc colouring must agree with `ReadinessScore.band`, or a score can be labelled
    /// "Ready" while being drawn in the amber "Moderate" band. The detail hero and the trend chart
    /// read the same zones, so this pins all three surfaces at once.
    func testZonesAgreeWithTheScoreBands() {
        let expected: [(Int, String)] = [
            (0, "Rest needed"), (54, "Rest needed"),
            (55, "Moderate"), (69, "Moderate"),
            (70, "Ready"), (84, "Ready"),
            (85, "Primed"), (100, "Primed")
        ]
        for (score, label) in expected {
            let zone = ReadinessZones.all.first { $0.contains(Double(score)) }
            XCTAssertEqual(zone?.label, label, "score \(score) fell in the wrong band")
            XCTAssertEqual(zone?.label, ReadinessScore.band(score).rawValue,
                           "tile band disagrees with ReadinessScore.band at \(score)")
        }
    }

    func testEveryTileZoneHasAnExplanation() {
        for zone in ReadinessZones.all {
            XCTAssertFalse(zone.explanation.isEmpty, "\(zone.label) has no explanation")
        }
    }
}
