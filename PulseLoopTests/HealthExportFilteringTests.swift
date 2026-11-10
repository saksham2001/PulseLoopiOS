import XCTest
@testable import PulseLoop

/// Android issue #103 / PR #134: estimated hourly SpO₂ and heart-rate-derived respiratory rate never
/// reach Apple Health. Ports Android's `VitalsExporterFilteringTest`.
final class HealthExportFilteringTests: XCTestCase {
    private let spot = Date(timeIntervalSince1970: 1_729_000_000)
    private let hourly = Date(timeIntervalSince1970: 1_729_003_600)

    func testGenuineSpotSpO2IsExported() {
        XCTAssertTrue(HealthKitTypeMappings.shouldExport(kind: .spo2, value: 98, timestamp: spot,
                                                         estimatedSpO2: [hourly, hourly.addingTimeInterval(3600)]))
    }

    func testHourlySpO2EstimatedFromHeartRateIsExcluded() {
        XCTAssertFalse(HealthKitTypeMappings.shouldExport(kind: .spo2, value: 98, timestamp: hourly,
                                                          estimatedSpO2: [hourly, hourly.addingTimeInterval(3600)]))
    }

    func testImplausibleSpO2IsExcludedEvenIfNotEstimated() {
        XCTAssertFalse(HealthKitTypeMappings.shouldExport(kind: .spo2, value: 105, timestamp: spot))
        XCTAssertFalse(HealthKitTypeMappings.shouldExport(kind: .spo2, value: 0, timestamp: spot))
    }

    func testRespiratoryRateFromAYCBTRingIsExcluded() {
        // YCBT rings derive respiratory rate as ~0.2 × HR without a real sensor.
        XCTAssertFalse(HealthKitTypeMappings.shouldExport(kind: .respiratoryRate, value: 16, timestamp: spot,
                                                          respiratoryRateDerived: true))
    }

    func testRespiratoryRateFromARingWithoutThatDerivationIsExported() {
        XCTAssertTrue(HealthKitTypeMappings.shouldExport(kind: .respiratoryRate, value: 16, timestamp: spot,
                                                         respiratoryRateDerived: false))
    }

    func testImplausibleRespiratoryRateIsExcludedOnAnyRing() {
        XCTAssertFalse(HealthKitTypeMappings.shouldExport(kind: .respiratoryRate, value: 0, timestamp: spot))
        XCTAssertFalse(HealthKitTypeMappings.shouldExport(kind: .respiratoryRate, value: 100, timestamp: spot))
    }

    /// Every YCBT family derives it; no other family does, and an unknown device is not assumed to.
    func testOnlyYCBTFamiliesDeriveRespiratoryRate() {
        for type in RingDeviceType.allCases {
            XCTAssertEqual(HealthKitTypeMappings.derivesRespiratoryRate(type),
                           [.tk5, .colmiSmartHealth, .ycbt].contains(type), "\(type)")
        }
        XCTAssertFalse(HealthKitTypeMappings.derivesRespiratoryRate(nil))
    }

    /// The estimate set only ever gates SpO₂; another kind at the same instant is unaffected.
    func testEstimatedSetDoesNotGateOtherKinds() {
        XCTAssertTrue(HealthKitTypeMappings.shouldExport(kind: .heartRate, value: 70, timestamp: hourly,
                                                         estimatedSpO2: [hourly], respiratoryRateDerived: true))
    }
}
