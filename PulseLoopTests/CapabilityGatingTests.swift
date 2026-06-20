import XCTest
import SwiftData
@testable import PulseLoop

/// The product UI gates metric cards on the active device's capabilities. A jring hides
/// HRV/Stress/Temperature; a Colmi R02 shows them. These assertions drive off `Device.capabilities`
/// via `MetricsService.supports`.
@MainActor
final class CapabilityGatingTests: XCTestCase {

    func testJringHidesColmiOnlyMetrics() throws {
        let context = try TestSupport.makeContext()
        let jring = Device(deviceType: .jring, capabilities: [.heartRate, .spo2, .steps, .sleep, .battery])
        context.insert(jring)
        try context.save()

        XCTAssertTrue(MetricsService.supports(.heartRate, context: context))
        XCTAssertTrue(MetricsService.supports(.spo2, context: context))
        XCTAssertFalse(MetricsService.supports(.hrv, context: context))
        XCTAssertFalse(MetricsService.supports(.stress, context: context))
        XCTAssertFalse(MetricsService.supports(.temperature, context: context))
    }

    func testColmiShowsRichMetrics() throws {
        let context = try TestSupport.makeContext()
        let colmi = Device(
            deviceType: .colmiR02,
            capabilities: [.heartRate, .spo2, .steps, .sleep, .battery, .stress, .hrv, .temperature, .remSleep]
        )
        context.insert(colmi)
        try context.save()

        XCTAssertTrue(MetricsService.supports(.heartRate, context: context))
        XCTAssertTrue(MetricsService.supports(.hrv, context: context))
        XCTAssertTrue(MetricsService.supports(.stress, context: context))
        XCTAssertTrue(MetricsService.supports(.temperature, context: context))
    }

    func testManualSpo2GatingDiffersByDevice() {
        // jring supports an on-demand SpO2 spot reading; Colmi does not (SpO2 is all-day only).
        XCTAssertTrue(JringCoordinator().capabilities.contains(.manualSpo2))
        XCTAssertFalse(ColmiCoordinator().capabilities.contains(.manualSpo2))
        // Both still expose SpO2 history (the graph) and manual HR.
        XCTAssertTrue(JringCoordinator().capabilities.contains(.spo2))
        XCTAssertTrue(ColmiCoordinator().capabilities.contains(.spo2))
        XCTAssertTrue(ColmiCoordinator().capabilities.contains(.manualHeartRate))
    }

    func testLegacyDeviceFallsBackToBaseMetrics() throws {
        // A device row that predates capability stamping (empty capabilitiesRaw) should still show
        // the base metrics so existing users don't lose HR/SpO₂.
        let context = try TestSupport.makeContext()
        let legacy = Device(deviceType: .jring, capabilities: [])
        context.insert(legacy)
        try context.save()

        XCTAssertTrue(MetricsService.supports(.heartRate, context: context))
        XCTAssertTrue(MetricsService.supports(.spo2, context: context))
        XCTAssertFalse(MetricsService.supports(.hrv, context: context))
    }

    func testCapabilityCSVRoundTrip() {
        let caps: Set<WearableCapability> = [.heartRate, .hrv, .temperature]
        let restored = Set<WearableCapability>(csv: caps.csv)
        XCTAssertEqual(caps, restored)
    }
}
