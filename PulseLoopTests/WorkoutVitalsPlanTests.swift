import XCTest
@testable import PulseLoop

/// The capability-driven workout vitals plan: which HR/SpO2 strategy each device family gets.
final class WorkoutVitalsPlanTests: XCTestCase {
    private var prefs = WorkoutPrefs.default

    private let colmiCaps: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .sleep, .battery,
        .remSleep, .stress, .hrv, .temperature,
        .manualHeartRate, .realtimeHeartRate, .realtimeSteps,
        .findDevice, .powerOff, .factoryReset,
        .measurementInterval, .spo2History,
    ]

    private let jringCaps: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .sleep, .battery,
        .bloodPressure, .bloodSugar, .fatigue, .stress, .hrv,
        .manualHeartRate, .manualSpo2, .realtimeHeartRate, .findDevice,
    ]

    func testColmiStreamsWithRingLogSpO2AndIntervalBump() {
        let plan = WorkoutVitalsPlan.plan(for: colmiCaps, prefs: prefs)
        XCTAssertEqual(plan.hrMode, .stream)
        XCTAssertEqual(plan.spo2Mode, .ringLog, "Colmi has no instant SpO2 — never spot-poll it")
        XCTAssertTrue(plan.bumpRingInterval)
        XCTAssertEqual(plan.vitalsModeRaw, "stream")
    }

    func testJringStreamsWithSpotSpO2NoBump() {
        let plan = WorkoutVitalsPlan.plan(for: jringCaps, prefs: prefs)
        XCTAssertEqual(plan.hrMode, .stream)
        XCTAssertEqual(plan.spo2Mode, .spotPoll)
        XCTAssertFalse(plan.bumpRingInterval, "jring has no interval config command")
    }

    func testUnknownDeviceFallsBackToSpotPolling() {
        let plan = WorkoutVitalsPlan.plan(for: [], prefs: prefs)
        XCTAssertEqual(plan, .spotFallback)
        XCTAssertEqual(plan.vitalsModeRaw, "spot")
    }

    func testCaptureTogglesTurnModesOff() {
        var off = prefs
        off.captureHeartRate = false
        off.captureSpO2 = false
        let plan = WorkoutVitalsPlan.plan(for: colmiCaps, prefs: off)
        XCTAssertEqual(plan.hrMode, .off)
        XCTAssertEqual(plan.spo2Mode, .off)
        XCTAssertFalse(plan.bumpRingInterval, "no ring-log bump when HR capture is off")
    }

    func testSpO2OffWhenDeviceHasNeitherSpotNorHistory() {
        let caps: Set<WearableCapability> = [.heartRate, .realtimeHeartRate, .spo2]
        let plan = WorkoutVitalsPlan.plan(for: caps, prefs: prefs)
        XCTAssertEqual(plan.spo2Mode, .off, "declaring .spo2 alone isn't enough to capture during a workout")
    }
}
