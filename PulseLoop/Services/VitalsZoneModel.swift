import SwiftUI

// Value types backing the centralized vitals reference-range / threshold engine.
//
// These mirror the medical reference ranges encoded in `VitalsThresholdEngine`. Nothing here is a
// diagnosis — labels are deliberately conservative ("Typical", "Elevated", "Talk to a clinician if
// persistent") and ring-estimated metrics (BP, glucose, fatigue) are always flagged `isEstimated`.
//
// Design rule: colors resolve in exactly one place (`VitalColorToken.color`), which maps to
// `PulseColors`. Views, charts, gauges, and legends all go through tokens — no hex anywhere else.

// MARK: - Metric identity

/// The physiological metrics the threshold engine interprets. Distinct from `MetricKey` (the storage
/// key) because blood pressure is a single *card* driven by two stored series (systolic + diastolic).
enum MetricKind: String, CaseIterable, Hashable, Identifiable {
    case heartRate
    case spo2
    case hrv
    case bloodPressure
    case stress
    case fatigue
    case glucose
    case temperature

    var id: String { rawValue }

    // `metricKey` (the storage-key mapping) lives in Services/VitalsModelBridge.swift so this file
    // stays free of storage types and can be shared with the widget extension.

    var title: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .spo2: return "Blood oxygen"
        case .hrv: return "HRV"
        case .bloodPressure: return "Blood pressure"
        case .stress: return "Stress"
        case .fatigue: return "Fatigue"
        case .glucose: return "Blood sugar"
        case .temperature: return "Skin temperature"
        }
    }

    /// Display unit shown after the big value. Empty for unit-less device scores.
    var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .spo2: return "%"
        case .hrv: return "ms"
        case .bloodPressure: return "mmHg"
        case .stress, .fatigue: return ""
        case .glucose: return "mg/dL"
        case .temperature: return "°C"
        }
    }

    var accentToken: VitalColorToken { .metricAccent(self) }
}

// MARK: - Severity

/// Ordered worst-to-best for "worse of" comparisons (e.g. blood pressure category = worse of
/// systolic and diastolic). `unknown` sorts last and is handled separately so it never wins a `max`.
enum ZoneSeverity: Int, Comparable {
    case optimal = 0
    case normal
    case watch
    case high
    case critical
    case unknown

    static func < (lhs: ZoneSeverity, rhs: ZoneSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The worse (more severe) of two severities, treating `unknown` as "no information" so a real
    /// category always wins over it.
    static func worst(_ a: ZoneSeverity, _ b: ZoneSeverity) -> ZoneSeverity {
        if a == .unknown { return b }
        if b == .unknown { return a }
        return a.rawValue >= b.rawValue ? a : b
    }

    /// A neutral fallback token. Color is NOT derived from severity anymore — each `MetricZone`
    /// carries its own explicit `colorToken` (the per-metric palette). Severity only orders zones
    /// and drives the BP "worse-of" rule.
    var fallbackColorToken: VitalColorToken {
        switch self {
        case .optimal: return .mint
        case .normal: return .cyan
        case .watch: return .amber
        case .high: return .orange
        case .critical: return .red
        case .unknown: return .neutral
        }
    }
}

// MARK: - Color tokens

/// Explicit vitals color token. The single `color` switch maps to `PulseColors` — never duplicate
/// hex elsewhere. Each `MetricZone` picks its token from this palette so the chart line, reference
/// band, gauge arc, stat dot, and status label are always the same color for the same zone.
/// `metricAccent` resolves to the metric's brand color (heart pink, HRV purple…) — used where a
/// metric's "normal" zone should read as its own accent.
enum VitalColorToken: Equatable {
    case blue          // low / cool
    case mint          // optimal / typical
    case cyan          // normal (where the accent isn't the normal color)
    case amber         // caution
    case softAmber     // slight caution
    case orange        // elevated / low-oxygen / stage 1
    case red           // high / critical
    case brightRed     // a deeper/brighter red where the plain accent is already reddish (HR high)
    case neutral       // no information (building baseline)
    case metricAccent(MetricKind)

    var color: Color {
        switch self {
        case .blue: return PulseColors.zoneBlue
        case .mint: return PulseColors.zoneMint
        case .cyan: return PulseColors.zoneCyan
        case .amber: return PulseColors.zoneAmber
        case .softAmber: return PulseColors.zoneSoftAmber
        case .orange: return PulseColors.zoneOrange
        case .red: return PulseColors.zoneRed
        case .brightRed: return PulseColors.zoneCritical
        case .neutral: return PulseColors.textMuted
        case .metricAccent(let metric): return metric.accentColor
        }
    }
}

extension MetricKind {
    /// The brand accent color for this metric, drawn from `PulseColors`.
    var accentColor: Color {
        switch self {
        case .heartRate: return PulseColors.heartRate
        case .spo2: return PulseColors.spo2
        case .hrv: return PulseColors.hrv
        case .bloodPressure: return PulseColors.bloodPressure
        case .stress: return PulseColors.stress
        case .fatigue: return PulseColors.fatigue
        case .glucose: return PulseColors.bloodSugar
        case .temperature: return PulseColors.temperature
        }
    }
}

// MARK: - Zones

/// One reference band of a metric (e.g. "Normal 60–100 bpm"). `lower`/`upper` are nil for
/// open-ended ends. `contains` uses a half-open interval `[lower, upper)` so adjacent zones don't
/// both claim a boundary value.
struct MetricZone: Identifiable, Equatable {
    let id: String
    let label: String
    let lower: Double?
    let upper: Double?
    let severity: ZoneSeverity
    let colorToken: VitalColorToken
    let explanation: String

    func contains(_ value: Double) -> Bool {
        let aboveLower = lower.map { value >= $0 } ?? true
        let belowUpper = upper.map { value < $0 } ?? true
        return aboveLower && belowUpper
    }

    var color: Color { colorToken.color }
}

// MARK: - User physiology inputs

enum BiologicalSex: String {
    case female
    case male
    case unspecified

    init(profileSex: String?) {
        switch profileSex?.lowercased() {
        case "female": self = .female
        case "male": self = .male
        default: self = .unspecified
        }
    }
}

enum GlucoseUnit: String, Codable, CaseIterable, Identifiable {
    case mgdl
    case mmol

    var id: String { rawValue }
    var label: String { self == .mgdl ? "mg/dL" : "mmol/L" }
}

/// The physiology inputs that shift reference ranges. Built from `UserProfile`; every field is
/// optional so the engine degrades gracefully when the profile is incomplete. Athlete mode,
/// altitude, beta-blockers, lung condition, and glucose unit come from new `UserProfile` fields.
struct UserPhysiologyProfile {
    let age: Int?
    let sex: BiologicalSex
    let athleteMode: Bool
    let altitudeMeters: Double?
    let usesBetaBlockers: Bool
    let hasKnownLungCondition: Bool
    let preferredGlucoseUnit: GlucoseUnit

    /// A neutral default used when no profile exists yet (onboarding not done).
    static let unknown = UserPhysiologyProfile(
        age: nil, sex: .unspecified, athleteMode: false, altitudeMeters: nil,
        usesBetaBlockers: false, hasKnownLungCondition: false, preferredGlucoseUnit: .mgdl
    )

    /// Age-predicted maximum heart rate (`220 − age`), used for effort-zone overlays. Falls back to
    /// 190 when age is unknown.
    var maxHeartRate: Double {
        guard let age, age > 0 else { return 190 }
        return Double(220 - age)
    }
}

// The `UserProfile`-backed initializer lives in Services/VitalsModelBridge.swift so this file stays
// free of SwiftData model types and can be shared with the widget extension.

// MARK: - Measurement context & source quality

/// The circumstance a reading was taken under. Glucose interpretation needs this to choose fasting
/// vs post-meal thresholds; today it is almost always `.unknown` (per-reading tagging is deferred),
/// which forces the engine onto conservative, non-diagnostic labels.
enum MeasurementContext {
    case resting
    case sleeping
    case active
    case fasting
    case postMeal
    case random
    case unknown
}

/// How much to trust a reading. Derived from timestamps + calibration state at display time — never
/// persisted. Drives chip styling and line opacity, not the medical category.
enum SourceQuality {
    case good
    case motionArtifact
    case looseFit
    case stale
    case estimated
    case needsCalibration
    case unknown

    /// Whether to surface an "Estimated" treatment (chip / disclaimer).
    var isEstimated: Bool { self == .estimated || self == .needsCalibration }
}

struct MetricContext {
    let timeRange: MetricRange
    let measurement: MeasurementContext
    let sourceQuality: SourceQuality

    init(timeRange: MetricRange = .twentyFourHours,
         measurement: MeasurementContext = .unknown,
         sourceQuality: SourceQuality = .good) {
        self.timeRange = timeRange
        self.measurement = measurement
        self.sourceQuality = sourceQuality
    }
}

// MARK: - Baseline statistics

/// Rolling baseline computed from already-fetched samples. HRV interpretation is baseline-driven
/// (deviation from the user's own typical range), not absolute. `isEstablished` gates the
/// "Building baseline" state — under the dashboard's 24h fetch this is usually false; the detail
/// screen (30-day fetch) produces a real baseline.
struct BaselineStats: Equatable {
    let mean: Double
    let median: Double
    let standardDeviation: Double
    let p25: Double
    let p75: Double
    let sampleCount: Int
    let spanDays: Double

    /// A baseline is meaningful once it spans roughly a week of wear with enough samples.
    var isEstablished: Bool { spanDays >= 7 && sampleCount >= 20 }

    // `compute(_: [MetricSample])` lives in Services/VitalsModelBridge.swift so this file stays free
    // of storage types and can be shared with the widget extension.
}

// MARK: - Interpretation result

/// The engine's verdict for a value: which zone it lands in, the full zone set (for legends/bands),
/// a user-facing label/explanation, and an optional confidence caveat.
struct MetricInterpretation: Equatable {
    let primaryZone: MetricZone
    let allZones: [MetricZone]
    let displayLabel: String
    let explanation: String
    let confidenceLabel: String?
    let isEstimated: Bool

    var statusColor: Color { primaryZone.color }
}
