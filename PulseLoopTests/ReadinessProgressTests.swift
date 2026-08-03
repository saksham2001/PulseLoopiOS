import XCTest
import SwiftData
@testable import PulseLoop

/// Progress toward a first readiness score: the night count, and the copy that reports it.
///
/// The number shown to a user is a countdown they will hold the feature to, so these tests pin it
/// against the gate that actually blocks scoring rather than against a hard-coded 7.
@MainActor
final class ReadinessProgressTests: XCTestCase {

    private var savedPrefs: ReadinessPrefs?

    override func setUp() async throws {
        try await super.setUp()
        savedPrefs = ReadinessPrefsStore.shared.prefs
        ReadinessPrefsStore.shared.prefs = ReadinessPrefs.default
    }

    override func tearDown() async throws {
        if let savedPrefs { ReadinessPrefsStore.shared.prefs = savedPrefs }
        try await super.tearDown()
    }

    private var calendar: Calendar { Calendar.current }

    private func day(_ offset: Int) -> Date { TestSupport.day(offset) }

    /// A night belonging to the morning of `dayOffset`, 23:00 → +`minutes`.
    @discardableResult
    private func insertNight(_ dayOffset: Int, minutes: Int = 420, into context: ModelContext) -> SleepSession {
        let start = calendar.date(byAdding: .hour, value: -1, to: day(dayOffset)) ?? day(dayOffset)
        let end = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        let session = SleepSession(date: day(dayOffset), startAt: start, endAt: end,
                                   totalMinutes: minutes, syncedAt: start)
        context.insert(session)
        context.insert(SleepStageBlock(sessionId: session.id, startAt: start,
                                       startMinute: 0, durationMinutes: minutes, stage: .light))
        try? context.save()
        return session
    }

    /// One overnight HRV reading on the night of `dayOffset`, with no sleep session.
    private func insertOvernightHRV(_ dayOffset: Int, into context: ModelContext) {
        let ts = calendar.date(byAdding: .hour, value: 2, to: day(dayOffset)) ?? day(dayOffset)  // 02:00
        TestSupport.insertMeasurement(kind: .hrv, value: 48, timestamp: ts, into: context)
    }

    /// Readings spread across the night at the given hours after midnight, with no sleep session.
    private func insertOvernightRun(_ dayOffset: Int, hours: [Int], into context: ModelContext) {
        for hour in hours {
            let ts = calendar.date(byAdding: .hour, value: hour, to: day(dayOffset)) ?? day(dayOffset)
            TestSupport.insertMeasurement(kind: .hrv, value: 48, timestamp: ts, into: context)
        }
    }

    // MARK: - The number the user counts down against

    /// If `BaselineStats.isEstablished` ever changes its span requirement, the countdown shown to
    /// the user becomes a lie. This fails loudly in that case.
    func testAdvertisedNightsMatchTheBaselineGate() {
        let needed = ReadinessService.baselineNightsNeeded

        func stats(spanDays: Double) -> BaselineStats {
            BaselineStats(mean: 50, median: 50, standardDeviation: 5, p25: 45, p75: 55,
                          sampleCount: 40, spanDays: spanDays)
        }
        XCTAssertTrue(stats(spanDays: Double(needed)).isEstablished,
                      "a baseline spanning the advertised \\(needed) nights must be established")
        XCTAssertFalse(stats(spanDays: Double(needed) - 0.1).isEstablished,
                       "one night short must NOT be established")
    }

    // MARK: - Counting

    func testCountsOnlyNightsThatProducedSignal() throws {
        let context = try TestSupport.makeContext()
        for offset in [0, -1, -4] { insertNight(offset, into: context) }

        let progress = ReadinessService.progress(context: context)
        XCTAssertEqual(progress.nightsCollected, 3, "gaps must not be counted as worn nights")
        XCTAssertEqual(progress.nightsNeeded, ReadinessService.baselineNightsNeeded)
        XCTAssertEqual(progress.nightsRemaining, ReadinessService.baselineNightsNeeded - 3)
        XCTAssertFalse(progress.hasEnoughNights)
    }

    /// A night whose sleep decode failed still counts if the ring was clearly worn through it —
    /// otherwise the countdown would stall for a user who is in fact wearing it every night.
    func testANightWithSustainedVitalsButNoSleepStillCounts() throws {
        let context = try TestSupport.makeContext()
        insertOvernightRun(0, hours: [0, 2, 4], into: context)
        XCTAssertEqual(ReadinessService.progress(context: context).nightsCollected, 1)
    }

    /// Regression, reported from a real device: the counter read "6 of 7 nights" for a user with
    /// two nights of actual sleep data.
    ///
    /// These rings log heart rate all day and the fallback overnight window is 22:00–08:00, so
    /// wearing the ring until 22:30 or putting it on at 07:30 dropped a reading inside the window
    /// and marked the whole day "collected". The countdown would have reached 7 and still produced
    /// no score — the exact broken promise this indicator exists to prevent.
    func testEveningAndMorningWearDoesNotCountAsASleptNight() throws {
        let context = try TestSupport.makeContext()
        // Two nights genuinely slept in the ring.
        insertNight(-1, into: context)
        insertNight(-2, into: context)
        // Four days where it was only worn around the edges of the overnight window.
        for offset in [-3, -4, -5, -6] {
            let evening = calendar.date(byAdding: .hour, value: -1, to: day(offset)) ?? day(offset)   // 23:00
            let morning = calendar.date(byAdding: .hour, value: 7, to: day(offset)) ?? day(offset)    // 07:00
            TestSupport.insertMeasurement(kind: .heartRate, value: 68, timestamp: evening, into: context)
            TestSupport.insertMeasurement(kind: .heartRate, value: 72, timestamp: morning, into: context)
        }

        let progress = ReadinessService.progress(context: context)
        XCTAssertEqual(progress.nightsCollected, 2,
                       "only nights actually slept in the ring count; edge-of-window wear does not")
        XCTAssertEqual(progress.nightsRemaining, ReadinessService.baselineNightsNeeded - 2)
    }

    /// A single stray reading is not a night, however isolated.
    func testOneStrayOvernightReadingIsNotANight() throws {
        let context = try TestSupport.makeContext()
        insertOvernightHRV(0, into: context)
        XCTAssertEqual(ReadinessService.progress(context: context).nightsCollected, 0)
    }

    /// Readings clustered into a few minutes are someone checking their ring, not sleeping in it.
    func testReadingsMustSpanEnoughOfTheNight() throws {
        let context = try TestSupport.makeContext()
        for minute in [0, 5, 10, 15] {
            let ts = calendar.date(byAdding: .minute, value: 120 + minute, to: day(0)) ?? day(0)
            TestSupport.insertMeasurement(kind: .heartRate, value: 60, timestamp: ts, into: context)
        }
        XCTAssertEqual(ReadinessService.progress(context: context).nightsCollected, 0,
                       "four readings inside 15 minutes is not a night's wear")
    }

    func testNoDataReportsZeroNights() throws {
        let context = try TestSupport.makeContext()
        let progress = ReadinessService.progress(context: context)
        XCTAssertEqual(progress.nightsCollected, 0)
        XCTAssertEqual(progress.reason, .noSignals)
    }

    /// Progress counts nights *with data*, not days since install. Someone who wore the ring twice
    /// in a month is two nights along, and saying otherwise promises a score that isn't coming.
    func testSparseWearIsNotInflatedByElapsedTime() throws {
        let context = try TestSupport.makeContext()
        insertNight(-1, into: context)
        insertNight(-25, into: context)
        XCTAssertEqual(ReadinessService.progress(context: context).nightsCollected, 2)
    }

    // MARK: - Copy

    func testCountdownReadsCorrectly() {
        let p = ReadinessProgress(nightsCollected: 3, nightsNeeded: 7, reason: .baselineLearning)
        XCTAssertEqual(p.title, "Learning your baseline")
        XCTAssertEqual(p.detail, "3 of 7 nights collected · 4 more nights to go")
        XCTAssertEqual(p.shortDetail, "3 of 7 nights")
        XCTAssertEqual(p.fraction, 3.0 / 7.0, accuracy: 0.0001)
    }

    func testSingularNightIsNotPluralised() {
        let p = ReadinessProgress(nightsCollected: 6, nightsNeeded: 7, reason: .baselineLearning)
        XCTAssertEqual(p.detail, "6 of 7 nights collected · 1 more night to go")
    }

    func testZeroNightsAsksForTheFirstOne() {
        let p = ReadinessProgress(nightsCollected: 0, nightsNeeded: 7, reason: .noSignals)
        XCTAssertEqual(p.title, "No score yet")
        XCTAssertTrue(p.detail.contains("Wear your ring overnight"))
        XCTAssertEqual(p.fraction, 0)
    }

    /// Nights are a proxy for a gate that also needs enough individual readings. Claiming "0 more
    /// nights" while still showing no score would be a broken promise, so this case says so.
    func testEnoughNightsButStillUnscoredDoesNotPromiseZeroMore() {
        let p = ReadinessProgress(nightsCollected: 9, nightsNeeded: 7, reason: .baselineLearning)
        XCTAssertTrue(p.hasEnoughNights)
        XCTAssertFalse(p.detail.contains("0 more"))
        XCTAssertTrue(p.detail.contains("Still gathering"))
        XCTAssertEqual(p.fraction, 1, "the bar must not overflow past full")
    }

    /// Regression: the ring first shipped reading "30 of 7 nights", which looks like a broken
    /// counter rather than progress. Past the target the fraction is dropped entirely.
    func testRingCaptionDropsTheFractionOnceTheTargetIsMet() {
        XCTAssertEqual(
            ReadinessProgress(nightsCollected: 3, nightsNeeded: 7, reason: .baselineLearning).centerCaption,
            "of 7 nights"
        )
        XCTAssertEqual(
            ReadinessProgress(nightsCollected: 30, nightsNeeded: 7, reason: .baselineLearning).centerCaption,
            "nights"
        )
        XCTAssertEqual(
            ReadinessProgress(nightsCollected: 1, nightsNeeded: 1, reason: .baselineLearning).centerCaption,
            "night"
        )
    }

    // MARK: - Summary plumbing

    func testSummaryCarriesProgressOnlyWhileThereIsNoScore() throws {
        let context = try TestSupport.makeContext()
        insertNight(0, into: context)

        let unscored = MetricsService.buildTodaySummary(context: context, scope: .today)
        XCTAssertNil(unscored.readiness)
        XCTAssertNotNil(unscored.readinessProgress, "the empty state needs its countdown")

        // Now give the day a real score.
        context.insert(ReadinessDaily(date: day(0), score: 80, band: .ready,
                                      availablePoints: 100, contributorsJSON: "[]"))
        try? context.save()

        let scored = MetricsService.buildTodaySummary(context: context, scope: .today)
        XCTAssertNotNil(scored.readiness)
        XCTAssertNil(scored.readinessProgress, "progress must not be computed on the happy path")
    }

    func testSummaryOmitsProgressWhenTheFeatureIsOff() throws {
        let context = try TestSupport.makeContext()
        insertNight(0, into: context)

        var prefs = ReadinessPrefs.default
        prefs.masterEnabled = false
        ReadinessPrefsStore.shared.prefs = prefs

        let summary = MetricsService.buildTodaySummary(context: context, scope: .today)
        XCTAssertNil(summary.readiness)
        XCTAssertNil(summary.readinessProgress)
    }
}
