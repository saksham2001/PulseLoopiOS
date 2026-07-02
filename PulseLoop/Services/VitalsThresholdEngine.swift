import Foundation

/// Centralized medical reference-range engine for vitals. The single source of truth for zones,
/// interpretation, and value→color mapping. Views/charts/gauges/legends all call through here so a
/// threshold lives in exactly one place.
///
/// IMPORTANT: nothing here is a diagnosis. Labels are conservative ("Typical", "Elevated", "Low")
/// and ring-estimated metrics (blood pressure, glucose, fatigue) always carry `isEstimated`.
///
/// Reference ranges encoded (defaults; users can later override via profile):
/// - HR: resting adult 60–100 bpm normal; athletes lower; effort zones from `220 − age`.
/// - SpO₂: 95–100 normal; <95 watch; ≤92 high; ≤88 critical (altitude shifts expectations).
/// - HRV: baseline-deviation, NOT absolute cutoffs (highly individual).
/// - Stress / Fatigue: device 0–100 scores, quartile zones.
/// - BP: AHA categories; card category = worse of systolic and diastolic.
/// - Glucose: fasting / 2-hour / random thresholds; conservative when context unknown; always Estimated.
enum VitalsThresholdEngine {

    // MARK: - Public entry points

    /// The reference zones for a metric, given the user's physiology and the measurement context.
    /// For HRV these are baseline-relative and require `baseline`; call `interpret` for the verdict.
    static func zones(for metric: MetricKind,
                      profile: UserPhysiologyProfile,
                      context: MetricContext = MetricContext(),
                      baseline: BaselineStats? = nil) -> [MetricZone] {
        switch metric {
        case .heartRate: return heartRateZones(profile: profile)
        case .spo2: return spo2Zones(profile: profile)
        case .hrv: return hrvZones(baseline: baseline)
        case .stress: return stressZones()
        case .fatigue: return fatigueZones()
        case .bloodPressure: return systolicZones()   // legend uses systolic; card shows both
        case .glucose: return glucoseZones(context: context.measurement)
        case .temperature: return temperatureZones()
        }
    }

    /// Interpret a single scalar value. (Blood pressure has its own two-input entry point.)
    static func interpret(value: Double,
                          metric: MetricKind,
                          profile: UserPhysiologyProfile,
                          context: MetricContext = MetricContext(),
                          baseline: BaselineStats? = nil) -> MetricInterpretation {
        switch metric {
        case .hrv:
            return interpretHRV(value: value, baseline: baseline)
        case .glucose:
            return interpretGlucose(value: value, context: context, profile: profile)
        default:
            let zones = self.zones(for: metric, profile: profile, context: context, baseline: baseline)
            let zone = zone(containing: value, in: zones)
            return MetricInterpretation(
                primaryZone: zone,
                allZones: zones,
                displayLabel: zone.label,
                explanation: zone.explanation,
                confidenceLabel: nil,
                isEstimated: false
            )
        }
    }

    /// The token a chart/legend/gauge should use at `value`: exactly the zone that contains it. The
    /// line, reference band, gauge arc, stat dot, and status label all go through this (or the same
    /// zone list), so the same zone is always the same color. (For metrics whose normal zone IS the
    /// metric accent — HR, HRV — an in-range line still reads as the accent, because the zone says so.)
    static func colorToken(forValue value: Double,
                           metric: MetricKind,
                           profile: UserPhysiologyProfile,
                           context: MetricContext = MetricContext(),
                           baseline: BaselineStats? = nil) -> VitalColorToken {
        interpret(value: value, metric: metric, profile: profile, context: context, baseline: baseline).primaryZone.colorToken
    }

    /// The resolved zones for a metric in render order. The chart uses this to split a line segment at
    /// each zone boundary it crosses, so each piece is colored by the zone it actually falls in.
    static func resolvedZones(for metric: MetricKind,
                              profile: UserPhysiologyProfile,
                              context: MetricContext = MetricContext(),
                              baseline: BaselineStats? = nil) -> [MetricZone] {
        zones(for: metric, profile: profile, context: context, baseline: baseline)
    }

    /// The sorted interior thresholds (zone boundaries) for a metric — the y-values where the line
    /// color can change. Excludes open ends. Used to split segments at crossings.
    static func zoneThresholds(for metric: MetricKind,
                               profile: UserPhysiologyProfile,
                               context: MetricContext = MetricContext(),
                               baseline: BaselineStats? = nil) -> [Double] {
        let zones = resolvedZones(for: metric, profile: profile, context: context, baseline: baseline)
        // Each zone's `upper` (when finite) is a boundary; dedupe + sort.
        let bounds = zones.compactMap(\.upper)
        return Array(Set(bounds)).sorted()
    }

    // MARK: - Blood pressure (two inputs → worse-of category)

    /// Interpret a systolic/diastolic pair. The card's category is the **worse** of the two axes
    /// (AHA convention). BP from a ring is always estimated; suggests cuff calibration.
    static func interpretBloodPressure(systolic: Double,
                                       diastolic: Double,
                                       profile: UserPhysiologyProfile,
                                       hasCuffReference: Bool = false) -> MetricInterpretation {
        let sysZone = zone(containing: systolic, in: systolicZones())
        let diaZone = zone(containing: diastolic, in: diastolicZones())
        let worse = ZoneSeverity.worst(sysZone.severity, diaZone.severity)
        // Pick whichever axis produced the worse severity for the label/explanation.
        let primary = worse == sysZone.severity ? sysZone : diaZone
        let confidence = hasCuffReference ? "Estimated" : "Estimated · calibrate with a cuff"
        return MetricInterpretation(
            primaryZone: primary,
            allZones: systolicZones(),
            displayLabel: primary.label,
            explanation: primary.explanation,
            confidenceLabel: confidence,
            isEstimated: true
        )
    }

    // MARK: - Heart rate

    private static func heartRateZones(profile: UserPhysiologyProfile) -> [MetricZone] {
        // Athletes commonly rest below 60 (and even near 40) — that is optimal, not a concern.
        // Beta-blockers also lower resting HR; we relabel rather than alarm.
        let lowLabel: String
        let lowSeverity: ZoneSeverity
        let lowExplanation: String
        let lowColor: VitalColorToken
        if profile.athleteMode {
            lowLabel = "Athletic"
            lowSeverity = .optimal
            lowColor = .metricAccent(.heartRate)   // a low athletic HR is good, not a caution
            lowExplanation = "A low resting heart rate is common with high fitness."
        } else if profile.usesBetaBlockers {
            lowLabel = "Low (medication)"
            lowSeverity = .normal
            lowColor = .blue
            lowExplanation = "Beta-blockers lower heart rate; this is expected on that medication."
        } else {
            lowLabel = "Low"
            lowSeverity = .watch
            lowColor = .blue
            lowExplanation = "Below the typical resting range. Often fine, but worth noting if you feel faint."
        }
        return [
            MetricZone(id: "hr.low", label: lowLabel, lower: nil, upper: 60,
                       severity: lowSeverity, colorToken: lowColor, explanation: lowExplanation),
            // 60–100 inclusive is normal, so the half-open upper bound is 101.
            MetricZone(id: "hr.normal", label: "Normal", lower: 60, upper: 101,
                       severity: .normal, colorToken: .metricAccent(.heartRate),
                       explanation: "A typical resting heart rate for adults is 60–100 bpm."),
            MetricZone(id: "hr.elevated", label: "Elevated", lower: 101, upper: 120,
                       severity: .watch, colorToken: .amber,
                       explanation: "Above the typical resting range. Activity, caffeine, or stress can raise it."),
            MetricZone(id: "hr.high", label: "High", lower: 120, upper: nil,
                       severity: .high, colorToken: .brightRed,
                       explanation: "A high resting heart rate. Talk to a clinician if it persists at rest."),
        ]
    }

    // MARK: - SpO₂

    private static func spo2Zones(profile: UserPhysiologyProfile) -> [MetricZone] {
        // Altitude and lung conditions lower expected SpO₂; nudge the watch boundary down a touch and
        // note it, rather than alarming on a normal-for-altitude reading.
        let highAltitude = (profile.altitudeMeters ?? 0) > 2000
        let watchUpper = highAltitude || profile.hasKnownLungCondition ? 93.0 : 95.0
        let altitudeNote = highAltitude ? " Expected values are lower at altitude." : ""
        return [
            MetricZone(id: "spo2.critical", label: "Very low", lower: nil, upper: 89,
                       severity: .critical, colorToken: .red,
                       explanation: "An urgently low oxygen reading. Seek care if you also feel unwell.\(altitudeNote)"),
            MetricZone(id: "spo2.high", label: "Low", lower: 89, upper: 93,
                       severity: .high, colorToken: .orange,
                       explanation: "Low blood oxygen. Re-measure when still; talk to a clinician if persistent.\(altitudeNote)"),
            MetricZone(id: "spo2.watch", label: "Slightly low", lower: 93, upper: watchUpper,
                       severity: .watch, colorToken: .amber,
                       explanation: "Slightly below the typical range.\(altitudeNote)"),
            MetricZone(id: "spo2.normal", label: "Normal", lower: watchUpper, upper: nil,
                       severity: .normal, colorToken: .cyan,
                       explanation: "A normal blood-oxygen level is 95–100%.\(altitudeNote)"),
        ]
    }

    // MARK: - HRV (baseline-relative)

    private static func hrvZones(baseline: BaselineStats?) -> [MetricZone] {
        guard let baseline, baseline.isEstablished, baseline.standardDeviation > 0 else {
            // No baseline yet → show the metric's own purple accent (not a gray "unknown" color).
            return [MetricZone(id: "hrv.building", label: "Building baseline", lower: nil, upper: nil,
                               severity: .unknown, colorToken: .metricAccent(.hrv),
                               explanation: "HRV is personal. Wear your ring for about a week to learn your baseline.")]
        }
        let mean = baseline.mean
        let sd = baseline.standardDeviation
        return [
            MetricZone(id: "hrv.below", label: "Below baseline", lower: nil, upper: mean - sd,
                       severity: .high, colorToken: .amber,
                       explanation: "Notably below your typical HRV — often linked to stress, poor sleep, or strain."),
            MetricZone(id: "hrv.slightlyBelow", label: "Slightly below", lower: mean - sd, upper: mean - 0.5 * sd,
                       severity: .watch, colorToken: .softAmber,
                       explanation: "A little below your usual range."),
            MetricZone(id: "hrv.near", label: "Near baseline", lower: mean - 0.5 * sd, upper: mean + 0.5 * sd,
                       severity: .normal, colorToken: .metricAccent(.hrv),
                       explanation: "Around your personal baseline."),
            MetricZone(id: "hrv.above", label: "Above baseline", lower: mean + 0.5 * sd, upper: nil,
                       severity: .optimal, colorToken: .mint,
                       explanation: "Above your typical HRV — often a sign of good recovery."),
        ]
    }

    private static func interpretHRV(value: Double, baseline: BaselineStats?) -> MetricInterpretation {
        let zones = hrvZones(baseline: baseline)
        // No established baseline → single "Building baseline" zone.
        guard let baseline, baseline.isEstablished, baseline.standardDeviation > 0 else {
            let zone = zones[0]
            return MetricInterpretation(
                primaryZone: zone, allZones: zones, displayLabel: zone.label,
                explanation: zone.explanation, confidenceLabel: "Building baseline", isEstimated: false
            )
        }
        let zone = zone(containing: value, in: zones)
        let deltaPct = baseline.mean > 0 ? (value - baseline.mean) / baseline.mean * 100 : 0
        let delta = abs(Int(deltaPct.rounded()))
        let direction = deltaPct >= 0 ? "above" : "below"
        return MetricInterpretation(
            primaryZone: zone, allZones: zones, displayLabel: zone.label,
            explanation: zone.explanation,
            confidenceLabel: delta == 0 ? "At baseline" : "\(delta)% \(direction) baseline",
            isEstimated: false
        )
    }

    // MARK: - Stress / Fatigue (device 0–100 scores)

    private static func stressZones() -> [MetricZone] {
        [
            MetricZone(id: "stress.calm", label: "Calm", lower: nil, upper: 26,
                       severity: .optimal, colorToken: .mint, explanation: "Low stress score — relaxed."),
            MetricZone(id: "stress.normal", label: "Normal", lower: 26, upper: 51,
                       severity: .normal, colorToken: .cyan, explanation: "A typical daytime stress score."),
            MetricZone(id: "stress.elevated", label: "Elevated", lower: 51, upper: 76,
                       severity: .watch, colorToken: .amber, explanation: "Elevated stress — consider a short break."),
            MetricZone(id: "stress.high", label: "High", lower: 76, upper: nil,
                       severity: .high, colorToken: .red, explanation: "High stress score. Wellness estimate, not a diagnosis."),
        ]
    }

    private static func fatigueZones() -> [MetricZone] {
        [
            MetricZone(id: "fatigue.fresh", label: "Fresh", lower: nil, upper: 25,
                       severity: .optimal, colorToken: .mint, explanation: "Low fatigue — well recovered."),
            MetricZone(id: "fatigue.mild", label: "Mild", lower: 25, upper: 50,
                       severity: .normal, colorToken: .cyan, explanation: "Mild fatigue."),
            MetricZone(id: "fatigue.tired", label: "Tired", lower: 50, upper: 75,
                       severity: .watch, colorToken: .amber, explanation: "Tired — consider lighter activity and good sleep."),
            MetricZone(id: "fatigue.high", label: "High fatigue", lower: 75, upper: nil,
                       severity: .high, colorToken: .red, explanation: "High fatigue score. Wellness estimate from the ring."),
        ]
    }

    // MARK: - Blood pressure axes

    /// Public accessor for the diastolic reference zones (the systolic zones are returned by
    /// `zones(for: .bloodPressure …)`). Used by the dual-ring gauge's inner track.
    static func diastolicReferenceZones() -> [MetricZone] { diastolicZones() }

    private static func systolicZones() -> [MetricZone] {
        [
            MetricZone(id: "bp.sys.low", label: "Low", lower: nil, upper: 90,
                       severity: .watch, colorToken: .blue, explanation: "Low systolic pressure (below 90)."),
            MetricZone(id: "bp.sys.normal", label: "Normal", lower: 90, upper: 120,
                       severity: .normal, colorToken: .mint, explanation: "Normal blood pressure is below 120/80."),
            MetricZone(id: "bp.sys.elevated", label: "Elevated", lower: 120, upper: 130,
                       severity: .watch, colorToken: .amber, explanation: "Elevated systolic (120–129)."),
            MetricZone(id: "bp.sys.stage1", label: "Stage 1", lower: 130, upper: 140,
                       severity: .high, colorToken: .orange, explanation: "Stage 1 hypertension range (systolic 130–139)."),
            MetricZone(id: "bp.sys.stage2", label: "Stage 2", lower: 140, upper: 180,
                       severity: .high, colorToken: .red, explanation: "Stage 2 hypertension range (systolic ≥140)."),
            MetricZone(id: "bp.sys.crisis", label: "Severe", lower: 180, upper: nil,
                       severity: .critical, colorToken: .red, explanation: "Severe range (systolic >180). Seek care if confirmed."),
        ]
    }

    private static func diastolicZones() -> [MetricZone] {
        [
            MetricZone(id: "bp.dia.low", label: "Low", lower: nil, upper: 60,
                       severity: .watch, colorToken: .blue, explanation: "Low diastolic pressure (below 60)."),
            MetricZone(id: "bp.dia.normal", label: "Normal", lower: 60, upper: 80,
                       severity: .normal, colorToken: .mint, explanation: "Normal diastolic is below 80."),
            // Note: there is no diastolic "Elevated" category — 80–89 is already Stage 1 by AHA.
            MetricZone(id: "bp.dia.stage1", label: "Stage 1", lower: 80, upper: 90,
                       severity: .high, colorToken: .orange, explanation: "Stage 1 hypertension range (diastolic 80–89)."),
            MetricZone(id: "bp.dia.stage2", label: "Stage 2", lower: 90, upper: 120,
                       severity: .high, colorToken: .red, explanation: "Stage 2 hypertension range (diastolic ≥90)."),
            MetricZone(id: "bp.dia.crisis", label: "Severe", lower: 120, upper: nil,
                       severity: .critical, colorToken: .red, explanation: "Severe range (diastolic >120). Seek care if confirmed."),
        ]
    }

    // MARK: - Glucose

    private static func glucoseZones(context: MeasurementContext) -> [MetricZone] {
        switch context {
        case .fasting:
            return [
                MetricZone(id: "glucose.low", label: "Low", lower: nil, upper: 70,
                           severity: .high, colorToken: .red, explanation: "Below 70 mg/dL is low."),
                MetricZone(id: "glucose.normal", label: "Normal", lower: 70, upper: 100,
                           severity: .normal, colorToken: .mint, explanation: "Fasting normal is up to 99 mg/dL."),
                MetricZone(id: "glucose.elevated", label: "Elevated", lower: 100, upper: 126,
                           severity: .watch, colorToken: .amber, explanation: "Fasting 100–125 is above the typical range."),
                MetricZone(id: "glucose.high", label: "High", lower: 126, upper: nil,
                           severity: .high, colorToken: .red, explanation: "Fasting ≥126. Talk to a clinician if confirmed by a meter."),
            ]
        case .postMeal:
            return [
                MetricZone(id: "glucose.low", label: "Low", lower: nil, upper: 70,
                           severity: .high, colorToken: .red, explanation: "Below 70 mg/dL is low."),
                MetricZone(id: "glucose.normal", label: "Normal", lower: 70, upper: 140,
                           severity: .normal, colorToken: .mint, explanation: "Two-hour post-meal normal is up to 140 mg/dL."),
                MetricZone(id: "glucose.elevated", label: "Elevated", lower: 140, upper: 200,
                           severity: .watch, colorToken: .amber, explanation: "Two-hour 140–199 is above the typical range."),
                MetricZone(id: "glucose.high", label: "High", lower: 200, upper: nil,
                           severity: .high, colorToken: .red, explanation: "Two-hour ≥200. Confirm with a meter and a clinician."),
            ]
        default:
            // Unknown / random context: conservative labels, NO "prediabetes"/"diabetes" wording.
            return [
                MetricZone(id: "glucose.low", label: "Low", lower: nil, upper: 70,
                           severity: .high, colorToken: .red, explanation: "Below 70 mg/dL is low."),
                MetricZone(id: "glucose.typical", label: "Typical", lower: 70, upper: 140,
                           severity: .normal, colorToken: .mint, explanation: "Within a typical range for a non-fasting reading."),
                MetricZone(id: "glucose.elevated", label: "Elevated", lower: 140, upper: 200,
                           severity: .watch, colorToken: .amber, explanation: "Above the typical range. Context (meals) affects this."),
                MetricZone(id: "glucose.veryHigh", label: "Very high", lower: 200, upper: nil,
                           severity: .high, colorToken: .red, explanation: "A high reading regardless of context. Confirm with a meter."),
            ]
        }
    }

    private static func interpretGlucose(value: Double,
                                         context: MetricContext,
                                         profile: UserPhysiologyProfile) -> MetricInterpretation {
        let zones = glucoseZones(context: context.measurement)
        let zone = zone(containing: value, in: zones)
        return MetricInterpretation(
            primaryZone: zone, allZones: zones, displayLabel: zone.label,
            explanation: zone.explanation,
            confidenceLabel: "Estimated — not for dosing or diagnosis",
            isEstimated: true
        )
    }

    // MARK: - Temperature (skin)

    private static func temperatureZones() -> [MetricZone] {
        // Skin (not core) temperature; ring values run cooler than oral. Trend matters more than
        // absolute, so we keep a single soft "typical" band and flag extremes only.
        [
            MetricZone(id: "temp.low", label: "Cool", lower: nil, upper: 31,
                       severity: .watch, colorToken: .blue, explanation: "Cooler than typical skin temperature."),
            MetricZone(id: "temp.normal", label: "Typical", lower: 31, upper: 36,
                       severity: .normal, colorToken: .metricAccent(.temperature),
                       explanation: "A typical skin-temperature range from the ring."),
            MetricZone(id: "temp.high", label: "Warm", lower: 36, upper: nil,
                       severity: .watch, colorToken: .amber, explanation: "Warmer than typical. Trends matter more than a single reading."),
        ]
    }

    // MARK: - Helpers

    /// The zone a value falls into, falling back to the nearest end zone if outside all bands.
    private static func zone(containing value: Double, in zones: [MetricZone]) -> MetricZone {
        if let match = zones.first(where: { $0.contains(value) }) { return match }
        // Outside every band: clamp to the first/last zone.
        if let first = zones.first, let lower = first.lower, value < lower { return first }
        return zones.last ?? zones[0]
    }
}
