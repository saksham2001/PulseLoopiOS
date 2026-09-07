import XCTest
import SwiftData
@testable import PulseLoop

/// Edwards' summated heart-rate zones, and the acute:chronic balance built on them.
@MainActor
final class TrainingLoadTests: XCTestCase {

    private let hrMax: Double = 190   // the age-unknown fallback

    /// `count` readings one minute apart, all at the same bpm.
    private func samples(bpm: Double, minutes: Int, from start: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> [MetricSample] {
        (0...minutes).map { MetricSample(timestamp: start.addingTimeInterval(Double($0) * 60), value: bpm) }
    }

    // MARK: - Zones

    func testZoneBoundariesMatchTheWorkoutSummary() {
        XCTAssertEqual(TrainingLoad.zoneIndex(forHeartRate: 100, hrMax: 200), 0, "50% → zone 1")
        XCTAssertEqual(TrainingLoad.zoneIndex(forHeartRate: 120, hrMax: 200), 1, "60% → zone 2")
        XCTAssertEqual(TrainingLoad.zoneIndex(forHeartRate: 140, hrMax: 200), 2, "70% → zone 3")
        XCTAssertEqual(TrainingLoad.zoneIndex(forHeartRate: 160, hrMax: 200), 3, "80% → zone 4")
        XCTAssertEqual(TrainingLoad.zoneIndex(forHeartRate: 180, hrMax: 200), 4, "90% → zone 5")
        XCTAssertEqual(TrainingLoad.zoneIndex(forHeartRate: 220, hrMax: 200), 4, "above max stays in zone 5")
    }

    func testMaxHeartRateFallsBackWhenAgeIsUnknown() {
        XCTAssertEqual(TrainingLoad.maxHeartRate(age: 30), 190)
        XCTAssertEqual(TrainingLoad.maxHeartRate(age: nil), 190)
    }

    // MARK: - Load

    /// Sixty minutes in zone 1 is 60 weighted minutes; the same hour in zone 5 is five times that.
    func testLoadIsWeightedMinutes() {
        let easy = TrainingLoad.load(samples: samples(bpm: 90, minutes: 60), hrMax: hrMax)
        XCTAssertEqual(easy, 60, accuracy: 0.5)

        let hard = TrainingLoad.load(samples: samples(bpm: 180, minutes: 60), hrMax: hrMax)
        XCTAssertEqual(hard, 300, accuracy: 0.5)
        XCTAssertEqual(hard / easy, 5, accuracy: 0.05)
    }

    /// **The gap cap.** Two readings twelve hours apart must not be credited as twelve hours of
    /// zone-1 work — that would turn an overnight sampling gap into the biggest session of the week.
    func testAnOvernightGapIsCappedNotCredited() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let sparse = [
            MetricSample(timestamp: start, value: 90),
            MetricSample(timestamp: start.addingTimeInterval(12 * 3600), value: 90),
        ]
        // A lone gap has no median to widen the cap, so the 5-minute ceiling applies.
        XCTAssertEqual(TrainingLoad.load(samples: sparse, hrMax: hrMax), 5, accuracy: 0.5)
    }

    func testASingleReadingHasNoLoad() {
        XCTAssertEqual(TrainingLoad.load(samples: samples(bpm: 150, minutes: 0), hrMax: hrMax), 0, accuracy: 0.001)
        XCTAssertEqual(TrainingLoad.load(samples: [], hrMax: hrMax), 0, accuracy: 0.001)
    }

    // MARK: - Acute vs chronic

    private func dailyLoad(_ values: [Int: Double], now: Date) -> [Date: Double] {
        let calendar = Calendar.current
        var out: [Date: Double] = [:]
        for (daysAgo, load) in values {
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now)
            out[day] = load
        }
        return out
    }

    func testSteadyWeekReadsAsSteady() {
        let now = Date()
        let load = dailyLoad(Dictionary(uniqueKeysWithValues: (0..<28).map { ($0, 100.0) }), now: now)
        let balance = TrainingLoad.balance(dailyLoad: load, now: now)

        XCTAssertEqual(balance.ratio ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(balance.band, .steady)
    }

    func testASharpWeekReadsAsASpike() {
        let now = Date()
        var values = Dictionary(uniqueKeysWithValues: (7..<28).map { ($0, 100.0) })
        for day in 0..<7 { values[day] = 300 }
        let balance = TrainingLoad.balance(dailyLoad: dailyLoad(values, now: now), now: now)

        XCTAssertEqual(balance.band, .spike)
        XCTAssertGreaterThan(balance.ratio ?? 0, 1.5)
    }

    func testAQuietWeekReadsAsDetraining() {
        let now = Date()
        var values = Dictionary(uniqueKeysWithValues: (7..<28).map { ($0, 200.0) })
        for day in 0..<7 { values[day] = 40 }
        let balance = TrainingLoad.balance(dailyLoad: dailyLoad(values, now: now), now: now)

        XCTAssertEqual(balance.band, .detraining)
    }

    /// **The rule that matters most.** A week the ring wasn't worn is not a week of recovery —
    /// averaging in zeros would manufacture a "detraining" reading out of a charging cable.
    func testUnwornDaysAreExcludedNotCountedAsRest() {
        let now = Date()
        // Worn on 20 days at a steady 100; the other 8 are simply absent.
        let values = Dictionary(uniqueKeysWithValues: (0..<28).filter { $0 % 7 != 3 }.map { ($0, 100.0) })
        let balance = TrainingLoad.balance(dailyLoad: dailyLoad(values, now: now), now: now)

        XCTAssertEqual(balance.ratio ?? 0, 1.0, accuracy: 0.01, "the missing days don't drag the mean down")
        XCTAssertEqual(balance.band, .steady)
    }

    /// A ratio built on a fortnight isn't a chronic baseline, so it isn't published as one.
    func testThinHistoryWithholdsTheRatio() {
        let now = Date()
        let load = dailyLoad(Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, 100.0) }), now: now)
        let balance = TrainingLoad.balance(dailyLoad: load, now: now)

        XCTAssertNil(balance.ratio)
        XCTAssertEqual(balance.band, .unknown)
        XCTAssertEqual(balance.chronicDaysCovered, 10)
    }

    /// Band edges are inclusive at the top, so a ratio sitting exactly on 1.3 stays steady.
    func testBandBoundariesAreInclusiveAtTheTop() {
        XCTAssertEqual(TrainingLoad.Band(ratio: 0.79), .detraining)
        XCTAssertEqual(TrainingLoad.Band(ratio: 0.8), .steady)
        XCTAssertEqual(TrainingLoad.Band(ratio: 1.3), .steady)
        XCTAssertEqual(TrainingLoad.Band(ratio: 1.31), .building)
        XCTAssertEqual(TrainingLoad.Band(ratio: 1.5), .building)
        XCTAssertEqual(TrainingLoad.Band(ratio: 1.51), .spike)
        XCTAssertEqual(TrainingLoad.Band(ratio: nil), .unknown)
        XCTAssertEqual(TrainingLoad.Band(ratio: .nan), .unknown)
    }

    func testEmptyHistoryIsUnknownNotZero() {
        let balance = TrainingLoad.balance(dailyLoad: [:], now: Date())
        XCTAssertNil(balance.ratio)
        XCTAssertEqual(balance.band, .unknown)
    }

    // MARK: - Through the store

    func testDailyLoadOmitsDaysWithNoReadings() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // An hour of steady effort today; nothing yesterday.
        for minute in 0...60 {
            let ts = calendar.date(byAdding: .minute, value: minute, to: today.addingTimeInterval(9 * 3600)) ?? today
            context.insert(Measurement(kind: .heartRate, value: 140, unit: "bpm", timestamp: ts))
        }
        try? context.save()

        let load = ActivityScoreService.dailyLoad(context: context)
        XCTAssertNotNil(load[today])
        XCTAssertGreaterThan(load[today] ?? 0, 100, "an hour in zone 3 is ~180 weighted minutes")

        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        XCTAssertNil(load[yesterday], "a day with no readings is absent, not zero")
    }
}
