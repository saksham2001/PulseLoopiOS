import XCTest
import SwiftData
@testable import PulseLoop

/// The multi-signal overnight strain detector. Its whole value is that it waits for *agreement*
/// between signals, so most of these pin the cases where it deliberately stays quiet.
@MainActor
final class HealthWatchTests: XCTestCase {

    /// Baselines a healthy adult might carry, for the signals to be judged against.
    private let baselines: [HealthWatch.Signal: Double] = [
        .skinTemperature: 34.0,
        .restingHeartRate: 54,
        .hrv: 60,
        .respiratoryRate: 14,
        .bloodOxygen: 97,
    ]

    // MARK: - Direction

    /// Only the strain side of each signal counts. A resting HR *below* baseline, an HRV *above*
    /// it, or a cooler night are not warning signs — flagging them would turn good news into alerts.
    func testOnlyTheStrainDirectionCounts() {
        XCTAssertEqual(HealthWatch.level(for: .restingHeartRate, value: 44, baseline: 54), .normal)
        XCTAssertEqual(HealthWatch.level(for: .restingHeartRate, value: 64, baseline: 54), .strong)

        XCTAssertEqual(HealthWatch.level(for: .hrv, value: 90, baseline: 60), .normal, "higher HRV is good news")
        XCTAssertEqual(HealthWatch.level(for: .hrv, value: 40, baseline: 60), .strong)

        XCTAssertEqual(HealthWatch.level(for: .skinTemperature, value: 32.5, baseline: 34), .normal)
        XCTAssertEqual(HealthWatch.level(for: .skinTemperature, value: 35.2, baseline: 34), .strong)

        XCTAssertEqual(HealthWatch.level(for: .bloodOxygen, value: 99, baseline: 97), .normal)
        XCTAssertEqual(HealthWatch.level(for: .bloodOxygen, value: 93, baseline: 97), .strong)
    }

    func testThresholdKnots() {
        XCTAssertEqual(HealthWatch.level(for: .skinTemperature, value: 34.4, baseline: 34), .normal)
        XCTAssertEqual(HealthWatch.level(for: .skinTemperature, value: 34.5, baseline: 34), .notable)
        XCTAssertEqual(HealthWatch.level(for: .skinTemperature, value: 35.0, baseline: 34), .strong)

        XCTAssertEqual(HealthWatch.level(for: .restingHeartRate, value: 58.9, baseline: 54), .normal)
        XCTAssertEqual(HealthWatch.level(for: .restingHeartRate, value: 59, baseline: 54), .notable)

        // HRV's knots are proportional, since it spans an order of magnitude across healthy adults.
        XCTAssertEqual(HealthWatch.level(for: .hrv, value: 51, baseline: 60), .notable, "15% below")
        XCTAssertEqual(HealthWatch.level(for: .hrv, value: 42, baseline: 60), .strong, "30% below")
    }

    // MARK: - Agreement

    func testANormalNightIsClear() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 34.1, .restingHeartRate: 53, .hrv: 61, .bloodOxygen: 97],
            baselines: baselines
        )
        XCTAssertEqual(result.status, .clear)
        XCTAssertTrue(result.flagged.isEmpty)
    }

    /// **The false-alarm guard.** One signal nudging past its knot is noise — a warm duvet, one
    /// restless hour. Nothing fires until something corroborates it.
    func testASingleNotableSignalStaysQuiet() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 34.6, .restingHeartRate: 53, .hrv: 61, .bloodOxygen: 97],
            baselines: baselines
        )
        XCTAssertEqual(result.status, .clear)
        XCTAssertEqual(result.flagged.count, 1, "it is still reported, just not acted on")
    }

    func testTwoNotableSignalsAreMinor() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 34.6, .restingHeartRate: 60, .hrv: 61, .bloodOxygen: 97],
            baselines: baselines
        )
        XCTAssertEqual(result.status, .minor)
    }

    /// A single strong signal is worth a minor flag on its own — a full degree of overnight
    /// temperature rise is not noise, even unaccompanied.
    func testOneStrongSignalAloneIsMinor() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 35.2, .restingHeartRate: 53, .hrv: 61, .bloodOxygen: 97],
            baselines: baselines
        )
        XCTAssertEqual(result.status, .minor)
    }

    func testAStrongPlusANotableIsMajor() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 35.2, .restingHeartRate: 60, .hrv: 61, .bloodOxygen: 97],
            baselines: baselines
        )
        XCTAssertEqual(result.status, .major)
        XCTAssertEqual(result.flagged.count, 2)
    }

    /// The classic pattern: warmer, working harder, less variable.
    func testTheIllnessPatternIsMajor() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 35.3, .restingHeartRate: 66, .hrv: 38, .bloodOxygen: 96],
            baselines: baselines
        )
        XCTAssertEqual(result.status, .major)
        XCTAssertGreaterThanOrEqual(result.flagged.count, 3)
    }

    // MARK: - Availability

    /// A jring has no temperature sensor and no breathing rate. It still gets a usable answer from
    /// the three signals it does have.
    func testARingWithFewerSensorsStillWorks() {
        let result = HealthWatch.evaluate(
            values: [.restingHeartRate: 66, .hrv: 38, .bloodOxygen: 97],
            baselines: baselines
        )
        XCTAssertEqual(result.signalsAvailable, 3)
        XCTAssertEqual(result.status, .major)
    }

    /// One judgeable signal can't corroborate anything, so the honest answer is "clear" rather than
    /// a warning built on a single reading.
    func testOneJudgeableSignalNeverFlags() {
        let result = HealthWatch.evaluate(values: [.restingHeartRate: 80], baselines: baselines)
        XCTAssertEqual(result.signalsAvailable, 1)
        XCTAssertEqual(result.status, .clear)
    }

    func testSignalsWithoutABaselineAreNotJudged() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 36, .restingHeartRate: 70, .hrv: 30],
            baselines: [.restingHeartRate: 54]   // only one baseline established
        )
        XCTAssertEqual(result.signalsAvailable, 1)
        XCTAssertEqual(result.status, .clear)
    }

    func testAZeroBaselineIsNotJudged() {
        let result = HealthWatch.evaluate(
            values: [.restingHeartRate: 70, .hrv: 30],
            baselines: [.restingHeartRate: 0, .hrv: 0]
        )
        XCTAssertEqual(result.signalsAvailable, 0)
    }

    // MARK: - Copy

    /// Non-negotiable: the facts sentence names the mundane explanations, and never a condition.
    func testFactsNameTheMundaneExplanationsAndNoDiagnosis() {
        let result = HealthWatch.evaluate(
            values: [.skinTemperature: 35.3, .restingHeartRate: 66, .hrv: 38],
            baselines: baselines
        )
        let facts = HealthWatch.facts(result)
        XCTAssertTrue(facts.contains("alcohol"))
        XCTAssertTrue(facts.contains("hard session"))
        for word in ["infection", "illness", "fever", "sick", "virus", "flu"] {
            XCTAssertFalse(facts.lowercased().contains(word), "must not name a condition: \(word)")
        }
    }

    func testFactsOnAClearNight() {
        let result = HealthWatch.evaluate(values: [.restingHeartRate: 53, .hrv: 61], baselines: baselines)
        XCTAssertTrue(HealthWatch.facts(result).contains("close to your usual"))
    }

    // MARK: - Alerting

    /// Only `major` interrupts. `minor` means two signals nudged past their knots, which happens
    /// after a glass of wine often enough that alerting on it would train people to dismiss the
    /// ones that matter — it still reaches the card and the coach.
    func testOnlyMajorFiresAnAlert() {
        func packet(status: HealthWatch.Status, flagged: Int) -> NotificationContextPacket {
            var p = NotificationContextPacket(
                slot: "morning", generatedAt: "", timezone: "UTC", profileName: nil,
                goals: .init(stepsDaily: 10000, activeMinutesDaily: 45, sleepHours: 8, exerciseDaysWeekly: 4),
                today: .init(localDate: "2026-06-05", steps: 0, calories: nil, distanceKm: nil,
                             activeMinutes: nil, dataConfidence: "high"),
                latestSleep: nil,
                latestVitals: .init(latestHr: nil, latestHrAt: nil, latestSpo2: nil, latestSpo2At: nil,
                                    restingHrEstimate: nil, peakHrToday: nil),
                hrLast12h: .init(count: 0, avg: nil, min: nil, max: nil),
                spo2Last12h: .init(count: 0, avg: nil, min: nil, max: nil),
                recentWorkouts: [], memories: [], dataQualityWarnings: []
            )
            p.healthWatch = .init(
                status: status.rawValue, signalsAvailable: 4,
                flagged: (0..<flagged).map {
                    .init(signal: "Signal \($0)", value: 1, baseline: 0.5, detail: "up")
                },
                facts: "grounded sentence"
            )
            return p
        }

        XCTAssertEqual(CoachAnomalyDetector.detect(packet(status: .major, flagged: 2))?.kind, .healthWatch)
        XCTAssertNil(CoachAnomalyDetector.detect(packet(status: .minor, flagged: 2)))
        XCTAssertNil(CoachAnomalyDetector.detect(packet(status: .clear, flagged: 0)))
        XCTAssertNil(CoachAnomalyDetector.detect(packet(status: .major, flagged: 0)),
                     "a major status with nothing flagged is incoherent — don't fire on it")
    }

    // MARK: - Baselines from the store

    /// A single feverish night must not drag the very baseline it needs to be judged against, which
    /// is why the baseline is a median of per-night figures rather than a mean of every sample.
    func testBaselineIsAMedianOfNightsNotOfSamples() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current

        // Ten ordinary nights at 34.0 °C, sampled sparsely...
        for offset in 1...10 {
            let day = TestSupport.day(-offset)
            let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: start, stages: Array(repeating: .light, count: 420), into: context)
            for i in 0..<8 {
                let ts = calendar.date(byAdding: .minute, value: i * 30, to: start) ?? start
                context.insert(Measurement(kind: .temperature, value: 34.0, unit: "°C", timestamp: ts))
            }
        }
        // ...and one hot night sampled four times as often, which would dominate a raw sample mean.
        let hotDay = TestSupport.day(-11)
        let hotStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: hotDay) ?? hotDay
        _ = TestSupport.insertSleep(nightStart: hotStart, stages: Array(repeating: .light, count: 420), into: context)
        for i in 0..<40 {
            let ts = calendar.date(byAdding: .minute, value: i * 6, to: hotStart) ?? hotStart
            context.insert(Measurement(kind: .temperature, value: 37.5, unit: "°C", timestamp: ts))
        }
        try? context.save()

        let baseline = try XCTUnwrap(
            HealthWatchService.baseline(.skinTemperature, before: TestSupport.day(0), context: context)
        )
        XCTAssertEqual(baseline, 34.0, accuracy: 0.05, "the one hot night doesn't move the median")
    }

    func testBaselineNeedsAWeekOfNights() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        for offset in 1...5 {
            let day = TestSupport.day(-offset)
            let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
            _ = TestSupport.insertSleep(nightStart: start, stages: Array(repeating: .light, count: 420), into: context)
            for i in 0..<8 {
                let ts = calendar.date(byAdding: .minute, value: i * 30, to: start) ?? start
                context.insert(Measurement(kind: .heartRate, value: 55, unit: "bpm", timestamp: ts))
            }
        }
        try? context.save()

        XCTAssertNil(HealthWatchService.baseline(.restingHeartRate, before: TestSupport.day(0), context: context),
                     "five nights is under the seven-night floor")
    }

    func testEvaluateIsNilWithoutARecentNight() throws {
        let context = try TestSupport.makeContext()
        XCTAssertNil(HealthWatchService.evaluate(context: context))
    }
}
