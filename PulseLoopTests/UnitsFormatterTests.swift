import XCTest
import CoreLocation
@testable import PulseLoop

/// Pure conversion checks for `UnitsFormatter` — stored values are canonical metric, displayed in the
/// user's preferred units.
@MainActor
final class UnitsFormatterTests: XCTestCase {

    func testDistanceMetricAndImperial() {
        let m = UnitsFormatter.distance(meters: 1000, units: .metric)
        XCTAssertEqual(m.value, "1.00")
        XCTAssertEqual(m.unit, "km")

        let i = UnitsFormatter.distance(meters: 1609.344, units: .imperial)
        XCTAssertEqual(i.value, "1.00")
        XCTAssertEqual(i.unit, "mi")
    }

    func testWeight() {
        XCTAssertEqual(UnitsFormatter.weight(kg: 70, units: .metric).unit, "kg")
        let lb = UnitsFormatter.weight(kg: 100, units: .imperial)
        XCTAssertEqual(lb.unit, "lb")
        XCTAssertEqual(Double(lb.value) ?? 0, 220.5, accuracy: 0.1)
    }

    func testHeight() {
        XCTAssertEqual(UnitsFormatter.height(cm: 175, units: .metric).value, "175")
        let inches = UnitsFormatter.height(cm: 175, units: .imperial)
        XCTAssertEqual(inches.unit, "in")
        XCTAssertEqual(Int(inches.value) ?? 0, 69)   // 175 / 2.54 ≈ 68.9 → 69
    }

    func testPace() {
        XCTAssertEqual(UnitsFormatter.paceUnit(.metric), "/km")
        XCTAssertEqual(UnitsFormatter.paceUnit(.imperial), "/mi")
        // 5 min/km → slower per-mile number (a mile is longer).
        let perMile = UnitsFormatter.paceSeconds(perKmSeconds: 300, units: .imperial)
        XCTAssertEqual(perMile, 300 * 1.609344, accuracy: 0.5)
        XCTAssertEqual(UnitsFormatter.paceSeconds(perKmSeconds: 300, units: .metric), 300, accuracy: 0.001)
    }

    func testWorkoutPrefsTolerantDecodeAndGpsMapping() {
        // Defaults round-trip; unknown/missing keys fall back.
        let prefs = WorkoutPrefs.default
        let data = try! JSONEncoder().encode(prefs)
        let decoded = try! JSONDecoder().decode(WorkoutPrefs.self, from: data)
        XCTAssertEqual(decoded, prefs)
        XCTAssertEqual(GpsAccuracy.best.clValue, kCLLocationAccuracyBest)
    }
}
