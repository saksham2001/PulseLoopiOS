import Foundation

// Bridges between the storage layer (SwiftData models, MetricKey/MetricSample from
// DerivedSummaries.swift) and the pure vitals value types. These helpers used to live in
// ChartSample.swift / VitalsZoneModel.swift; they were moved here so those files carry zero storage
// dependencies and can be compiled into the PulseLoopWidgets extension. App target only.

extension ChartSampleBuilder {
    /// Map stored samples to chart samples, tagging each with a single resolved quality. Samples are
    /// assumed already time-sorted by `metricRange`; we sort defensively anyway.
    static func from(_ samples: [MetricSample], quality: SourceQuality = .good) -> [ChartSample] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChartSample(timestamp: $0.timestamp, value: $0.value, quality: quality) }
    }
}

extension MetricKind {
    /// The storage key this card reads. BP reads `bloodPressureSystolic` for visibility gating; the
    /// card itself pulls both systolic and diastolic series.
    var metricKey: MetricKey {
        switch self {
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .hrv: return .hrv
        case .bloodPressure: return .bloodPressureSystolic
        case .stress: return .stress
        case .fatigue: return .fatigue
        case .glucose: return .bloodSugar
        case .temperature: return .temperature
        }
    }
}

// Kept in an extension so the synthesized memberwise initializer (used by `.unknown`) survives.
extension UserPhysiologyProfile {
    /// Build from a stored `UserProfile`. A nil profile (pre-onboarding) yields `.unknown` defaults.
    init(_ profile: UserProfile?) {
        guard let profile else { self = .unknown; return }
        self.init(
            age: profile.age,
            sex: BiologicalSex(profileSex: profile.sex),
            athleteMode: profile.athleteMode,
            altitudeMeters: profile.altitudeMeters,
            usesBetaBlockers: profile.usesBetaBlockers ?? false,
            hasKnownLungCondition: profile.hasKnownLungCondition ?? false,
            preferredGlucoseUnit: profile.preferredGlucoseUnit
        )
    }
}

extension BaselineStats {
    static func compute(_ samples: [MetricSample]) -> BaselineStats? {
        let values = samples.map(\.value).filter { $0 > 0 }
        guard values.count >= 2 else { return nil }
        let sorted = values.sorted()
        let count = Double(values.count)
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let sd = variance.squareRoot()
        let spanDays: Double
        if let first = samples.map(\.timestamp).min(), let last = samples.map(\.timestamp).max() {
            spanDays = last.timeIntervalSince(first) / 86_400
        } else {
            spanDays = 0
        }
        return BaselineStats(
            mean: mean,
            median: percentile(sorted, 0.50),
            standardDeviation: sd,
            p25: percentile(sorted, 0.25),
            p75: percentile(sorted, 0.75),
            sampleCount: values.count,
            spanDays: spanDays
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
