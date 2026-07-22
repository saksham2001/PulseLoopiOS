import SwiftUI

// The app ↔ home-screen-widget data contract. Compiled into BOTH the app target and the
// PulseLoopWidgets extension (like `WorkoutActivityAttributes.swift`), so keep it free of SwiftData
// models and app services.
//
// Why a JSON snapshot instead of sharing the SwiftData store: widget data only changes when the app
// syncs with the ring over BLE — the extension can never fetch fresher data than the app last wrote.
// So the app projects the already-interpreted Today tile state (`VitalCardViewModel` et al.) into
// plain Codable payloads, writes one small JSON file into the app-group container, and reloads the
// widget timelines. The widget decodes in milliseconds and renders with the same shared design-system
// views — no store, no threshold engine, no 22-model schema inside a ~30 MB extension.
//
// Colors cross the process boundary two ways, both lossless:
// - Zone/band colors as `VitalColorToken` strings (round-trip via the shared token enum, so a
//   reconstructed `MetricZone` renders exactly like the in-app one).
// - Already-resolved colors (status color, chart line interval colors, sleep stage colors) as hex,
//   rebuilt with the shared `Color(hex:)`.

// MARK: - Storage location

enum PulseWidgetStore {
    static let suite = "group.xyz.sakshambhutani.pulseloop2"
    static let fileName = "widget-snapshot.json"
    /// Shared-defaults key holding the Date of the last background-triggered timeline reload
    /// (foreground reloads are free of the WidgetKit refresh budget; background ones are throttled).
    static let lastBackgroundReloadKey = "widgetLastBackgroundReload"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suite)?
            .appendingPathComponent(fileName)
    }
}

// MARK: - Snapshot root

struct WidgetSnapshot: Codable {
    /// When the app built this snapshot — drives the widget's "as of" staleness footer.
    var generatedAt: Date
    /// Start-of-day the activity/sleep payloads belong to. Entries after midnight compare against
    /// this so yesterday's steps are never presented as today's.
    var dayStart: Date
    var activity: WidgetActivityPayload?
    var sleep: WidgetSleepPayload?
    /// Keyed by `MetricKind.rawValue`.
    var metrics: [String: WidgetMetricPayload]
}

// MARK: - Activity (concentric rings tile)

struct WidgetActivityPayload: Codable {
    /// Ring inputs (nil value = metric unavailable → track only), matching `ActivityTileView`.
    var steps: Double?
    var stepsGoal: Double
    /// Distance already converted to the user's display unit (km or mi), like the in-app tile.
    var distanceDisplay: Double?
    var distanceGoalDisplay: Double
    /// "KM" or "MI".
    var distanceUnitLabel: String
    var calories: Double?
    var caloriesGoal: Double
    /// Preformatted label-stack texts (steps grouping, 2-decimal distance, whole calories). Missing
    /// metrics are nil and skipped, exactly like the tile.
    var stepsText: String?
    var distanceText: String?
    var caloriesText: String?
}

// MARK: - Sleep (duration + stage bar + score tile)

struct WidgetSleepPayload: Codable {
    struct Segment: Codable {
        var minutes: Double
        var colorHex: String
        var label: String
    }

    var durationText: String
    var score: Int
    var segments: [Segment]
}

// MARK: - Vitals metric (chart / gauge / BP tiles)

struct WidgetSamplePayload: Codable {
    var t: Date
    var v: Double
}

struct WidgetZonePayload: Codable {
    var id: String
    var label: String
    var lower: Double?
    var upper: Double?
    var severityRaw: Int
    var colorToken: String
}

struct WidgetBandPayload: Codable {
    var lower: Double
    var upper: Double
    var colorToken: String
    var opacity: Double
}

/// A serializable projection of `VitalCardViewModel` — everything a Today chart/gauge/BP tile needs,
/// with all interpretation (thresholds, baselines, calibration) already baked in by the app.
struct WidgetMetricPayload: Codable {
    /// `MetricKind.rawValue`; the widget maps it back for accents/titles/chart identity.
    var kind: String
    var title: String
    var valueText: String
    var unitText: String?
    var statusText: String
    /// The resolved status color (gauge value arc / status label), as hex.
    var statusColorHex: String
    var isEmpty: Bool

    // Chart tile inputs (downsampled ≤ 48 points).
    var samples: [WidgetSamplePayload]
    var yLower: Double
    var yUpper: Double
    var referenceBands: [WidgetBandPayload]
    var dashedRules: [Double]
    /// Sorted interior zone boundaries where the line color changes…
    var thresholds: [Double]
    /// …and the resolved line color for each of the `thresholds.count + 1` intervals (hex). Encodes
    /// the threshold engine's value→color mapping (including HRV's baseline-relative case) as a step
    /// function, so the widget reproduces `TodayChartTile` coloring without the engine.
    var intervalColorHexes: [String]

    // Gauge tile inputs.
    var zones: [WidgetZonePayload]

    // Blood-pressure extras (dual gauge).
    var systolic: Double?
    var diastolic: Double?
    var systolicZones: [WidgetZonePayload]
    var diastolicZones: [WidgetZonePayload]

    /// The step-function lookup for chart line coloring. Falls back to the status color when the
    /// interval list is missing/mismatched (defensive against old snapshots).
    func lineColor(forValue value: Double) -> Color {
        guard intervalColorHexes.count == thresholds.count + 1 else { return Color(hex: statusColorHex) }
        // First threshold strictly above the value marks the interval (zones are half-open [lo, hi)).
        let index = thresholds.firstIndex(where: { value < $0 }) ?? thresholds.count
        return Color(hex: intervalColorHexes[index])
    }
}

// MARK: - Token string bridge

extension VitalColorToken {
    private static let accentPrefix = "accent:"

    var tokenString: String {
        switch self {
        case .blue: return "blue"
        case .mint: return "mint"
        case .cyan: return "cyan"
        case .amber: return "amber"
        case .softAmber: return "softAmber"
        case .orange: return "orange"
        case .red: return "red"
        case .brightRed: return "brightRed"
        case .deepRed: return "deepRed"
        case .neutral: return "neutral"
        case .metricAccent(let metric): return Self.accentPrefix + metric.rawValue
        }
    }

    init(tokenString: String) {
        switch tokenString {
        case "blue": self = .blue
        case "mint": self = .mint
        case "cyan": self = .cyan
        case "amber": self = .amber
        case "softAmber": self = .softAmber
        case "orange": self = .orange
        case "red": self = .red
        case "brightRed": self = .brightRed
        case "deepRed": self = .deepRed
        default:
            if tokenString.hasPrefix(Self.accentPrefix),
               let metric = MetricKind(rawValue: String(tokenString.dropFirst(Self.accentPrefix.count))) {
                self = .metricAccent(metric)
            } else {
                self = .neutral
            }
        }
    }
}

// MARK: - Payload ↔ render-type converters

extension WidgetZonePayload {
    init(_ zone: MetricZone) {
        self.init(id: zone.id, label: zone.label, lower: zone.lower, upper: zone.upper,
                  severityRaw: zone.severity.rawValue, colorToken: zone.colorToken.tokenString)
    }

    /// Rebuild the real render input. `explanation` is detail-screen-only, so it doesn't cross over.
    var metricZone: MetricZone {
        MetricZone(id: id, label: label, lower: lower, upper: upper,
                   severity: ZoneSeverity(rawValue: severityRaw) ?? .unknown,
                   colorToken: VitalColorToken(tokenString: colorToken), explanation: "")
    }
}

extension WidgetBandPayload {
    init(_ band: ReferenceBand) {
        self.init(lower: band.lower, upper: band.upper,
                  colorToken: band.colorToken.tokenString, opacity: band.opacity)
    }

    var referenceBand: ReferenceBand {
        ReferenceBand(lower: lower, upper: upper,
                      colorToken: VitalColorToken(tokenString: colorToken), opacity: opacity)
    }
}

extension WidgetSamplePayload {
    var chartSample: ChartSample { ChartSample(timestamp: t, value: v) }
}
