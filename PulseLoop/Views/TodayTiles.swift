import SwiftUI

// Today-page tiles. Every tile is half-width (rendered in a 2-column grid) and shares one fixed
// height so the grid never jumps. Each wraps the shared `TodayTile` chrome around a metric-specific
// visualization, reusing the Vitals design-system components (ring gauge, zone chart, activity loop,
// sleep-stage colors) so Today and Vitals speak the same visual language. All interpretation math is
// prepared in `TodayStore` (via `VitalsCardFactory`) — these views only lay out prepared state.

/// Shared sizing so every Today tile is identical.
enum TodayTileMetrics {
    static let height: CGFloat = 168
    static let corner: CGFloat = 20
}

// MARK: - Tile chrome

/// The card shell shared by every Today tile: fixed height, rounded card background, optional tap.
/// A leading "eyebrow" header (colored dot + label) mirrors `MetricCardButton` so custom tiles read
/// as siblings of the plain metric tiles.
struct TodayTile<Content: View>: View {
    let label: String
    var color: Color
    var onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button { onTap?() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.7), radius: 5)
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .frame(height: TodayTileMetrics.height)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: TodayTileMetrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TodayTileMetrics.corner, style: .continuous)
                    .stroke(PulseColors.borderSubtle, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onTap != nil)
    }
}

// MARK: - Activity tile (steps + distance + calories → one concentric loop)

/// Collapses the three activity metrics into the same concentric progress loop the Activity page
/// uses (`ActivityRingsView`), sized to fit a half-width tile. Labels are colored in ring color,
/// values are white — matching the Activity page widget style.
struct ActivityTileView: View {
    let summary: TodaySummary
    let units: UnitsPreference
    var caloriesAvailable: Bool
    var onTap: () -> Void

    private var effectiveCalories: Double? { caloriesAvailable ? summary.calories : nil }
    private var distanceGoalDisplay: Double {
        Double(UnitsFormatter.distance(meters: summary.goals.distanceMetersDaily, units: units).value) ?? 0
    }
    private var distanceDisplay: Double? {
        summary.distanceMeters.flatMap { Double(UnitsFormatter.distance(meters: $0, units: units).value) }
    }

    /// The three values with labels, top-to-bottom in ring order (outer→inner).
    /// Missing metrics are skipped rather than shown as dashes.
    private var values: [(label: String, text: String, color: Color)] {
        let distUnit = units == .imperial ? "MI" : "KM"
        let rows: [(String, String?, Color)] = [
            ("STEPS", summary.steps.map { $0.formatted() }, PulseColors.steps),
            (distUnit, summary.distanceMeters.map { UnitsFormatter.distance(meters: $0, units: units).value }, PulseColors.distance),
            ("CAL", effectiveCalories.map { Int($0).formatted() }, PulseColors.calories),
        ]
        return rows.compactMap { label, text, color in text.map { (label, $0, color) } }
    }

    var body: some View {
        TodayTile(label: "Activity", color: PulseColors.steps, onTap: onTap) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ActivityRingsView(rings: [
                    ActivityRing(value: summary.steps.map(Double.init), goal: Double(summary.goals.stepsDaily), color: PulseColors.steps),
                    ActivityRing(value: distanceDisplay, goal: distanceGoalDisplay, color: PulseColors.distance),
                    ActivityRing(value: effectiveCalories, goal: Double(summary.goals.caloriesDaily), color: PulseColors.calories)
                ], size: 88, stroke: 9, spacing: 4)
                // Nudge into the card padding so the bigger loop doesn't crowd the numbers.
                .padding(.leading, -6)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(value.label)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(value.color)
                            Text(value.text)
                                .font(.system(size: 26, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sleep tile (duration + stage distribution bar + score)

/// A single stacked bar of proportional deep/light/REM/awake segments (sleep-page colors), the total
/// sleep duration above it, and the sleep score below. No percentages or per-segment labels — the
/// bar reads distribution at a glance.
struct SleepTileView: View {
    let sleep: SleepSummary?
    var onTap: () -> Void

    var body: some View {
        TodayTile(label: "Sleep", color: PulseColors.sleep, onTap: onTap) {
            if let sleep {
                let stages = SleepStageDistribution(sleep)
                let score = SleepScore.calculate(sleep).score
                VStack(alignment: .leading, spacing: 10) {
                    Text(SleepFormat.duration(sleep.session.totalMinutes))
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    SleepStageBar(segments: stages.segments)
                        .frame(height: 24)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(score)")
                            .font(.system(size: 32, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(PulseColors.textPrimary)
                        Text("SCORE")
                            .font(.system(size: 10, weight: .semibold)).tracking(1.0)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 24)).foregroundStyle(PulseColors.sleep.opacity(0.7))
                    Text("No sleep recorded")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Derives the four-stage split (deep/light/REM/awake) from a sleep summary. `SleepSummary` pre-sums
/// deep/light/awake; REM is recovered from the stage blocks. Empty stages are dropped so the bar only
/// shows what's present.
struct SleepStageDistribution {
    let segments: [SleepStageSegment]

    init(_ sleep: SleepSummary) {
        let remMinutes = sleep.blocks.filter { $0.stage == .rem }.reduce(0) { $0 + $1.durationMinutes }
        let raw: [(Double, Color, String)] = [
            (Double(max(0, sleep.deepMinutes)), SleepStageColors.deep, "DEEP"),
            (Double(max(0, sleep.lightMinutes)), SleepStageColors.light, "LIGHT"),
            (Double(max(0, remMinutes)), SleepStageColors.rem, "REM"),
            (Double(max(0, sleep.awakeMinutes)), SleepStageColors.awake, "AWK"),
        ]
        segments = raw.filter { $0.0 > 0 }.map { SleepStageSegment(minutes: $0.0, color: $0.1, label: $0.2) }
    }
}

// MARK: - Compact zone-chart tile (HR / SpO₂ / HRV / temperature)

/// A half-width chart tile: the metric's latest value + a compact zone-colored line chart. Reuses the
/// same `ZoneLineChart` + threshold coloring the Vitals cards use, at a reduced height with no axes.
struct TodayChartTile: View {
    let model: VitalCardViewModel
    let profile: UserPhysiologyProfile
    let baseline: BaselineStats?
    var showPoints: Bool = false
    var onTap: () -> Void

    var body: some View {
        TodayTile(label: model.title, color: model.accentColor, onTap: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.valueText)
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .minimumScaleFactor(0.7).lineLimit(1)
                if let unit = model.unitText {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.isEmpty {
                Text(model.statusText)
                    .font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZoneLineChart(
                    samples: model.samples,
                    metric: model.metric,
                    yDomain: model.yDomain,
                    referenceBands: model.referenceBands,
                    range: .twentyFourHours,
                    showPoints: showPoints,
                    showAxes: false,
                    dashedRules: model.dashedRules,
                    height: 56,
                    thresholds: VitalsThresholdEngine.zoneThresholds(
                        for: model.metric, profile: profile, baseline: baseline
                    ),
                    colorForValue: { value in
                        VitalsThresholdEngine.colorToken(
                            forValue: value, metric: model.metric, profile: profile, baseline: baseline
                        ).color
                    }
                )
            }
        }
    }
}

// MARK: - Compact gauge tile (Stress / Fatigue / Glucose)

/// A half-width gauge tile: the Vitals ring gauge scaled down. The gauge center carries the value, so
/// the tile header shows only the metric name (no repeated value).
struct TodayGaugeTile: View {
    let model: VitalCardViewModel
    var onTap: () -> Void

    private var gaugeValue: Double { Double(model.valueText) ?? 0 }

    var body: some View {
        TodayTile(label: model.title, color: model.accentColor, onTap: onTap) {
            Spacer(minLength: 0)
            if model.isEmpty {
                VitalEmptyState(metric: model.metric, compact: true)
            } else {
                VitalRingGauge(
                    value: gaugeValue,
                    domain: model.yDomain,
                    zones: model.zones,
                    valueColor: model.statusColor,
                    centerValue: model.valueText,
                    centerStatus: model.statusText,
                    size: 118,
                    lineWidth: 11
                )
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Blood pressure tile (two gauges side by side)

/// Systolic + diastolic as two small gauges side by side in one half-width tile. Mirrors the Vitals
/// BP card, scaled down. Each gauge's arc is colored by the zone the reading falls in.
struct TodayBloodPressureTile: View {
    let model: VitalCardViewModel
    let systolic: Double?
    let diastolic: Double?
    let systolicZones: [MetricZone]
    let diastolicZones: [MetricZone]
    var onTap: () -> Void

    var body: some View {
        TodayTile(label: model.title, color: model.accentColor, onTap: onTap) {
            Spacer(minLength: 0)
            if model.isEmpty || systolic == nil || diastolic == nil {
                VitalEmptyState(metric: .bloodPressure, compact: true)
            } else {
                HStack(spacing: 6) {
                    ringColumn(title: "SYS", value: systolic!, domain: 80...190, zones: systolicZones,
                               fallback: PulseColors.bloodPressure)
                    ringColumn(title: "DIA", value: diastolic!, domain: 50...130, zones: diastolicZones,
                               fallback: PulseColors.bloodPressure.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
    }

    private func ringColumn(title: String, value: Double, domain: ClosedRange<Double>,
                            zones: [MetricZone], fallback: Color) -> some View {
        let valueColor = zones.first(where: { $0.contains(value) })?.color ?? fallback
        return VStack(spacing: 5) {
            VitalRingGauge(
                value: value,
                domain: domain,
                zones: zones,
                valueColor: valueColor,
                centerValue: "\(Int(value))",
                size: 66,
                lineWidth: 7
            )
            Text(title)
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
