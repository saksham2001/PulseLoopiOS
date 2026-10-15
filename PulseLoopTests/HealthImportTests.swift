import XCTest
import HealthKit
import SwiftData
@testable import PulseLoop

/// Reading *from* Apple Health. The live `HKHealthStore` isn't reachable in CI, so these cover the
/// parts that decide correctness: the dedup rule, the provenance that keeps the two directions from
/// looping, and the preferences.
@MainActor
final class HealthImportTests: XCTestCase {

    /// Qualified: bare `Measurement` collides with Foundation's generic `Measurement<Unit>`.
    private func glucoseRows(in context: ModelContext) -> [PulseLoop.Measurement] {
        MetricsRepository.measurementsAll(kind: .bloodSugar, context: context)
    }

    // MARK: - Provenance

    /// Imported rows carry their own source. Everything downstream keys off this — most importantly
    /// the export path, which refuses to publish them.
    func testImportedRowsAreLabelledAsComingFromHealth() throws {
        let context = try TestSupport.makeContext()
        HealthImportService.shared.upsert(kind: .bloodSugar, value: 96,
                                          timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                                          context: context)
        try? context.save()

        let rows = glucoseRows(in: context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sourceRaw, MeasurementSource.appleHealth.rawValue)
        XCTAssertEqual(rows.first?.unit, MeasurementKind.bloodSugar.unit)
    }

    /// `.appleHealth` must round-trip through the persisted raw value like every other source, or
    /// imported rows would read back as ring data after a relaunch.
    func testSourceRoundTripsThroughItsRawValue() {
        XCTAssertEqual(MeasurementSource(rawValue: "apple_health"), .appleHealth)
        XCTAssertEqual(MeasurementSource.appleHealth.rawValue, "apple_health")
    }

    // MARK: - Dedup

    /// A CGM that revises a reading in place updates the row rather than stacking a second one
    /// beside it — the same (kind, instant) dedup every other history path uses.
    func testReimportingTheSameInstantUpdatesRatherThanDuplicates() throws {
        let context = try TestSupport.makeContext()
        let instant = Date(timeIntervalSince1970: 1_760_000_000)

        XCTAssertTrue(HealthImportService.shared.upsert(kind: .bloodSugar, value: 96, timestamp: instant, context: context))
        XCTAssertTrue(HealthImportService.shared.upsert(kind: .bloodSugar, value: 104, timestamp: instant, context: context))
        try? context.save()

        let rows = glucoseRows(in: context)
        XCTAssertEqual(rows.count, 1, "one instant, one row")
        XCTAssertEqual(rows.first?.value, 104, "the revised value wins")
    }

    /// An unchanged re-import writes nothing, so a repeated pass doesn't churn the store.
    func testAnUnchangedReimportIsANoOp() throws {
        let context = try TestSupport.makeContext()
        let instant = Date(timeIntervalSince1970: 1_760_000_000)

        XCTAssertTrue(HealthImportService.shared.upsert(kind: .bloodSugar, value: 96, timestamp: instant, context: context))
        XCTAssertFalse(HealthImportService.shared.upsert(kind: .bloodSugar, value: 96, timestamp: instant, context: context))
    }

    func testDifferentInstantsAreDifferentRows() throws {
        let context = try TestSupport.makeContext()
        let instant = Date(timeIntervalSince1970: 1_760_000_000)
        HealthImportService.shared.upsert(kind: .bloodSugar, value: 96, timestamp: instant, context: context)
        HealthImportService.shared.upsert(kind: .bloodSugar, value: 101,
                                          timestamp: instant.addingTimeInterval(300), context: context)
        try? context.save()

        XCTAssertEqual(glucoseRows(in: context).count, 2)
    }

    /// An imported row must not collide with a ring row at the same instant: they are different
    /// claims about the same moment, and the ring's own reading is not something an import may edit.
    func testImportDoesNotTouchRingRowsAtTheSameInstant() throws {
        let context = try TestSupport.makeContext()
        let instant = Date(timeIntervalSince1970: 1_760_000_000)
        context.insert(Measurement(kind: .bloodSugar, value: 88, unit: "mg/dL", timestamp: instant, source: .ring))
        try? context.save()

        HealthImportService.shared.upsert(kind: .bloodSugar, value: 96, timestamp: instant, context: context)
        try? context.save()

        let rows = glucoseRows(in: context)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.sourceRaw == MeasurementSource.ring.rawValue })?.value, 88,
                       "the ring's reading is untouched")
        XCTAssertEqual(rows.first(where: { $0.sourceRaw == MeasurementSource.appleHealth.rawValue })?.value, 96)
    }

    // MARK: - The loop guard

    /// **The invariant that matters most.** PulseLoop exports glucose, so if the export path also
    /// picked up imported rows the two directions would close a loop — import a CGM reading, export
    /// it as ours, import it back. The export predicate excludes `.appleHealth`; this asserts the
    /// value it filters on hasn't drifted.
    func testExportAndImportUseDistinctSources() {
        XCTAssertNotEqual(MeasurementSource.appleHealth, MeasurementSource.ring)
        XCTAssertNotEqual(MeasurementSource.appleHealth, MeasurementSource.history)
        XCTAssertNotEqual(MeasurementSource.appleHealth.rawValue, MeasurementSource.mock.rawValue)
    }

    /// Steps and workouts stay out of the importable set on purpose: Health's step count already
    /// includes the iPhone's pedometer, and a ring workout PulseLoop exported would come back as a
    /// second session.
    func testStepsAndWorkoutsAreNotImportable() {
        XCTAssertNil(HealthImportService.importableKinds[.heartRate])
        XCTAssertEqual(Set(HealthImportService.importableKinds.keys), [.bloodSugar])
    }

    func testImportableKindsMapToRealHealthKitTypes() {
        for (kind, identifier) in HealthImportService.importableKinds {
            XCTAssertNotNil(HKQuantityType.quantityType(forIdentifier: identifier),
                            "\(kind) maps to an identifier HealthKit doesn't know")
        }
    }

    // MARK: - Preferences

    /// Import is off until asked for — a different decision from exporting, with different privacy
    /// weight, so it gets its own switch rather than riding the export master toggle.
    func testImportIsOffByDefault() {
        let prefs = AppleHealthPrefs.default
        XCTAssertFalse(prefs.importEnabled)
        XCTAssertTrue(prefs.importGlucose, "…but the per-type toggles are on, so one tap starts a full import")
        XCTAssertTrue(prefs.importBodyMass)
    }

    func testTolerantDecodeOfAPrefsBlobWithoutImportKeys() throws {
        let legacy = #"{"masterEnabled":true,"syncHeartRate":false}"#
        let prefs = try JSONDecoder().decode(AppleHealthPrefs.self, from: Data(legacy.utf8))

        XCTAssertTrue(prefs.masterEnabled)
        XCTAssertFalse(prefs.syncHeartRate, "the stored choice survives")
        XCTAssertFalse(prefs.importEnabled, "a build that never wrote the key defaults to off")
    }

    /// Import watermarks are a separate map from the export ones, so clearing one never disturbs
    /// the other — a full re-export must not also re-import a year of glucose.
    func testImportWatermarksAreIndependentOfExportWatermarks() {
        var state = AppleHealthSyncState()
        let instant = Date(timeIntervalSince1970: 1_760_000_000)
        state.measurementWatermarks["glucose"] = instant
        state.importWatermarks["glucose"] = instant

        state.measurementWatermarks = [:]
        XCTAssertEqual(state.importWatermarks["glucose"], instant)
    }

    func testSyncStateDecodesWithoutImportWatermarks() throws {
        let legacy = #"{"measurementWatermarks":{}}"#
        let state = try JSONDecoder().decode(AppleHealthSyncState.self, from: Data(legacy.utf8))
        XCTAssertTrue(state.importWatermarks.isEmpty)
    }
}
