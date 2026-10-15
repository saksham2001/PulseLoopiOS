import XCTest
import SwiftData
@testable import PulseLoop

/// `restingHRDrift` shipped as a declared-but-unfired `CoachAnomalyKind` — the detector reads a
/// 12-hour packet and drift only means anything against a multi-day baseline. These lock both halves
/// of the fix: the baseline now rides in the packet, and the detector's gates.
@MainActor
final class RestingHRDriftTests: XCTestCase {

    /// Builds a packet carrying only what the drift detector reads; everything else is inert so a
    /// higher-priority anomaly can't mask the case under test.
    private func packet(
        baseline: Double?, lastNight: Double?, nightOf: String, samples: Int = 40
    ) -> NotificationContextPacket {
        var p = NotificationContextPacket(
            slot: "morning", generatedAt: "", timezone: "UTC", profileName: "Sam",
            goals: .init(stepsDaily: 10000, activeMinutesDaily: 45, sleepHours: 8, exerciseDaysWeekly: 4),
            today: .init(localDate: nightOf, steps: 0, calories: nil, distanceKm: nil,
                         activeMinutes: nil, dataConfidence: "high"),
            latestSleep: nil,
            latestVitals: .init(latestHr: nil, latestHrAt: nil, latestSpo2: nil, latestSpo2At: nil,
                                restingHrEstimate: nil, peakHrToday: nil),
            hrLast12h: .init(count: 0, avg: nil, min: nil, max: nil),
            spo2Last12h: .init(count: 0, avg: nil, min: nil, max: nil),
            recentWorkouts: [], memories: [], dataQualityWarnings: []
        )
        if let baseline, let lastNight {
            p.restingHR = .init(baselineBpm: baseline, lastNightBpm: lastNight,
                                sampleCount: samples, nightOf: nightOf)
        }
        return p
    }

    private func today(_ now: Date = Date()) -> String {
        CoachDataAccess.localDateString(now)
    }

    // MARK: - Threshold

    func testFiresAtTheDriftThreshold() {
        let now = Date()
        let anomaly = CoachAnomalyDetector.detect(
            packet(baseline: 54, lastNight: 59, nightOf: today(now)), now: now
        )
        XCTAssertEqual(anomaly?.kind, .restingHRDrift)
        XCTAssertTrue(anomaly?.facts.contains("59 bpm") == true)
        XCTAssertTrue(anomaly?.facts.contains("5 bpm above") == true)
    }

    func testSilentJustBelowTheThreshold() {
        let now = Date()
        XCTAssertNil(CoachAnomalyDetector.detect(
            packet(baseline: 54, lastNight: 58.9, nightOf: today(now)), now: now
        ))
    }

    /// A resting HR *below* baseline is usually good news, and never an unprompted alert.
    func testSilentWhenRestingHRIsBelowBaseline() {
        let now = Date()
        XCTAssertNil(CoachAnomalyDetector.detect(
            packet(baseline: 60, lastNight: 50, nightOf: today(now)), now: now
        ))
    }

    // MARK: - Gates

    func testSilentWithoutAnEstablishedBaseline() {
        let now = Date()
        XCTAssertNil(CoachAnomalyDetector.detect(
            packet(baseline: nil, lastNight: nil, nightOf: today(now)), now: now
        ))
    }

    func testSilentOnAStaleNight() {
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -5, to: now) ?? now
        XCTAssertNil(
            CoachAnomalyDetector.detect(
                packet(baseline: 54, lastNight: 70, nightOf: CoachDataAccess.localDateString(old)), now: now
            ),
            "a five-day-old night says nothing about today, however elevated"
        )
    }

    // MARK: - Precedence

    /// A short night usually raises resting HR too. When both trip, the sleep alert names the cause
    /// and drift would only restate its consequence — `detect` returns one anomaly, so sleep wins.
    func testShortSleepOutranksDrift() {
        let now = Date()
        var p = packet(baseline: 54, lastNight: 70, nightOf: today(now))
        p.latestSleep = .init(date: today(now), totalMin: 240, deepMin: 40, lightMin: 180,
                              awakeMin: 20, score: 40, confidence: "medium", decoderNote: "")
        XCTAssertEqual(CoachAnomalyDetector.detect(p, now: now)?.kind, .poorSleep)
    }

    func testLowSpO2OutranksDrift() {
        let now = Date()
        var p = packet(baseline: 54, lastNight: 70, nightOf: today(now))
        p.spo2Last12h = .init(count: 4, avg: 93, min: 88, max: 97)
        XCTAssertEqual(CoachAnomalyDetector.detect(p, now: now)?.kind, .lowSpO2)
    }

    // MARK: - Copy

    func testScriptedAlertIsActionable() {
        let now = Date()
        guard let anomaly = CoachAnomalyDetector.detect(
            packet(baseline: 54, lastNight: 62, nightOf: today(now)), now: now
        ) else { return XCTFail("expected a drift anomaly") }

        let notification = CoachNotificationGenerator.scriptedAnomaly(anomaly)
        XCTAssertFalse(notification.title.isEmpty)
        XCTAssertNotNil(notification.tip, "the offline fallback should still suggest something")
        XCTAssertEqual(anomaly.dedupeKey, "anomaly:restingHRDrift")
    }

    // MARK: - Builder

    /// The packet block is only built once there is both a learned baseline and a recent night with
    /// enough overnight samples to stand in for a resting figure.
    func testBuilderWithholdsBlockWhenBaselineUnlearned() throws {
        let context = try TestSupport.makeContext()
        let profile = UserProfile(name: "Sam")
        context.insert(profile)
        try? context.save()

        XCTAssertNil(NotificationContextBuilder.restingHR(context: context))
    }

    func testBuilderMeasuresTheNightAtTheSamePercentileAsTheBaseline() throws {
        let context = try TestSupport.makeContext()
        let profile = UserProfile(name: "Sam")
        profile.hrRestingBaseline = 54
        context.insert(profile)

        // A night of sleep, with HR samples spread across it.
        let start = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))
            ?? TestSupport.day(-1)
        _ = TestSupport.insertSleep(nightStart: start, stages: Array(repeating: .light, count: 400), into: context)

        // 40 readings from 60 to 99 bpm: the 10th percentile lands at 63.9.
        for i in 0..<40 {
            let ts = Calendar.current.date(byAdding: .minute, value: i * 10, to: start) ?? start
            context.insert(Measurement(kind: .heartRate, value: Double(60 + i), unit: "bpm", timestamp: ts))
        }
        try? context.save()

        let resting = NotificationContextBuilder.restingHR(context: context)
        XCTAssertEqual(resting?.sampleCount, 40)
        XCTAssertEqual(resting?.baselineBpm, 54)
        XCTAssertEqual(resting?.lastNightBpm ?? 0, 63.9, accuracy: 0.05)
    }

    func testBuilderWithholdsBlockOnTooFewOvernightSamples() throws {
        let context = try TestSupport.makeContext()
        let profile = UserProfile(name: "Sam")
        profile.hrRestingBaseline = 54
        context.insert(profile)

        let start = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: TestSupport.day(-1))
            ?? TestSupport.day(-1)
        _ = TestSupport.insertSleep(nightStart: start, stages: Array(repeating: .light, count: 400), into: context)

        // One under the floor — a handful of readings is not a resting heart rate.
        for i in 0..<(NotificationContextBuilder.minNightSamples - 1) {
            let ts = Calendar.current.date(byAdding: .minute, value: i * 10, to: start) ?? start
            context.insert(Measurement(kind: .heartRate, value: 70, unit: "bpm", timestamp: ts))
        }
        try? context.save()

        XCTAssertNil(NotificationContextBuilder.restingHR(context: context))
    }
}
