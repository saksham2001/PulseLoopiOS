import Foundation

/// Unit-aware display helpers driven by the user's `UnitsPreference`. Stored values are always
/// canonical metric (cm/kg/°C, distance in metres); these convert for display. Covers the headline
/// display sites — temperature, distance, pace, and profile body metrics. Step/calorie/HR/SpO₂ values
/// are unitless or universal and don't go through here.
enum UnitsFormatter {
    private static let metersPerMile = 1609.344
    private static let cmPerInch = 2.54
    private static let lbPerKg = 2.2046226

    /// Skin/body temperature. Metric → "36.5", "°C"; imperial → "97.7", "°F".
    static func temperature(celsius: Double, units: UnitsPreference) -> (value: String, unit: String) {
        switch units {
        case .metric:
            return (String(format: "%.1f", celsius), "°C")
        case .imperial:
            return (String(format: "%.1f", celsius * 9 / 5 + 32), "°F")
        }
    }

    /// Distance from canonical metres. Metric → km; imperial → mi (2 decimals).
    static func distance(meters: Double, units: UnitsPreference) -> (value: String, unit: String) {
        switch units {
        case .metric:
            return (String(format: "%.2f", meters / 1000), "km")
        case .imperial:
            return (String(format: "%.2f", meters / metersPerMile), "mi")
        }
    }

    /// Height from canonical cm. Metric → whole cm; imperial → whole inches.
    static func height(cm: Double, units: UnitsPreference) -> (value: String, unit: String) {
        switch units {
        case .metric:
            return ("\(Int(cm.rounded()))", "cm")
        case .imperial:
            return ("\(Int((cm / cmPerInch).rounded()))", "in")
        }
    }

    /// Weight from canonical kg. Metric → kg; imperial → lb (1 decimal).
    static func weight(kg: Double, units: UnitsPreference) -> (value: String, unit: String) {
        switch units {
        case .metric:
            return (String(format: "%.1f", kg), "kg")
        case .imperial:
            return (String(format: "%.1f", kg * lbPerKg), "lb")
        }
    }

    /// The pace denominator label for the user's units.
    static func paceUnit(_ units: UnitsPreference) -> String {
        units == .metric ? "/km" : "/mi"
    }

    /// Convert a per-kilometre pace (seconds) into the user's per-unit pace (seconds): per-mile for
    /// imperial (slower number, since a mile is longer), unchanged for metric.
    static func paceSeconds(perKmSeconds: Double, units: UnitsPreference) -> Double {
        units == .metric ? perKmSeconds : perKmSeconds * (metersPerMile / 1000)
    }
}
