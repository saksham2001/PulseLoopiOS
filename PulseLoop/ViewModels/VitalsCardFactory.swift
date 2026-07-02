import SwiftUI

/// Builds `VitalCardViewModel`s from the store's raw sample arrays + the user's physiology profile.
/// All threshold/baseline/trend/label math lives here (called once per rebuild), so views stay
/// declarative. BP is special: it consumes two series and produces a single card.
@MainActor
enum VitalsCardFactory {
    /// Input bundle so the call site (the store) stays terse and the factory is unit-testable.
    struct Inputs {
        var hr: [MetricSample] = []
        var spo2: [MetricSample] = []
        var hrv: [MetricSample] = []
        var stress: [MetricSample] = []
        var fatigue: [MetricSample] = []
        var temperature: [MetricSample] = []
        var systolic: [MetricSample] = []
        var diastolic: [MetricSample] = []
        var glucose: [MetricSample] = []
        var summary: TodaySummary?
        var range: MetricRange = .twentyFourHours
        var now: Date = Date()
    }

    static func card(_ metric: MetricKind,
                     inputs: Inputs,
                     profile: UserPhysiologyProfile,
                     calibration: Calibration) -> VitalCardViewModel {
        switch metric {
        case .heartRate: return heartRate(inputs, profile, calibration)
        case .spo2: return spo2(inputs, profile, calibration)
        case .hrv: return hrv(inputs, profile, calibration)
        case .stress: return scoreCard(.stress, samples: inputs.stress, inputs: inputs, profile: profile, calibration: calibration)
        case .fatigue: return scoreCard(.fatigue, samples: inputs.fatigue, inputs: inputs, profile: profile, calibration: calibration)
        case .temperature: return temperature(inputs, profile, calibration)
        case .bloodPressure: return bloodPressure(inputs, profile, calibration)
        case .glucose: return glucose(inputs, profile, calibration)
        }
    }

    // MARK: - Heart rate

    private static func heartRate(_ inputs: Inputs, _ profile: UserPhysiologyProfile, _ cal: Calibration) -> VitalCardViewModel {
        let samples = inputs.hr
        let latest = samples.last?.value ?? inputs.summary?.latestHeartRate?.value
        let quality = SourceQualityResolver.quality(for: .heartRate, latest: samples.last?.timestamp, now: inputs.now, calibration: cal)
        let interp = latest.map { VitalsThresholdEngine.interpret(value: $0, metric: .heartRate, profile: profile) }

        let valueText = TodayInsights.hrRangeLabel(samples, latest)
        let resting = inputs.summary?.restingHeartRateEstimate.map { "Resting \(Int($0))" } ?? "Resting calibrating"
        let peak = inputs.summary?.peakHeartRateToday.map { "Peak \(Int($0))" } ?? "Peak —"
        let chart = ChartSampleBuilder.from(samples, quality: quality)
        let domain = clampedDomain(samples, fallback: 40...140, pad: 8, hardLower: 40, hardUpper: 220)
        return VitalCardViewModel(
            metric: .heartRate, title: MetricKind.heartRate.title,
            valueText: valueText, unitText: latest != nil ? "bpm range" : nil,
            statusText: interp?.displayLabel ?? "No reading", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            subtitleText: "\(resting) · \(peak)",
            samples: chart, zones: VitalsThresholdEngine.zones(for: .heartRate, profile: profile),
            yDomain: domain, referenceBands: bands(for: .heartRate, profile: profile, domain: domain),
            dashedRules: [],
            trend: TrendSummary.compute(samples: chart, metric: .heartRate, unitLabel: "bpm"),
            sourceQuality: quality, isEstimated: false, confidenceLabel: nil,
            lastUpdatedText: lastUpdated(samples.last?.timestamp, now: inputs.now),
            isEmpty: samples.count < 2
        )
    }

    // MARK: - SpO₂

    private static func spo2(_ inputs: Inputs, _ profile: UserPhysiologyProfile, _ cal: Calibration) -> VitalCardViewModel {
        let samples = inputs.spo2
        let latest = samples.last?.value ?? inputs.summary?.latestSpO2?.value
        let quality = SourceQualityResolver.quality(for: .spo2, latest: samples.last?.timestamp, now: inputs.now, calibration: cal)
        let interp = latest.map { VitalsThresholdEngine.interpret(value: $0, metric: .spo2, profile: profile) }
        let lowest = samples.map(\.value).filter { $0 > 0 }.min()
        let subtitle = lowest.map { "Lowest \(Int($0)) · \(samples.count) readings" }
        let chart = ChartSampleBuilder.from(samples, quality: quality)
        return VitalCardViewModel(
            metric: .spo2, title: MetricKind.spo2.title,
            valueText: TodayInsights.averageLabel(samples, latest), unitText: latest != nil ? "% avg" : nil,
            statusText: interp?.displayLabel ?? "No reading", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            subtitleText: subtitle,
            samples: chart, zones: VitalsThresholdEngine.zones(for: .spo2, profile: profile),
            yDomain: 88...100,
            referenceBands: [ReferenceBand(lower: 95, upper: 100, colorToken: .cyan)],
            dashedRules: [92],
            trend: TrendSummary.compute(samples: chart, metric: .spo2, unitLabel: "%"),
            sourceQuality: quality, isEstimated: false, confidenceLabel: nil,
            lastUpdatedText: lastUpdated(samples.last?.timestamp, now: inputs.now),
            isEmpty: samples.count < 2
        )
    }

    // MARK: - HRV (baseline-relative)

    private static func hrv(_ inputs: Inputs, _ profile: UserPhysiologyProfile, _ cal: Calibration) -> VitalCardViewModel {
        let samples = inputs.hrv
        let baseline = BaselineStats.compute(samples)
        let latest = samples.last?.value
        let quality = SourceQualityResolver.quality(for: .hrv, latest: samples.last?.timestamp, now: inputs.now, calibration: cal)
        let interp = latest.map { VitalsThresholdEngine.interpret(value: $0, metric: .hrv, profile: profile, baseline: baseline) }
        let chart = ChartSampleBuilder.from(samples, quality: quality)
        let domain = clampedDomain(samples, fallback: 0...120, pad: 10, hardLower: 0, hardUpper: 250)
        var bands: [ReferenceBand] = []
        if let baseline, baseline.isEstablished {
            let half = max(6, baseline.mean * 0.12)
            bands = [ReferenceBand(lower: baseline.mean - half, upper: baseline.mean + half,
                                   colorToken: .metricAccent(.hrv), opacity: 0.12)]
        }
        let subtitle: String?
        if let baseline, baseline.isEstablished {
            subtitle = "Baseline \(Int(baseline.mean)) ms"
        } else {
            subtitle = "Building baseline"
        }
        return VitalCardViewModel(
            metric: .hrv, title: MetricKind.hrv.title,
            valueText: latest.map { "\(Int($0))" } ?? "--", unitText: latest != nil ? "ms" : nil,
            statusText: interp?.displayLabel ?? "Building baseline", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            subtitleText: subtitle,
            samples: chart, zones: VitalsThresholdEngine.zones(for: .hrv, profile: profile, baseline: baseline),
            yDomain: domain, referenceBands: bands, dashedRules: baseline.map { [$0.mean] } ?? [],
            trend: TrendSummary.compute(samples: chart, metric: .hrv, baseline: baseline, unitLabel: "ms"),
            sourceQuality: quality, isEstimated: false, confidenceLabel: interp?.confidenceLabel,
            lastUpdatedText: lastUpdated(samples.last?.timestamp, now: inputs.now),
            isEmpty: samples.count < 2
        )
    }

    // MARK: - Stress / Fatigue (device 0–100 scores)

    private static func scoreCard(_ metric: MetricKind, samples: [MetricSample], inputs: Inputs,
                                  profile: UserPhysiologyProfile, calibration cal: Calibration) -> VitalCardViewModel {
        let latest = samples.last?.value
        let quality = SourceQualityResolver.quality(for: metric, latest: samples.last?.timestamp, now: inputs.now, calibration: cal)
        let interp = latest.map { VitalsThresholdEngine.interpret(value: $0, metric: metric, profile: profile) }
        let chart = ChartSampleBuilder.from(samples, quality: quality)
        let subtitle = metric == .stress ? "Lower is calmer" : "Ring model estimate"
        return VitalCardViewModel(
            metric: metric, title: metric.title,
            valueText: latest.map { "\(Int($0))" } ?? "--", unitText: nil,
            statusText: interp?.displayLabel ?? "No data", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            subtitleText: subtitle,
            samples: chart, zones: VitalsThresholdEngine.zones(for: metric, profile: profile),
            yDomain: 0...100, referenceBands: [], dashedRules: [],
            trend: TrendSummary.compute(samples: chart, metric: metric),
            sourceQuality: quality, isEstimated: false, confidenceLabel: nil,
            lastUpdatedText: lastUpdated(samples.last?.timestamp, now: inputs.now),
            isEmpty: latest == nil
        )
    }

    // MARK: - Temperature

    private static func temperature(_ inputs: Inputs, _ profile: UserPhysiologyProfile, _ cal: Calibration) -> VitalCardViewModel {
        let samples = inputs.temperature
        let latest = samples.last?.value
        let quality = SourceQualityResolver.quality(for: .temperature, latest: samples.last?.timestamp, now: inputs.now, calibration: cal)
        let interp = latest.map { VitalsThresholdEngine.interpret(value: $0, metric: .temperature, profile: profile) }
        let chart = ChartSampleBuilder.from(samples, quality: quality)
        let domain = clampedDomain(samples, fallback: 30...38, pad: 0.5, hardLower: 20, hardUpper: 45)
        return VitalCardViewModel(
            metric: .temperature, title: MetricKind.temperature.title,
            valueText: latest.map { String(format: "%.1f", $0) } ?? "--", unitText: latest != nil ? "°C" : nil,
            statusText: interp?.displayLabel ?? "No data", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            subtitleText: nil,
            samples: chart, zones: VitalsThresholdEngine.zones(for: .temperature, profile: profile),
            yDomain: domain, referenceBands: [], dashedRules: [],
            trend: TrendSummary.compute(samples: chart, metric: .temperature, unitLabel: "°"),
            sourceQuality: quality, isEstimated: false, confidenceLabel: nil,
            lastUpdatedText: lastUpdated(samples.last?.timestamp, now: inputs.now),
            isEmpty: samples.count < 2
        )
    }

    // MARK: - Blood pressure (two series → one card)

    private static func bloodPressure(_ inputs: Inputs, _ profile: UserPhysiologyProfile, _ cal: Calibration) -> VitalCardViewModel {
        let sys = inputs.systolic.last?.value
        let dia = inputs.diastolic.last?.value
        let quality = SourceQualityResolver.quality(for: .bloodPressure, latest: inputs.systolic.last?.timestamp,
                                                    now: inputs.now, calibration: cal)
        let interp: MetricInterpretation? = (sys != nil && dia != nil)
            ? VitalsThresholdEngine.interpretBloodPressure(systolic: sys!, diastolic: dia!,
                                                           profile: profile, hasCuffReference: cal.hasBPReference)
            : nil
        let valueText = (sys != nil && dia != nil) ? "\(Int(sys!))/\(Int(dia!))" : "--/--"
        // Chart uses systolic series for the trend line; gauge shows both.
        let chart = ChartSampleBuilder.from(inputs.systolic, quality: quality)
        return VitalCardViewModel(
            metric: .bloodPressure, title: MetricKind.bloodPressure.title,
            valueText: valueText, unitText: (sys != nil) ? "mmHg" : nil,
            statusText: interp?.displayLabel ?? "No reading", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            // Systolic/diastolic values are now shown under each of the two gauges on the card, so the
            // subtitle would just repeat them.
            subtitleText: nil,
            samples: chart, zones: VitalsThresholdEngine.zones(for: .bloodPressure, profile: profile),
            yDomain: 80...190, referenceBands: [], dashedRules: [],
            trend: TrendSummary.compute(samples: chart, metric: .bloodPressure, unitLabel: "mmHg"),
            sourceQuality: quality, isEstimated: true,
            confidenceLabel: cal.hasBPReference ? "Estimated" : "Estimated · calibrate with a cuff",
            lastUpdatedText: lastUpdated(inputs.systolic.last?.timestamp, now: inputs.now),
            isEmpty: sys == nil || dia == nil
        )
    }

    // MARK: - Glucose

    private static func glucose(_ inputs: Inputs, _ profile: UserPhysiologyProfile, _ cal: Calibration) -> VitalCardViewModel {
        let samples = inputs.glucose
        let latest = samples.last?.value
        let quality = SourceQualityResolver.quality(for: .glucose, latest: samples.last?.timestamp,
                                                    now: inputs.now, calibration: cal)
        // Context tagging is deferred → always interpret as unknown context (conservative labels).
        let unknownContext = MetricContext(measurement: .unknown)
        let interp = latest.map {
            VitalsThresholdEngine.interpret(value: $0, metric: .glucose, profile: profile, context: unknownContext)
        }
        let chart = ChartSampleBuilder.from(samples, quality: quality)
        let domain = clampedDomain(samples, fallback: 60...200, pad: 15, hardLower: 40, hardUpper: 400)
        return VitalCardViewModel(
            metric: .glucose, title: MetricKind.glucose.title,
            valueText: latest.map { "\(Int($0.rounded()))" } ?? "--", unitText: latest != nil ? "mg/dL" : nil,
            statusText: interp?.displayLabel ?? "No estimate", statusColor: interp?.statusColor ?? PulseColors.textMuted,
            subtitleText: "Estimated wellness metric",
            samples: chart, zones: VitalsThresholdEngine.zones(for: .glucose, profile: profile, context: unknownContext),
            yDomain: domain, referenceBands: [ReferenceBand(lower: 70, upper: 140, colorToken: .mint)], dashedRules: [],
            trend: TrendSummary.compute(samples: chart, metric: .glucose, unitLabel: "mg/dL"),
            sourceQuality: quality, isEstimated: true, confidenceLabel: interp?.confidenceLabel,
            lastUpdatedText: lastUpdated(samples.last?.timestamp, now: inputs.now),
            isEmpty: samples.count < 2
        )
    }

    // MARK: - Helpers

    /// A y-domain padded around the data and clamped to sane hard limits, falling back when empty.
    private static func clampedDomain(_ samples: [MetricSample], fallback: ClosedRange<Double>,
                                      pad: Double, hardLower: Double, hardUpper: Double) -> ClosedRange<Double> {
        let values = samples.map(\.value).filter { $0 > 0 }
        guard let lo = values.min(), let hi = values.max() else { return fallback }
        let lower = max(hardLower, min(fallback.lowerBound, lo - pad))
        let upper = min(hardUpper, max(fallback.upperBound, hi + pad))
        return lower < upper ? lower...upper : fallback
    }

    /// Reference bands derived from the engine's "normal" zone, for charts that want a soft band.
    private static func bands(for metric: MetricKind, profile: UserPhysiologyProfile, domain: ClosedRange<Double>) -> [ReferenceBand] {
        let zones = VitalsThresholdEngine.zones(for: metric, profile: profile)
        guard let normal = zones.first(where: { $0.severity == .normal }) else { return [] }
        let lower = normal.lower ?? domain.lowerBound
        let upper = normal.upper ?? domain.upperBound
        // Band reads from the normal zone's own token so it matches the line/legend exactly.
        return [ReferenceBand(lower: lower, upper: upper, colorToken: normal.colorToken)]
    }

    private static func lastUpdated(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(hours / 24)d ago"
    }
}
