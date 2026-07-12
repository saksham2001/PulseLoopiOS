import XCTest
import SwiftData
@testable import PulseLoop

/// Pure-logic coverage for the measurement-frequency feature: the Colmi command bytes, the per-device
/// config ↔ settings mapping, capability gating, vital-visibility, the graph downsampler, and the
/// user-profile value mapping. None of these need hardware.
@MainActor
final class MeasurementSettingsTests: XCTestCase {

    // MARK: - Colmi encoder bytes

    func testAutoHeartRateClampsIntervalToFiveMinuteSteps() {
        let encoder = ColmiEncoder()
        // 0x16 = autoHRPref, 0x02 = prefWrite, on flag 0x01, interval 10.
        XCTAssertEqual(encoder.autoHeartRate(enabled: true, intervalMinutes: 10), [0x16, 0x02, 0x01, 0x0a])
        // Off uses 0x02 (not 0x00) per the auto-HR shape.
        XCTAssertEqual(encoder.autoHeartRate(enabled: false, intervalMinutes: 5)[2], 0x02)
        // Out-of-range / non-multiple values clamp to 5…60 in 5-min steps.
        XCTAssertEqual(encoder.autoHeartRate(enabled: true, intervalMinutes: 3)[3], 5)
        XCTAssertEqual(encoder.autoHeartRate(enabled: true, intervalMinutes: 999)[3], 60)
        XCTAssertEqual(encoder.autoHeartRate(enabled: true, intervalMinutes: 12)[3], 10)
    }

    func testWriteTempPrefShape() {
        let encoder = ColmiEncoder()
        // 0x3a = autoTempPref, 0x03 framing byte, 0x02 = prefWrite, on/off flag.
        XCTAssertEqual(encoder.writeTempPref(enabled: true), [0x3a, 0x03, 0x02, 0x01])
        XCTAssertEqual(encoder.writeTempPref(enabled: false), [0x3a, 0x03, 0x02, 0x00])
    }

    // MARK: - Config ↔ settings mapping

    func testConfigProjectsToSettings() {
        let config = DeviceMeasurementConfig(deviceId: UUID())
        config.hrIntervalMinutes = 15
        config.spo2Enabled = false
        let settings = config.asSettings
        XCTAssertEqual(settings.hrIntervalMinutes, 15)
        XCTAssertFalse(settings.spo2Enabled)
        XCTAssertTrue(settings.hrvEnabled)
    }

    func testConfigRepositoryUpsertsOnce() throws {
        let context = try TestSupport.makeContext()
        let deviceId = UUID()
        let first = MeasurementConfigRepository.configOrDefault(deviceId: deviceId, context: context)
        first.hrIntervalMinutes = 30
        MeasurementConfigRepository.save(first, context: context)
        // Second fetch returns the same row (no duplicate insert).
        let second = MeasurementConfigRepository.configOrDefault(deviceId: deviceId, context: context)
        XCTAssertEqual(second.hrIntervalMinutes, 30)
        let all = (try? context.fetch(FetchDescriptor<DeviceMeasurementConfig>())) ?? []
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Capability gating

    /// Colmi configures its interval via the 0x16 pref; jring via byte [6] of its 0x19 background
    /// monitoring command; TK5 via the five YCBT monitor writes (`01 0C/1C/20/26/45 {enable, interval}`,
    /// interval floored at the firmware's 30-minute minimum).
    func testMeasurementIntervalCapabilityPerDevice() {
        XCTAssertTrue(ColmiCoordinator().capabilities.contains(.measurementInterval))
        XCTAssertTrue(JringCoordinator().capabilities.contains(.measurementInterval))
        XCTAssertTrue(TK5Coordinator().capabilities.contains(.measurementInterval))
    }

    /// A ring can be *asked* for a blood-pressure reading only if its live protocol has a BP mode: the
    /// jring's `0x23` mode 1, and — as of A4 — the TK5's `03 2f {01,01}`, which is exactly what
    /// SmartHealth's own BP screen sends (`appStartMeasurement(1, 1)`); the reading streams back on
    /// `06 03`. The note here used to claim the TK5 had no on-demand BP command. Colmi has no BP sensor
    /// at all.
    ///
    /// The TK5's BP is a *command* the stack has and a *sensor* nobody has confirmed on the ring, so it
    /// is bitmap-gated (`ISHASBLOOD` / `ISHASTESTBLOOD`) rather than promised: what this asserts is that
    /// the family can reach it at all, i.e. that a TK5 which claims the bits gets the button.
    func testManualBloodPressureRequiresALiveBPMode() {
        XCTAssertTrue(JringCoordinator().capabilities.contains(.manualBloodPressure))
        let tk5 = TK5Coordinator()
        XCTAssertTrue(tk5.bitmapGatedCapabilities.contains(.manualBloodPressure))
        XCTAssertTrue(
            tk5.refinedCapabilities(bitmapDerived: [.bloodPressure, .manualBloodPressure])
                .contains(.manualBloodPressure)
        )
        XCTAssertFalse(ColmiCoordinator().capabilities.contains(.manualBloodPressure))
        XCTAssertFalse(ColmiCoordinator().capabilities.contains(.bloodPressure))
    }

    /// Only the jring's PPG sweep returns every vital in one packet, so only it collapses the Vitals
    /// measure row into a single "Measure Vitals" action.
    func testCombinedVitalsMeasurementIsJringOnly() {
        XCTAssertTrue(JringCoordinator().capabilities.contains(.combinedVitalsMeasurement))
        XCTAssertFalse(ColmiCoordinator().capabilities.contains(.combinedVitalsMeasurement))
        XCTAssertFalse(TK5Coordinator().capabilities.contains(.combinedVitalsMeasurement))
    }

    // MARK: - Vital visibility (capability first, then user opt-out)

    func testHiddenVitalIsNotVisibleButUnsupportedStillFalse() throws {
        let context = try TestSupport.makeContext()
        let colmi = Device(
            deviceType: .colmiR02,
            capabilities: [.heartRate, .spo2, .steps, .sleep, .battery, .stress, .hrv, .temperature]
        )
        context.insert(colmi)
        try context.save()

        let store = MetricPrefsStore(defaults: makeEphemeralDefaults())
        // Supported + not hidden → visible.
        XCTAssertTrue(MetricsService.supports(.hrv, context: context))
        XCTAssertFalse(store.isHidden(.hrv))
        // Hiding a supported metric makes it not visible (but supports() is unchanged).
        store.setHidden(.hrv, true)
        XCTAssertTrue(store.isHidden(.hrv))
        XCTAssertTrue(MetricsService.supports(.hrv, context: context))
    }

    func testGraphResolutionFullIsIdentity() {
        XCTAssertEqual(GraphResolution.full.targetBuckets(for: .twentyFourHours), 0)
        XCTAssertGreaterThan(GraphResolution.smooth.targetBuckets(for: .twentyFourHours), 0)
    }

    // MARK: - Downsampler

    func testDownsamplerIdentityWhenTargetIsZeroOrFewerPoints() {
        let samples = (0..<10).map { MetricSample(timestamp: Date().addingTimeInterval(Double($0) * 60), value: Double($0)) }
        XCTAssertEqual(MetricDownsampler.bucketAverage(samples, targetBuckets: 0).count, 10)
        XCTAssertEqual(MetricDownsampler.bucketAverage(samples, targetBuckets: 20).count, 10)
    }

    func testDownsamplerBucketAveragesAndReducesCount() {
        let start = Date()
        // 100 points over ~100 minutes, value == index.
        let samples = (0..<100).map { MetricSample(timestamp: start.addingTimeInterval(Double($0) * 60), value: Double($0)) }
        let reduced = MetricDownsampler.bucketAverage(samples, targetBuckets: 10)
        XCTAssertLessThanOrEqual(reduced.count, 10)
        XCTAssertGreaterThan(reduced.count, 1)
        // Averaging the ascending series keeps the overall mean roughly centered.
        let mean = reduced.map(\.value).reduce(0, +) / Double(reduced.count)
        XCTAssertEqual(mean, 49.5, accuracy: 5)
        // Buckets are ordered by time.
        let timestamps = reduced.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted())
    }

    func testDownsamplerCollapsesSameTimestampToMean() {
        let t = Date()
        let samples = [10.0, 20.0, 30.0].map { MetricSample(timestamp: t, value: $0) }
        let reduced = MetricDownsampler.bucketAverage(samples, targetBuckets: 2)
        XCTAssertEqual(reduced.count, 1)
        XCTAssertEqual(reduced.first?.value, 20.0)
    }

    // MARK: - User profile mapping

    func testUserProfileValuesMapSexAndClamps() {
        let female = UserProfileValues(metric: true, sex: "Female", age: 40, heightCm: 165, weightKg: 60)
        XCTAssertEqual(female.gender, 0x00)
        let male = UserProfileValues(metric: false, sex: "male", age: 30, heightCm: 180, weightKg: 80)
        XCTAssertEqual(male.gender, 0x01)
        XCTAssertFalse(male.metric)
        let other = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil)
        XCTAssertEqual(other.gender, 0x02)
        XCTAssertEqual(other.age, 25)   // neutral fallback
    }

    func testUnitsFormatterTemperature() {
        XCTAssertEqual(UnitsFormatter.temperature(celsius: 36.5, units: .metric).unit, "°C")
        let imperial = UnitsFormatter.temperature(celsius: 36.5, units: .imperial)
        XCTAssertEqual(imperial.unit, "°F")
        XCTAssertEqual(Double(imperial.value) ?? 0, 97.7, accuracy: 0.1)
    }

    private func makeEphemeralDefaults() -> UserDefaults {
        // A bare UUID suite name (matching the Coach tests) — a dotted/prefixed suite name can abort
        // `UserDefaults(suiteName:)` on stricter CI runners.
        UserDefaults(suiteName: UUID().uuidString)!
    }
}
