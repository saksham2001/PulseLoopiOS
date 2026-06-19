import SwiftUI
import Charts

/// Native Swift Charts ports of the web app's Recharts components, plus the
/// custom sleep hypnogram. Colors/domains mirror `frontend/src/components/charts`.

// MARK: - Sleep stage palette (matches Sleep.tsx STAGE_COLORS, not PulseColors)

enum SleepStageColors {
    static let deep = Color(hex: "#3F2DD8")
    static let light = Color(hex: "#7C5CFF")
    static let rem = Color(hex: "#2DD4D8")
    static let awake = Color(hex: "#FFB86B")

    static func color(for stage: SleepStage) -> Color {
        switch stage {
        case .deep: return deep
        case .light: return light
        case .rem: return rem
        case .awake: return awake
        case .unknown: return PulseColors.textMuted
        }
    }
}

// MARK: - HR line (Vitals)

struct HRLineChart: View {
    let samples: [MetricSample]
    var height: CGFloat = 150

    var body: some View {
        let values = samples.map(\.value)
        let lo = (values.min() ?? 0) - 5
        let hi = (values.max() ?? 100) + 5
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                LineMark(
                    x: .value("i", index),
                    y: .value("bpm", sample.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(PulseColors.heartRate)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Stress gauge (Vitals, Colmi)

/// Radial gauge showing the latest stress score on a zoned arc:
/// relaxed (0–29) · normal (30–59) · medium (60–79) · high (80–100).
struct StressGaugeChart: View {
    let value: Double          // 0...100
    var height: CGFloat = 160

    private let zones: [(upper: Double, color: Color, label: String)] = [
        (29, PulseColors.success, "Relaxed"),
        (59, PulseColors.info, "Normal"),
        (79, PulseColors.warning, "Medium"),
        (100, PulseColors.danger, "High"),
    ]

    private var zone: (upper: Double, color: Color, label: String) {
        zones.first { value <= $0.upper } ?? zones[zones.count - 1]
    }

    var body: some View {
        let fraction = max(0, min(1, value / 100))
        ZStack {
            // Background track
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
            // Value arc
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(zone.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
            VStack(spacing: 2) {
                Text("\(Int(value))")
                    .font(.system(size: 38, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                Text(zone.label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(zone.color)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - HRV trend band (Vitals, Colmi)

/// HRV trend line with a shaded baseline band around the mean, so a glance shows whether recent
/// values sit above or below the user's typical range.
struct HRVTrendBandChart: View {
    let samples: [MetricSample]   // value in ms
    var height: CGFloat = 150

    var body: some View {
        let values = samples.map(\.value)
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let lo = (values.min() ?? 0) - 8
        let hi = (values.max() ?? 100) + 8
        let bandHalf = max(6, mean * 0.12)   // ±12% baseline band

        Chart {
            // Baseline band
            RectangleMark(
                xStart: .value("x0", 0),
                xEnd: .value("x1", max(1, samples.count - 1)),
                yStart: .value("lo", mean - bandHalf),
                yEnd: .value("hi", mean + bandHalf)
            )
            .foregroundStyle(PulseColors.hrv.opacity(0.12))

            RuleMark(y: .value("mean", mean))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(PulseColors.hrv.opacity(0.4))

            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                LineMark(x: .value("i", index), y: .value("ms", sample.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(PulseColors.hrv)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Temperature range (Vitals, Colmi)

/// Skin-temperature trend as a filled range around the series, emphasizing daily min/max swing.
struct TemperatureRangeChart: View {
    let samples: [MetricSample]   // value in °C
    var height: CGFloat = 150

    var body: some View {
        let values = samples.map(\.value)
        let lo = (values.min() ?? 30) - 0.5
        let hi = (values.max() ?? 38) + 0.5

        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                AreaMark(
                    x: .value("i", index),
                    yStart: .value("lo", lo),
                    yEnd: .value("temp", sample.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [PulseColors.temperature.opacity(0.28), PulseColors.temperature.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(x: .value("i", index), y: .value("temp", sample.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(PulseColors.temperature)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - SpO2 dots (Vitals)

struct SpO2DotsChart: View {
    let samples: [MetricSample]
    var height: CGFloat = 150

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                LineMark(x: .value("i", index), y: .value("spo2", sample.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(PulseColors.spo2.opacity(0.25))
                PointMark(x: .value("i", index), y: .value("spo2", sample.value))
                    .symbolSize(34)
                    .foregroundStyle(PulseColors.spo2)
            }
        }
        .chartYScale(domain: 90...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Step bars (Activity)

struct StepBarsChart: View {
    let values: [Double]
    var labels: [String] = []
    var goal: Double?
    var todayIndex: Int?
    var height: CGFloat = 160

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                BarMark(
                    x: .value("label", labels.indices.contains(index) ? labels[index] : "\(index)"),
                    y: .value("steps", value),
                    width: .automatic
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                .foregroundStyle(PulseColors.steps.opacity(todayIndex == index ? 1 : 0.55))
            }
            if let goal {
                RuleMark(y: .value("goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(PulseColors.textMuted.opacity(0.6))
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().foregroundStyle(PulseColors.textMuted)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Distance line (Activity)

struct DistanceLineChart: View {
    let values: [Double]
    var height: CGFloat = 150

    var body: some View {
        let hi = (values.max() ?? 1) + 0.5
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("i", index), y: .value("km", value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(PulseColors.distance)
            }
        }
        .chartYScale(domain: 0...max(hi, 0.5))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Calories area (Activity)

struct CaloriesAreaChart: View {
    let values: [Double]
    var height: CGFloat = 150

    var body: some View {
        let hi = (values.max() ?? 0) + 50
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("i", index), y: .value("kcal", value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [PulseColors.calories.opacity(0.45), PulseColors.calories.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                LineMark(x: .value("i", index), y: .value("kcal", value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(PulseColors.calories)
            }
        }
        .chartYScale(domain: 0...max(hi, 50))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Elevation profile (workout summary)

/// Altitude over the course of a route. X is point index (route progression),
/// Y is metres above sea level. Gradient area + line in the distance colour, axes hidden —
/// matches `CaloriesAreaChart`'s styling.
struct ElevationAreaChart: View {
    let altitudes: [Double]
    var height: CGFloat = 120

    var body: some View {
        let lo = (altitudes.min() ?? 0) - 2
        let hi = (altitudes.max() ?? 0) + 2
        Chart {
            ForEach(Array(altitudes.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("i", index), y: .value("m", value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [PulseColors.distance.opacity(0.40), PulseColors.distance.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                LineMark(x: .value("i", index), y: .value("m", value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(PulseColors.distance)
            }
        }
        .chartYScale(domain: lo...max(hi, lo + 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Sleep duration histogram (Sleep aggregate)

struct SleepBar: Identifiable {
    let id = UUID()
    let label: String
    /// Sleep duration in minutes, or nil for an untracked slot.
    let durationMin: Int?
    let score: Int?
    let present: Bool
}

struct SleepDurationHistogramChart: View {
    let bars: [SleepBar]
    var goalMin: Int?
    var slim: Bool = false
    var height: CGFloat = 210

    private var yMax: Double {
        let maxDuration = bars.compactMap { $0.durationMin }.max() ?? 0
        let ceiling = max(maxDuration, goalMin ?? 0)
        return ceiling > 0 ? Double(ceiling) * 1.15 : 600
    }

    var body: some View {
        let interval = bars.count > 14 ? max(1, bars.count / 6) : 1
        Chart {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                if bar.present, let duration = bar.durationMin {
                    BarMark(
                        x: .value("label", index),
                        y: .value("min", duration),
                        width: slim ? 7 : .automatic
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: slim ? 3 : 6, topTrailingRadius: slim ? 3 : 6))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#8B7CFF"), Color(hex: "#3F2DD8")],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                } else {
                    // Faint full-height placeholder so gaps read as "untracked".
                    BarMark(
                        x: .value("label", index),
                        y: .value("min", yMax),
                        width: slim ? 7 : .automatic
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: slim ? 3 : 6, topTrailingRadius: slim ? 3 : 6))
                    .foregroundStyle(PulseColors.accent.opacity(0.05))
                }
            }
            if let goalMin, goalMin > 0 {
                RuleMark(y: .value("goal", goalMin))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(PulseColors.textMuted.opacity(0.5))
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: max(2, bars.count / interval))) { value in
                if let index = value.as(Int.self), bars.indices.contains(index) {
                    AxisValueLabel {
                        Text(bars[index].label).foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .frame(height: height)
        .padding(8)
        .background(Color(hex: "#0F141F"), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Sleep hypnogram (Sleep day view)
// Direct port of frontend/src/components/charts/SleepTimeline.tsx

struct SleepHypnogramView: View {
    let blocks: [SleepStageBlock]
    let totalMin: Int
    let startTs: Date?
    var height: CGFloat = 210

    private let lanes: [SleepStage] = [.awake, .rem, .light, .deep]

    private func laneY(_ stage: SleepStage, in size: CGSize) -> CGFloat {
        // awake=top lane, then REM, light, deep=bottom (standard hypnogram ordering).
        let frac: CGFloat
        switch stage {
        case .awake: frac = 0.15
        case .rem: frac = 0.38
        case .light: frac = 0.62
        case .deep: frac = 0.85
        case .unknown: frac = 0.62
        }
        return size.height * frac
    }

    private func x(forMinute minute: Int, in width: CGFloat) -> CGFloat {
        guard totalMin > 0 else { return 0 }
        let pct = max(0, min(1, CGFloat(minute) / CGFloat(totalMin)))
        return pct * width
    }

    private var sortedBlocks: [SleepStageBlock] {
        blocks.filter { $0.durationMinutes > 0 && $0.stage != .unknown }.sorted { $0.startMinute < $1.startMinute }
    }

    private var ticks: [(offset: Int, label: String)] {
        let safe = totalMin > 0 ? totalMin : 1
        let offsets = [0, safe / 3, safe * 2 / 3, safe]
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return offsets.map { offset in
            if let start = startTs {
                let date = start.addingTimeInterval(Double(offset) * 60)
                return (offset, formatter.string(from: date))
            }
            return (offset, "\(offset / 60)h")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "#0F141F"))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))

                // Lane labels on the left.
                VStack(alignment: .leading) {
                    ForEach(lanes, id: \.self) { stage in
                        Text(stage.rawValue.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(SleepStageColors.color(for: stage))
                        if stage != lanes.last { Spacer() }
                    }
                }
                .padding(.vertical, 14)
                .padding(.leading, 12)

                // Plot area, inset to clear the labels.
                Canvas { context, size in
                    let blocks = sortedBlocks
                    guard !blocks.isEmpty else { return }

                    // Dashed vertical transition connectors between consecutive blocks.
                    for index in 1..<max(1, blocks.count) {
                        let prev = blocks[index - 1]
                        let cur = blocks[index]
                        let cx = x(forMinute: cur.startMinute, in: size.width)
                        var path = Path()
                        path.move(to: CGPoint(x: cx, y: laneY(prev.stage, in: size)))
                        path.addLine(to: CGPoint(x: cx, y: laneY(cur.stage, in: size)))
                        context.stroke(
                            path,
                            with: .color(Color(hex: "#D2CDFF").opacity(0.46)),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2.5, 3])
                        )
                    }

                    // Horizontal segment per block: soft halo underlay + solid line.
                    for block in blocks {
                        let y = laneY(block.stage, in: size)
                        let startX = x(forMinute: block.startMinute, in: size.width)
                        let endX = x(forMinute: block.startMinute + block.durationMinutes, in: size.width)
                        var path = Path()
                        path.move(to: CGPoint(x: startX, y: y))
                        path.addLine(to: CGPoint(x: max(startX, endX), y: y))
                        let color = SleepStageColors.color(for: block.stage)
                        context.stroke(path, with: .color(color.opacity(0.16)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
                    }
                }
                .padding(.vertical, 16)
                .padding(.leading, 64)
                .padding(.trailing, 16)
            }
            .frame(height: height - 22)

            // Time ticks.
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                    Text(tick.label)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(PulseColors.textMuted)
                    if index != ticks.count - 1 { Spacer() }
                }
            }
            .padding(.leading, 64)
            .padding(.trailing, 16)
        }
        .frame(height: height)
    }
}
