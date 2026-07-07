import AppIntents
import SwiftUI

/// The metrics a user can put on a configurable home-screen widget — every Today-page tile. Raw
/// values are stable identifiers persisted in the user's widget configuration; don't rename them.
enum WidgetMetric: String, CaseIterable, AppEnum {
    case activity
    case sleep
    case heartRate
    case spo2
    case hrv
    case temperature
    case stress
    case fatigue
    case bloodPressure
    case glucose

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"

    static let caseDisplayRepresentations: [WidgetMetric: DisplayRepresentation] = [
        .activity: "Activity",
        .sleep: "Sleep",
        .heartRate: "Heart Rate",
        .spo2: "Blood Oxygen",
        .hrv: "HRV",
        .temperature: "Skin Temperature",
        .stress: "Stress",
        .fatigue: "Fatigue",
        .bloodPressure: "Blood Pressure",
        .glucose: "Blood Sugar",
    ]

    /// The vitals kind whose payload backs this tile; nil for the two non-vitals tiles.
    var metricKind: MetricKind? {
        switch self {
        case .activity, .sleep: return nil
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .hrv: return .hrv
        case .temperature: return .temperature
        case .stress: return .stress
        case .fatigue: return .fatigue
        case .bloodPressure: return .bloodPressure
        case .glucose: return .glucose
        }
    }

    /// Which Today tile visual this metric renders as (mirrors `TodayView.tiles`).
    enum TileStyle {
        case rings, sleep, chart, gauge, bloodPressure
    }

    var tileStyle: TileStyle {
        switch self {
        case .activity: return .rings
        case .sleep: return .sleep
        case .heartRate, .spo2, .hrv, .temperature: return .chart
        case .stress, .fatigue, .glucose: return .gauge
        case .bloodPressure: return .bloodPressure
        }
    }

    /// Header eyebrow label + dot color, matching the in-app `TodayTile` chrome.
    var headerLabel: String {
        switch self {
        case .activity: return "Activity"
        case .sleep: return "Sleep"
        default: return metricKind?.title ?? rawValue
        }
    }

    var accentColor: Color {
        switch self {
        case .activity: return PulseColors.steps
        case .sleep: return PulseColors.sleep
        default: return metricKind?.accentColor ?? PulseColors.accent
        }
    }
}
