import XCTest
import HealthKit
import SwiftData
@testable import PulseLoop

/// Respiratory rate, VO₂max, blood glucose and blood pressure were tracked and displayed in-app but
/// never reached Apple Health. These lock the four new mappings, the units they're written in, and
/// the two kinds that genuinely have nowhere to go.
@MainActor
final class HealthSyncNewTypesTests: XCTestCase {

    // MARK: - New quantity mappings

    func testRespiratoryRateMapsToCountPerMinute() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .respiratoryRate))
        XCTAssertEqual(mapping.type.identifier, HKQuantityTypeIdentifier.respiratoryRate.rawValue)
        XCTAssertEqual(mapping.unit, HKUnit.count().unitDivided(by: .minute()))
        XCTAssertEqual(mapping.convert(16), 16, "brpm is already HealthKit's unit")
    }

    func testVO2MaxMapsToMillilitresPerKilogramMinute() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .vo2max))
        XCTAssertEqual(mapping.type.identifier, HKQuantityTypeIdentifier.vo2Max.rawValue)
        let expected = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        XCTAssertEqual(mapping.unit, expected)
        XCTAssertEqual(mapping.convert(42), 42)
    }

    func testBloodGlucoseMapsToMgPerDecilitre() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .bloodSugar))
        XCTAssertEqual(mapping.type.identifier, HKQuantityTypeIdentifier.bloodGlucose.rawValue)
        XCTAssertEqual(mapping.unit, HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)))
        XCTAssertEqual(mapping.convert(95), 95, "stored canonically in mg/dL already")
    }

    // MARK: - Plausibility, matching RingEventBridge's persistence gates

    func testNewMappingPlausibilityBounds() throws {
        let resp = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .respiratoryRate))
        XCTAssertTrue(resp.isPlausible(4))
        XCTAssertTrue(resp.isPlausible(60))
        XCTAssertFalse(resp.isPlausible(3))
        XCTAssertFalse(resp.isPlausible(61))

        let vo2 = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .vo2max))
        XCTAssertTrue(vo2.isPlausible(10))
        XCTAssertTrue(vo2.isPlausible(90))
        XCTAssertFalse(vo2.isPlausible(9))
        XCTAssertFalse(vo2.isPlausible(91))

        let glucose = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .bloodSugar))
        XCTAssertTrue(glucose.isPlausible(40))
        XCTAssertTrue(glucose.isPlausible(600))
        XCTAssertFalse(glucose.isPlausible(39))
        XCTAssertFalse(glucose.isPlausible(601))
    }

    // MARK: - The two that stay unmapped

    /// Not a follow-up: HealthKit has no type for a device-derived wellness score. `HKStateOfMind`
    /// is a self-reported mood log, so writing a ring's 0–100 number into it would misrepresent both.
    func testStressAndFatigueHaveNoHealthKitType() {
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .stress))
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .fatigue))
    }

    /// Blood pressure must not take the quantity path — a loose systolic or diastolic sample is
    /// stored by Health but never surfaces as a reading, which looks exactly like a silent failure.
    func testBloodPressureHalvesAreNotQuantityMapped() {
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .bloodPressureSystolic))
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .bloodPressureDiastolic))
    }

    // MARK: - Blood-pressure pairing

    func testBloodPressurePlausibilityRejectsInvertedPairs() {
        XCTAssertTrue(HealthKitTypeMappings.isPlausibleBloodPressure(systolic: 118, diastolic: 76))
        XCTAssertFalse(HealthKitTypeMappings.isPlausibleBloodPressure(systolic: 76, diastolic: 118),
                       "systolic below diastolic is a misframed packet, not a reading")
        XCTAssertFalse(HealthKitTypeMappings.isPlausibleBloodPressure(systolic: 90, diastolic: 90),
                       "equal halves are not a valid reading either")
        XCTAssertFalse(HealthKitTypeMappings.isPlausibleBloodPressure(systolic: 300, diastolic: 76))
        XCTAssertFalse(HealthKitTypeMappings.isPlausibleBloodPressure(systolic: 118, diastolic: 20))
    }

    /// Both halves share one instant, so the sync id is derived from that instant alone — a
    /// re-export of the same reading upserts rather than duplicating.
    func testBloodPressureSyncIDIsStablePerInstant() {
        let instant = Date(timeIntervalSince1970: 1_760_000_000.25)
        XCTAssertEqual(HealthKitTypeMappings.bloodPressureSyncID(timestamp: instant),
                       HealthKitTypeMappings.bloodPressureSyncID(timestamp: instant))
        XCTAssertNotEqual(HealthKitTypeMappings.bloodPressureSyncID(timestamp: instant),
                          HealthKitTypeMappings.bloodPressureSyncID(timestamp: instant.addingTimeInterval(0.001)))
    }

    // MARK: - Preferences

    func testNewPerTypeTogglesDefaultOn() {
        let prefs = AppleHealthPrefs.default
        XCTAssertTrue(prefs.syncRespiratoryRate)
        XCTAssertTrue(prefs.syncVO2Max)
        XCTAssertTrue(prefs.syncBloodSugar)
        XCTAssertTrue(prefs.syncBloodPressure)
    }

    /// A blob written by a build that predates these keys must keep its existing choices rather than
    /// being discarded wholesale.
    func testTolerantDecodeOfAnOlderPrefsBlob() throws {
        let legacy = #"{"masterEnabled":true,"syncHeartRate":false,"backfillChoice":"newDataOnly"}"#
        let prefs = try JSONDecoder().decode(AppleHealthPrefs.self, from: Data(legacy.utf8))

        XCTAssertTrue(prefs.masterEnabled)
        XCTAssertFalse(prefs.syncHeartRate, "the stored choice survives")
        XCTAssertEqual(prefs.backfillChoice, .newDataOnly)
        XCTAssertTrue(prefs.syncVO2Max, "a key the old build never wrote falls back to its default")
    }

    // MARK: - Capability gating for the settings rows

    func testHasAnyMeasurementDrivesRowVisibility() throws {
        let context = try TestSupport.makeContext()
        XCTAssertFalse(MetricsRepository.hasAnyMeasurement(kind: .vo2max, context: context))

        context.insert(Measurement(kind: .vo2max, value: 42, unit: "mL/kg/min", timestamp: Date()))
        try? context.save()

        XCTAssertTrue(MetricsRepository.hasAnyMeasurement(kind: .vo2max, context: context))
        XCTAssertFalse(MetricsRepository.hasAnyMeasurement(kind: .respiratoryRate, context: context),
                       "existence is per-kind, not any-row")
    }
}
