import SwiftUI
import WidgetKit

// Widget-native recompositions of the Today-page tiles. The heavy visuals (ActivityRingsView,
// SleepStageBar, ZoneLineChart, VitalRingGauge) are the SAME shared design-system views the app
// renders, fed from decoded snapshot payloads — only the ~25-line tile chrome differs, because a
// widget gets its card from `containerBackground` + the system corner mask instead of the in-app
// RoundedRectangle/border, and tiles here aren't buttons.

// MARK: - Chrome

/// The eyebrow header from `TodayTile`: glowing 8 pt dot + 11 pt tracked uppercase label. The
/// trailing "as of" time appears only once the snapshot is meaningfully stale, so a fresh widget
/// stays as clean as the in-app tile.
struct WidgetTileHeader: View {
    let label: String
    let color: Color
    var asOf: Date?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 5)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(PulseColors.textMuted)
                .lineLimit(1)
            if let asOf {
                Spacer(minLength: 4)
                Text(asOf, style: .time)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(PulseColors.textMuted.opacity(0.8))
            }
        }
    }
}

extension SnapshotEntry {
    /// Header timestamp: shown once the snapshot is older than this entry by 45+ minutes.
    var stalenessDate: Date? {
        guard let snapshot, date.timeIntervalSince(snapshot.generatedAt) > 45 * 60 else { return nil }
        return snapshot.generatedAt
    }
}

/// Centered muted message used for missing data / first-run states, mirroring the in-app empty tiles.
struct WidgetEmptyMessage: View {
    let systemImage: String
    let message: String
    var color: Color = PulseColors.textMuted

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 24)).foregroundStyle(color.opacity(0.7))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Activity (half-width tile: rings + stacked values, from `ActivityTileView`)

struct WidgetActivityContent: View {
    let payload: WidgetActivityPayload?
    let rolledOver: Bool

    /// The label rows in ring order (outer→inner), skipping missing metrics — same as the tile.
    private var values: [(label: String, text: String, color: Color)] {
        guard let payload, !rolledOver else { return [] }
        let rows: [(String, String?, Color)] = [
            ("STEPS", payload.stepsText, PulseColors.steps),
            (payload.distanceUnitLabel, payload.distanceText, PulseColors.distance),
            ("CAL", payload.caloriesText, PulseColors.calories),
        ]
        return rows.compactMap { label, text, color in text.map { (label, $0, color) } }
    }

    private var rings: [ActivityRing] {
        let active = rolledOver ? nil : payload
        return [
            ActivityRing(value: active?.steps, goal: active?.stepsGoal ?? 1, color: PulseColors.steps),
            ActivityRing(value: active?.distanceDisplay, goal: active?.distanceGoalDisplay ?? 1, color: PulseColors.distance),
            ActivityRing(value: active?.calories, goal: active?.caloriesGoal ?? 1, color: PulseColors.calories),
        ]
    }

    var body: some View {
        if values.isEmpty {
            WidgetEmptyMessage(systemImage: "figure.walk",
                               message: rolledOver ? "No data yet today" : "Open PulseLoop to sync",
                               color: PulseColors.steps)
        } else {
            HStack(spacing: 10) {
                ActivityRingsView(rings: rings, size: 88, stroke: 9, spacing: 4)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(value.label)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(value.color)
                            Text(value.text)
                                .activityValueStyle(size: 26)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Activity (full-width: labeled metrics left, big rings right, from `DailyActivitySummaryCard`)

struct WidgetActivityFullContent: View {
    let payload: WidgetActivityPayload?
    let rolledOver: Bool

    private var active: WidgetActivityPayload? { rolledOver ? nil : payload }

    var body: some View {
        if payload == nil {
            WidgetEmptyMessage(systemImage: "figure.walk", message: "Open PulseLoop to sync",
                               color: PulseColors.steps)
        } else {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        metric(label: "Steps", value: active?.stepsText ?? "—", unit: nil, color: PulseColors.steps)
                        metric(label: "Distance", value: active?.distanceText ?? "—",
                               unit: active?.distanceText == nil ? nil : active?.distanceUnitLabel.lowercased(),
                               color: PulseColors.distance)
                    }
                    metric(label: "Calories", value: active?.caloriesText ?? "—",
                           unit: active?.caloriesText == nil ? nil : "cal", color: PulseColors.calories)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ActivityRingsView(rings: [
                    ActivityRing(value: active?.steps, goal: active?.stepsGoal ?? 1, color: PulseColors.steps),
                    ActivityRing(value: active?.distanceDisplay, goal: active?.distanceGoalDisplay ?? 1, color: PulseColors.distance),
                    ActivityRing(value: active?.calories, goal: active?.caloriesGoal ?? 1, color: PulseColors.calories),
                ], size: 112, stroke: 11, spacing: 5)
                .frame(width: 112, height: 112)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func metric(label: String, value: String, unit: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 15, weight: .bold)).tracking(0.6)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .activityValueStyle(size: 32)
                if let unit {
                    Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sleep (duration + stage bar + score, from `SleepTileView`)

struct WidgetSleepContent: View {
    let payload: WidgetSleepPayload?
    let rolledOver: Bool

    var body: some View {
        if let payload, !rolledOver {
            VStack(alignment: .leading, spacing: 10) {
                Text(payload.durationText)
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                SleepStageBar(segments: payload.segments.map {
                    SleepStageSegment(minutes: $0.minutes, color: Color(hex: $0.colorHex), label: $0.label)
                })
                .frame(height: 24)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(payload.score)")
                        .font(.system(size: 32, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                    Text("SCORE")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.0)
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            WidgetEmptyMessage(systemImage: "moon.zzz", message: "No sleep recorded",
                               color: PulseColors.sleep)
        }
    }
}

// MARK: - Zone chart (HR / SpO₂ / HRV / temperature, from `TodayChartTile`)

struct WidgetChartContent: View {
    let payload: WidgetMetricPayload

    private var metricKind: MetricKind { MetricKind(rawValue: payload.kind) ?? .heartRate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(payload.valueText)
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .minimumScaleFactor(0.7).lineLimit(1)
                if let unit = payload.unitText {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if payload.isEmpty {
                Text(payload.statusText)
                    .font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZoneLineChart(
                    samples: payload.samples.map(\.chartSample),
                    metric: metricKind,
                    yDomain: payload.yLower...payload.yUpper,
                    referenceBands: payload.referenceBands.map(\.referenceBand),
                    range: .twentyFourHours,
                    showPoints: metricKind == .spo2,
                    showAxes: false,
                    dashedRules: payload.dashedRules,
                    height: 56,
                    thresholds: payload.thresholds,
                    colorForValue: { payload.lineColor(forValue: $0) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Ring gauge (stress / fatigue / glucose, from `TodayGaugeTile`)

struct WidgetGaugeContent: View {
    let payload: WidgetMetricPayload

    var body: some View {
        if payload.isEmpty {
            WidgetEmptyMessage(systemImage: "waveform.path", message: payload.statusText)
        } else {
            // The in-app tile uses a fixed 118 pt gauge; widget families vary a few points per
            // device, so size to the available square (capped at 118) to avoid clipping the arc.
            GeometryReader { geo in
                let size = min(118, min(geo.size.width, geo.size.height))
                VitalRingGauge(
                    value: Double(payload.valueText) ?? 0,
                    domain: payload.yLower...payload.yUpper,
                    zones: payload.zones.map(\.metricZone),
                    valueColor: Color(hex: payload.statusColorHex),
                    centerValue: payload.valueText,
                    centerStatus: payload.statusText,
                    size: size,
                    lineWidth: size * (11.0 / 118.0)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Blood pressure (two small gauges, from `TodayBloodPressureTile`)

struct WidgetBloodPressureContent: View {
    let payload: WidgetMetricPayload

    var body: some View {
        if payload.isEmpty || payload.systolic == nil || payload.diastolic == nil {
            WidgetEmptyMessage(systemImage: "heart.text.square", message: payload.statusText,
                               color: PulseColors.bloodPressure)
        } else {
            HStack(spacing: 6) {
                ringColumn(title: "SYS", value: payload.systolic!, domain: 80...190,
                           zones: payload.systolicZones.map(\.metricZone),
                           fallback: PulseColors.bloodPressure)
                ringColumn(title: "DIA", value: payload.diastolic!, domain: 50...130,
                           zones: payload.diastolicZones.map(\.metricZone),
                           fallback: PulseColors.bloodPressure.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Dispatcher (one Today tile, by configured metric)

/// Renders the configured metric as its Today tile: eyebrow header + the matching visual. Used by
/// the half-width widget and by each side of the full-width dual widget.
struct WidgetMetricTileView: View {
    let metric: WidgetMetric
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTileHeader(label: metric.headerLabel, color: metric.accentColor,
                             asOf: entry.stalenessDate)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch metric.tileStyle {
        case .rings:
            WidgetActivityContent(payload: entry.snapshot?.activity, rolledOver: entry.rolledOver)
        case .sleep:
            WidgetSleepContent(payload: entry.snapshot?.sleep, rolledOver: entry.rolledOver)
        case .chart, .gauge, .bloodPressure:
            if let payload = entry.snapshot.flatMap({ $0.metrics[metric.metricKind?.rawValue ?? ""] }) {
                switch metric.tileStyle {
                case .chart: WidgetChartContent(payload: payload)
                case .gauge: WidgetGaugeContent(payload: payload)
                default: WidgetBloodPressureContent(payload: payload)
                }
            } else {
                WidgetEmptyMessage(systemImage: "waveform.path",
                                   message: entry.snapshot == nil ? "Open PulseLoop to sync" : "No data",
                                   color: metric.accentColor)
            }
        }
    }
}
