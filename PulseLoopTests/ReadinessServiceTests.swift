import XCTest
import SwiftData
@testable import PulseLoop

/// Storage-side readiness tests: overnight windowing, baseline windows, upsert/throttle behaviour,
/// and backfill. The scoring maths itself is covered by `ReadinessScoreTests`.
///
/// Anchored to a fixed reference date rather than `Date()` so a run at 23:59 can't straddle
/// midnight and produce a different day's window than a run at noon.
@MainActor
final class ReadinessServiceTests: XCTestCase {

    /// 2026-03-15 12:00 local — midday, so every ±hours offset stays inside its intended day.
    private let reference: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        components.hour = 12
        return Calendar.current.date(from: components) ?? Date()
    }()

    private var calendar: Calendar { Calendar.current }
    private var savedPrefs: ReadinessPrefs?

    override func setUp() async throws {
        try await super.setUp()
        // `refreshIfStale` and `backfill` are gated on the master toggle, which lives in a shared
        // UserDefaults-backed singleton. Pin it on, and restore whatever was there afterwards.
        savedPrefs = ReadinessPrefsStore.shared.prefs
        var prefs = ReadinessPrefs.default
        prefs.masterEnabled = true
        ReadinessPrefsStore.shared.prefs = prefs
    }

    override func tearDown() async throws {
        if let savedPrefs { ReadinessPrefsStore.shared.prefs = savedPrefs }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference))
            ?? reference
    }

    /// A time on the morning of `day`, or the evening before when `hour` is negative.
    private func at(_ hour: Int, _ dayOffset: Int, minute: Int = 0) -> Date {
        let base = day(dayOffset)
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: base) ?? base
    }

    /// A night belonging to the morning of `dayOffset`: 23:00 the previous evening → +`minutes`.
    /// Stage blocks are aggregated (one per stage) rather than per-minute, so a 30-day backfill
    /// doesn't insert fifteen thousand rows.
    @discardableResult
    private func insertNight(
        _ dayOffset: Int,
        minutes: Int = 450,
        deep: Int = 90,
        light: Int = 320,
        awake: Int = 40,
        into context: ModelContext
    ) -> SleepSession {
        let start = at(-1, dayOffset)   // 23:00 the evening before
        let end = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        let session = SleepSession(
            date: day(dayOffset), startAt: start, endAt: end,
            totalMinutes: minutes, syncedAt: start
        )
        context.insert(session)
        var cursor = 0
        for (stage, duration) in [(SleepStage.deep, deep), (.light, light), (.awake, awake)] where duration > 0 {
            let blockStart = calendar.date(byAdding: .minute, value: cursor, to: start) ?? start
            context.insert(SleepStageBlock(
                sessionId: session.id, startAt: blockStart,
                startMinute: cursor, durationMinutes: duration, stage: stage
            ))
            cursor += duration
        }
        try? context.save()
        return session
    }

    /// Heart-rate readings spread across the night of `dayOffset`.
    private func insertOvernightHR(_ dayOffset: Int, values: [Double], into context: ModelContext) {
        for (index, value) in values.enumerated() {
            let ts = calendar.date(byAdding: .minute, value: index * 30, to: at(-1, dayOffset)) ?? reference
            TestSupport.insertMeasurement(kind: .heartRate, value: value, timestamp: ts, into: context)
        }
    }

    private func setRestingBaseline(_ bpm: Double, into context: ModelContext) {
        let profile = UserProfile()
        profile.hrRestingBaseline = bpm
        context.insert(profile)
        try? context.save()
    }

    /// The cheapest fully scoreable morning: sleep (30 pts) + resting HR (25 pts) = 55 available,
    /// which clears `minAvailablePoints` without needing a 30-day HRV baseline.
    private func seedScoreableDay(_ dayOffset: Int, into context: ModelContext) {
        insertNight(dayOffset, into: context)
        insertOvernightHR(dayOffset, values: [58, 56, 55, 57, 59], into: context)
    }

    // MARK: - Overnight window

    func testOvernightWindowFollowsTheSleepSession() throws {
        let context = try TestSupport.makeContext()
        let session = insertNight(0, minutes: 450, into: context)

        let window = ReadinessService.overnightWindow(for: day(0), context: context)
        XCTAssertEqual(window.start, session.startAt)
        XCTAssertEqual(window.end, session.endAt)
    }

    func testFallbackWindowIsUsedWhenSleepWasNotDecoded() throws {
        let context = try TestSupport.makeContext()
        // No sleep session at all — a ring that captured vitals but failed the sleep decode.
        let window = ReadinessService.overnightWindow(for: day(0), context: context)
        XCTAssertEqual(window.start, at(-2, 0), "fallback should open at 22:00 the evening before")
        XCTAssertEqual(window.end, at(8, 0), "fallback should close at 08:00")

        insertOvernightHR(0, values: [58, 56, 55], into: context)
        setRestingBaseline(55, into: context)
        let inputs = ReadinessService.inputs(for: day(0), context: context)
        XCTAssertNotNil(inputs.restingHeartRate, "overnight HR must survive a missing sleep session")
    }

    /// Daytime readings describe what you were doing, not how you recovered. A low afternoon heart
    /// rate must not be allowed to masquerade as a good resting HR.
    func testDaytimeSamplesAreExcludedFromTheOvernightWindow() throws {
        let context = try TestSupport.makeContext()
        insertNight(0, into: context)
        insertOvernightHR(0, values: [58, 56, 55, 57, 59], into: context)
        // A much lower reading at 14:00, well outside the night's window.
        TestSupport.insertMeasurement(kind: .heartRate, value: 40, timestamp: at(14, 0), into: context)
        setRestingBaseline(55, into: context)

        let inputs = ReadinessService.inputs(for: day(0), context: context)
        let resting = try XCTUnwrap(inputs.restingHeartRate)
        XCTAssertGreaterThan(resting, 50, "the 40 bpm afternoon reading leaked into the overnight p10")
        XCTAssertLessThan(resting, 60)
    }

    // MARK: - Baselines

    func testHrvBaselineExcludesTheNightBeingScored() throws {
        let context = try TestSupport.makeContext()
        // 30 prior nights at a steady 50 ms — enough span and samples for `isEstablished`.
        for offset in 1...30 {
            insertNight(-offset, into: context)
            for index in 0..<3 {
                let ts = calendar.date(byAdding: .hour, value: index, to: at(-1, -offset)) ?? reference
                TestSupport.insertMeasurement(kind: .hrv, value: 50, timestamp: ts, into: context)
            }
        }
        // Tonight is wildly different; it must not pull its own baseline toward itself.
        insertNight(0, into: context)
        for index in 0..<3 {
            let ts = calendar.date(byAdding: .hour, value: index, to: at(-1, 0)) ?? reference
            TestSupport.insertMeasurement(kind: .hrv, value: 20, timestamp: ts, into: context)
        }

        let inputs = ReadinessService.inputs(for: day(0), context: context)
        XCTAssertEqual(try XCTUnwrap(inputs.hrv), 20, accuracy: 0.001)
        let baseline = try XCTUnwrap(inputs.hrvBaseline)
        XCTAssertTrue(baseline.isEstablished)
        XCTAssertEqual(baseline.median, 50, accuracy: 0.001, "tonight's 20 ms leaked into its own baseline")
    }

    func testUnestablishedBaselineWritesNoRow() throws {
        let context = try TestSupport.makeContext()
        // Only three nights of HRV — far short of the establishment gate, and no resting baseline.
        for offset in 0...2 {
            insertNight(-offset, into: context)
            TestSupport.insertMeasurement(kind: .hrv, value: 50, timestamp: at(-1, -offset), into: context)
        }
        let outcome = ReadinessService.refresh(day: day(0), context: context, now: reference)
        XCTAssertEqual(outcome, .unavailable(.baselineLearning))
        XCTAssertNil(ReadinessRepository.row(on: day(0), context: context))
    }

    // MARK: - Persistence

    func testRefreshUpsertsASingleRow() throws {
        let context = try TestSupport.makeContext()
        seedScoreableDay(0, into: context)
        setRestingBaseline(55, into: context)

        ReadinessService.refresh(day: day(0), context: context, now: reference)
        ReadinessService.refresh(day: day(0), context: context, now: reference.addingTimeInterval(60))

        let rows = try context.fetch(FetchDescriptor<ReadinessDaily>())
        XCTAssertEqual(rows.count, 1, "a second refresh must update the row, not insert another")
        XCTAssertEqual(rows.first?.algorithmVersion, ReadinessScore.algorithmVersion)
        XCTAssertFalse(rows.first?.contributors.isEmpty ?? true, "the breakdown must round-trip")
    }

    func testStoredContributorsRoundTrip() throws {
        let context = try TestSupport.makeContext()
        seedScoreableDay(0, into: context)
        setRestingBaseline(55, into: context)
        ReadinessService.refresh(day: day(0), context: context, now: reference)

        let row = try XCTUnwrap(ReadinessRepository.row(on: day(0), context: context))
        let kinds = Set(row.contributors.compactMap(\.kind))
        XCTAssertEqual(kinds, [.sleep, .restingHeartRate])
        XCTAssertEqual(row.availablePoints, 55)
        XCTAssertEqual(row.coverage, 0.55, accuracy: 0.0001)
        for record in row.contributors {
            XCTAssertFalse(record.detail.isEmpty)
        }
    }

    func testThrottleSkipsAFreshRow() throws {
        let context = try TestSupport.makeContext()
        seedScoreableDay(0, into: context)
        setRestingBaseline(55, into: context)
        ReadinessService.refresh(day: day(0), context: context, now: reference)
        let computedAt = try XCTUnwrap(ReadinessRepository.row(on: day(0), context: context)).computedAt

        // One hour later — inside the 3h throttle.
        ReadinessService.refreshIfStale(context: context, now: reference.addingTimeInterval(3600))
        XCTAssertEqual(try XCTUnwrap(ReadinessRepository.row(on: day(0), context: context)).computedAt, computedAt)

        // Four hours later — past it.
        ReadinessService.refreshIfStale(context: context, now: reference.addingTimeInterval(4 * 3600))
        XCTAssertNotEqual(try XCTUnwrap(ReadinessRepository.row(on: day(0), context: context)).computedAt, computedAt)
    }

    /// A version bump must beat the throttle, or old scores would linger under new weights.
    func testAlgorithmVersionMismatchForcesRecomputeInsideTheThrottle() throws {
        let context = try TestSupport.makeContext()
        seedScoreableDay(0, into: context)
        setRestingBaseline(55, into: context)
        ReadinessService.refresh(day: day(0), context: context, now: reference)

        let row = try XCTUnwrap(ReadinessRepository.row(on: day(0), context: context))
        row.algorithmVersion = ReadinessScore.algorithmVersion - 1
        try? context.save()

        ReadinessService.refreshIfStale(context: context, now: reference.addingTimeInterval(60))
        let refreshed = try XCTUnwrap(ReadinessRepository.row(on: day(0), context: context))
        XCTAssertEqual(refreshed.algorithmVersion, ReadinessScore.algorithmVersion)
    }

    /// If a night's sleep is corrected away, yesterday's score must not stay on screen.
    func testRefreshDeletesTheRowWhenTheOutcomeBecomesUnavailable() throws {
        let context = try TestSupport.makeContext()
        let session = insertNight(0, into: context)
        insertOvernightHR(0, values: [58, 56, 55], into: context)
        setRestingBaseline(55, into: context)
        ReadinessService.refresh(day: day(0), context: context, now: reference)
        XCTAssertNotNil(ReadinessRepository.row(on: day(0), context: context))

        // Delete the night and every overnight reading — nothing left to score.
        context.delete(session)
        for row in try context.fetch(FetchDescriptor<PulseLoop.Measurement>()) {
            context.delete(row)
        }
        try? context.save()

        let outcome = ReadinessService.refresh(day: day(0), context: context, now: reference)
        XCTAssertEqual(outcome, .unavailable(.noSignals))
        XCTAssertNil(ReadinessRepository.row(on: day(0), context: context),
                     "a stale score must be cleared, not left behind")
    }

    // MARK: - Backfill

    func testBackfillScoresOnlyDaysWithDataAndIsIdempotent() throws {
        let context = try TestSupport.makeContext()
        setRestingBaseline(55, into: context)
        for offset in [0, -1, -3] {
            seedScoreableDay(offset, into: context)
        }

        ReadinessService.backfill(days: 7, context: context, now: reference)
        let first = try context.fetch(FetchDescriptor<ReadinessDaily>())
        XCTAssertEqual(first.count, 3, "days with no night must not get a row")
        let stamps = first.map(\.computedAt)

        ReadinessService.backfill(days: 7, context: context, now: reference.addingTimeInterval(600))
        let second = try context.fetch(FetchDescriptor<ReadinessDaily>())
        XCTAssertEqual(second.count, 3, "a second backfill must not duplicate rows")
        XCTAssertEqual(second.map(\.computedAt).sorted(), stamps.sorted(),
                       "rows already at the current version must be skipped, not rewritten")
    }

    func testMasterToggleOffSkipsComputationEntirely() throws {
        let context = try TestSupport.makeContext()
        seedScoreableDay(0, into: context)
        setRestingBaseline(55, into: context)

        var prefs = ReadinessPrefs.default
        prefs.masterEnabled = false
        ReadinessPrefsStore.shared.prefs = prefs

        ReadinessService.refreshIfStale(context: context, now: reference)
        ReadinessService.backfill(days: 7, context: context, now: reference)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ReadinessDaily>()).isEmpty)
    }

    // MARK: - Training load

    /// A tracked run usually also generates active minutes. Summing them would double-count the
    /// same hour of effort, so the day's load is the larger of the two, never their sum.
    func testLoadMinutesTakesTheMaxNotTheSum() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertActivity(date: day(-1), activeMinutes: 45, into: context)
        let session = ActivitySession(type: "run", status: .finished, startedAt: at(9, -1))
        session.endedAt = calendar.date(byAdding: .minute, value: 30, to: at(9, -1))
        context.insert(session)
        try? context.save()

        let load = try XCTUnwrap(ReadinessService.loadMinutes(on: day(-1), context: context))
        XCTAssertEqual(load, 45, accuracy: 0.001, "expected max(45, 30), not 75")
    }

    func testLoadMinutesSubtractsPausedTime() throws {
        let context = try TestSupport.makeContext()
        let session = ActivitySession(type: "run", status: .finished, startedAt: at(9, -1))
        session.endedAt = calendar.date(byAdding: .minute, value: 60, to: at(9, -1))
        session.totalPauseSeconds = 600   // 10 minutes paused
        context.insert(session)
        try? context.save()

        let load = try XCTUnwrap(ReadinessService.loadMinutes(on: day(-1), context: context))
        XCTAssertEqual(load, 50, accuracy: 0.001)
    }

    func testLoadBaselineNeedsEnoughDaysBeforeItIsTrusted() throws {
        let context = try TestSupport.makeContext()
        // Three days of history — below `minLoadBaselineDays`.
        for offset in 2...4 {
            TestSupport.insertActivity(date: day(-offset), activeMinutes: 40, into: context)
        }
        XCTAssertNil(ReadinessService.loadBaseline(before: day(-1), context: context))

        TestSupport.insertActivity(date: day(-5), activeMinutes: 40, into: context)
        let baseline = try XCTUnwrap(ReadinessService.loadBaseline(before: day(-1), context: context))
        XCTAssertEqual(baseline, 40, accuracy: 0.001)
    }

    func testLoadBaselineExcludesTheDayBeingJudged() throws {
        let context = try TestSupport.makeContext()
        // A huge spike on the day itself, steady history before it.
        TestSupport.insertActivity(date: day(-1), activeMinutes: 300, into: context)
        for offset in 2...6 {
            TestSupport.insertActivity(date: day(-offset), activeMinutes: 40, into: context)
        }
        let baseline = try XCTUnwrap(ReadinessService.loadBaseline(before: day(-1), context: context))
        XCTAssertEqual(baseline, 40, accuracy: 0.001, "the spike day leaked into its own baseline")
    }

    // MARK: - Demo data

    /// The seeded demo store must produce a real readiness history, or the tile and its trend chart
    /// are empty for anyone evaluating the app without a ring (`-seedDemo YES`).
    func testDemoSeedProducesReadinessHistory() throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context)
        let rows = try context.fetch(FetchDescriptor<ReadinessDaily>())
        XCTAssertGreaterThan(rows.count, 5, "demo data produced too little readiness history to chart")
        // A spread, not a flat line — the demo store should exercise more than one band.
        XCTAssertGreaterThan(Set(rows.map(\.band)).count, 1)
        for row in rows {
            XCTAssertTrue((0...100).contains(row.score))
            XCTAssertFalse(row.contributors.isEmpty, "a seeded score must carry its breakdown")
        }
    }
}
