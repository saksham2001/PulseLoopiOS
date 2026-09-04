import XCTest
import SwiftData
@testable import PulseLoop

/// Nightly-BBT extraction + cycle service plumbing on in-memory SwiftData: sleep-session
/// windowing, awake-block exclusion, the stable-window fallback, and capability gating.
@MainActor
final class CycleBBTServiceTests: XCTestCase {
    private var context: ModelContext!
    private let calendar = Calendar.current

    override func setUp() async throws {
        context = try TestSupport.makeContext()
        CycleSettingsStore.shared.settings = .default
    }

    private func insertTemp(_ value: Double, at date: Date) {
        TestSupport.insertMeasurement(kind: .temperature, value: value, timestamp: date, into: context)
    }

    // MARK: - Session path

    func testNightMedianExcludesAwakeSamples() throws {
        // A 7h night starting 23:00: 2h light, 1h awake, 4h light.
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))!
        let stages: [SleepStage] = Array(repeating: .light, count: 120)
            + Array(repeating: .awake, count: 60)
            + Array(repeating: .light, count: 240)
        let session = TestSupport.insertSleep(nightStart: nightStart, stages: stages, into: context)

        // Ring cadence: a sample every 30 min. The two samples inside the awake hour are hot
        // outliers that must not touch the median.
        for halfHour in 0..<14 {
            let ts = calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!
            let minutesIn = calendar.dateComponents([.minute], from: nightStart, to: ts).minute!
            let isAwake = minutesIn >= 120 && minutesIn < 180
            insertTemp(isAwake ? 39.0 : 36.0, at: ts)
        }

        let night = CycleBBTService.nightTemperature(for: session.date, context: context)
        XCTAssertEqual(night.celsius, 36.0)
        XCTAssertEqual(night.sampleCount, 12)
    }

    func testTooFewSamplesReturnsNoData() throws {
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))!
        let session = TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: SleepStage.light, count: 300), into: context)
        for halfHour in 0..<3 {
            insertTemp(36.2, at: calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!)
        }
        let night = CycleBBTService.nightTemperature(for: session.date, context: context)
        XCTAssertNil(night.celsius)
    }

    // MARK: - Robustness against replayed / duplicated samples

    /// A store written before the log-upsert fix holds one copy of each slot per sync — more copies
    /// for the slots that existed at the time of the most syncs. A median over those rows is weighted
    /// by sync count, not time. One value per slot, whatever the row count.
    func testDuplicateRowsDoNotSkewTheMedian() throws {
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))!
        let session = TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: SleepStage.light, count: 420), into: context)
        // 14 slots: first half warm (36.9), second half cool (36.5); the cool half replayed ×10.
        for halfHour in 0..<14 {
            let ts = calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!
            let copies = halfHour < 7 ? 1 : 10
            for _ in 0..<copies { insertTemp(halfHour < 7 ? 36.9 : 36.5, at: ts) }
        }

        let night = CycleBBTService.nightTemperature(for: session.date, context: context)
        XCTAssertEqual(try XCTUnwrap(night.celsius), 36.7, accuracy: 0.001)
        XCTAssertEqual(night.sampleCount, 14)
    }

    /// More than 500 rows in the night must not silently drop the early-night slots (the
    /// repository's default fetch cap, newest first).
    func testMoreThanFiveHundredRowsKeepsTheWholeNight() throws {
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))!
        let session = TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: SleepStage.light, count: 420), into: context)
        for halfHour in 0..<14 {
            let ts = calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!
            for _ in 0..<50 { insertTemp(halfHour < 7 ? 36.9 : 36.5, at: ts) }   // 700 rows
        }

        let night = CycleBBTService.nightTemperature(for: session.date, context: context)
        XCTAssertEqual(try XCTUnwrap(night.celsius), 36.7, accuracy: 0.001)
        XCTAssertEqual(night.sampleCount, 14)
    }

    /// When a slot was revised by a later sync, the latest row is the one that counts.
    func testLatestRowWinsForARevisedSlot() throws {
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))!
        let session = TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: SleepStage.light, count: 420), into: context)
        for halfHour in 0..<6 {
            let ts = calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!
            let stale = TestSupport.insertMeasurement(kind: .temperature, value: 35.0, timestamp: ts, into: context)
            stale.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            insertTemp(36.4, at: ts)
        }
        try context.save()

        let night = CycleBBTService.nightTemperature(for: session.date, context: context)
        XCTAssertEqual(night.celsius, 36.4)
        XCTAssertEqual(night.sampleCount, 6)
    }

    /// A waking day can hold a nap next to the night; the night (the longest session) is the one
    /// the basal temperature comes from, whatever order the rows were stored in.
    func testLongestSessionOfTheDayIsTheNight() throws {
        // Nap first, so a "first matching session" lookup would have picked it.
        let napStart = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: TestSupport.day(0))!
        TestSupport.insertSleep(nightStart: napStart, stages: Array(repeating: SleepStage.light, count: 150), into: context)
        for halfHour in 0..<5 {
            insertTemp(37.5, at: calendar.date(byAdding: .minute, value: 10 + halfHour * 30, to: napStart)!)
        }
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))!
        let session = TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: SleepStage.light, count: 420), into: context)
        for halfHour in 0..<14 {
            insertTemp(36.2, at: calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!)
        }

        let night = CycleBBTService.nightTemperature(for: session.date, context: context)
        XCTAssertEqual(night.celsius, 36.2)
        XCTAssertEqual(night.sampleCount, 14)
    }

    // MARK: - No-session fallback

    func testFallbackPicksTheMostStableWindow() throws {
        // No sleep session at all. Noisy daytime readings, one rock-steady 4h stretch —
        // the fallback must find the steady stretch, not a clock window.
        let day = TestSupport.day(0)
        let windowStart = calendar.date(byAdding: .hour, value: -12, to: day)!
        for halfHour in 0..<48 {
            let ts = calendar.date(byAdding: .minute, value: halfHour * 30, to: windowStart)!
            let hoursIn = Double(halfHour) / 2
            // Stable rest block 5h–9h into the window; jittery everywhere else.
            let stable = hoursIn >= 5 && hoursIn < 9
            insertTemp(stable ? 36.2 : (halfHour.isMultiple(of: 2) ? 35.4 : 37.1), at: ts)
        }
        let night = CycleBBTService.nightTemperature(for: day, context: context)
        XCTAssertEqual(night.celsius, 36.2)
    }

    func testNoDataAtAllReturnsNil() throws {
        let night = CycleBBTService.nightTemperature(for: TestSupport.day(0), context: context)
        XCTAssertNil(night.celsius)
        XCTAssertEqual(night.sampleCount, 0)
    }

    // MARK: - Capability gating

    func testCycleUnavailableWithoutTemperatureCapability() throws {
        context.insert(Device(state: .connected, capabilities: [.heartRate, .spo2, .steps]))
        try context.save()
        XCTAssertFalse(CycleService.isAvailable(context: context))
    }

    func testCycleAvailableWithTemperatureCapability() throws {
        context.insert(Device(state: .connected, capabilities: [.heartRate, .temperature]))
        try context.save()
        XCTAssertTrue(CycleService.isAvailable(context: context))
    }

    // MARK: - Overview plumbing

    func testOverviewMergesLoggedFactsAndTemperatures() throws {
        // Period on days -9…-6, one biphasic stretch of nights.
        for offset in -9...(-6) {
            let day = CycleRepository.dayOrNew(for: TestSupport.day(offset), context: context)
            day.isPeriod = true
            CycleRepository.save(day, context: context)
        }
        for offset in -9...0 {
            let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: TestSupport.day(offset))!
            let nightStart = calendar.date(byAdding: .minute, value: -420, to: wake)!
            TestSupport.insertSleep(nightStart: nightStart, stages: Array(repeating: SleepStage.light, count: 420), into: context)
            for halfHour in 0..<14 {
                insertTemp(36.0, at: calendar.date(byAdding: .minute, value: 15 + halfHour * 30, to: nightStart)!)
            }
        }

        let overview = CycleService.overview(context: context)
        let analysis = try XCTUnwrap(overview.analysis)
        XCTAssertEqual(analysis.cycleStart, TestSupport.day(-9))
        XCTAssertEqual(analysis.dayNumber, 10)
        XCTAssertEqual(overview.chartDays.count, 10)
        XCTAssertEqual(overview.chartDays.compactMap(\.temperature).count, 10)
        XCTAssertTrue(overview.chartDays.first?.isPeriod == true)
    }

    func testOverviewWithoutPeriodHasNoAnalysisButKeepsFacts() throws {
        let day = CycleRepository.dayOrNew(for: TestSupport.day(-1), context: context)
        day.isDisturbed = true
        CycleRepository.save(day, context: context)

        let overview = CycleService.overview(context: context)
        XCTAssertNil(overview.analysis)
        XCTAssertEqual(overview.loggedDays.count, 1)
        XCTAssertTrue(overview.loggedDays.values.first?.isDisturbed == true)
    }

    func testRepositoryPrunesEmptyDays() throws {
        let day = CycleRepository.dayOrNew(for: TestSupport.day(0), context: context)
        day.isPeriod = true
        CycleRepository.save(day, context: context)
        XCTAssertEqual(CycleRepository.days(context: context).count, 1)

        let same = CycleRepository.dayOrNew(for: TestSupport.day(0), context: context)
        same.isPeriod = false
        CycleRepository.save(same, context: context)
        XCTAssertTrue(CycleRepository.days(context: context).isEmpty)
    }
}
