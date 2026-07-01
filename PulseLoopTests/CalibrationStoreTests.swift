import XCTest
@testable import PulseLoop

/// Pure calibration math: offset derivation and the display-offset application. No hardware/store IO.
@MainActor
final class CalibrationStoreTests: XCTestCase {
    /// An isolated store backed by a throwaway suite so tests never touch the standard defaults.
    private func makeStore() -> CalibrationStore {
        let suite = UserDefaults(suiteName: "calib.test.\(UUID().uuidString)")!
        return CalibrationStore(defaults: suite)
    }

    func testGlucoseOffsetIsReferenceMinusLatestRaw() {
        let store = makeStore()
        store.calibrateGlucose(referenceMgdl: 110, latestRawMgdl: 120)
        XCTAssertEqual(store.settings.glucoseOffsetMgdl, -10, accuracy: 0.001)
        XCTAssertEqual(store.settings.glucoseRefMgdl, 110, accuracy: 0.001)
        // Display applies the offset: a raw 120 reads as 110.
        XCTAssertEqual(store.settings.adjusted(120, kind: .bloodSugar), 110, accuracy: 0.001)
    }

    func testGlucoseResetClearsOffset() {
        let store = makeStore()
        store.calibrateGlucose(referenceMgdl: 110, latestRawMgdl: 120)
        store.resetGlucose()
        XCTAssertEqual(store.settings.glucoseOffsetMgdl, 0)
        XCTAssertEqual(store.settings.adjusted(120, kind: .bloodSugar), 120)
    }

    func testBPOffsetDerivedAgainstLatestRaw() {
        let store = makeStore()
        // Cuff reads 130/85, ring's latest raw was 120/80 → offsets +10/+5.
        store.calibrateBloodPressure(referenceSystolic: 130, referenceDiastolic: 85,
                                     latestRawSystolic: 120, latestRawDiastolic: 80)
        XCTAssertEqual(store.settings.bpSystolicOffset, 10)
        XCTAssertEqual(store.settings.bpDiastolicOffset, 5)
        XCTAssertEqual(store.settings.adjusted(120, kind: .bloodPressureSystolic), 130)
        XCTAssertEqual(store.settings.adjusted(80, kind: .bloodPressureDiastolic), 85)
        XCTAssertTrue(store.settings.hasBPReference)
    }

    func testAdjustedIsIdentityForUncalibratedKinds() {
        let store = makeStore()
        XCTAssertEqual(store.settings.adjusted(72, kind: .heartRate), 72)
        XCTAssertEqual(store.settings.adjusted(98, kind: .spo2), 98)
    }

    func testCalibrationPersistsAcrossInstances() {
        let suite = UserDefaults(suiteName: "calib.test.\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: suite)
        store.calibrateGlucose(referenceMgdl: 100, latestRawMgdl: 90)
        // A fresh store reading the same suite sees the persisted offset.
        let reloaded = CalibrationStore(defaults: suite)
        XCTAssertEqual(reloaded.settings.glucoseOffsetMgdl, 10, accuracy: 0.001)
    }
}
