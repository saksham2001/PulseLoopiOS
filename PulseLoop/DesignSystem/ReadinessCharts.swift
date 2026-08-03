import SwiftUI
import Charts

/// One scored morning, flattened for charting.
struct ReadinessTrendPoint: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let score: Int
    let band: ReadinessBand
}

/// Readiness over time: one bar per scored morning, coloured by band, with a 7-day rolling mean
/// laid over it so a single rough night reads as noise rather than a trend.
///
/// **This chart is accessible to VoiceOver**, via `accessibilityChartDescriptor` plus per-bar
/// labels. No other chart in the app is, today — `Charts.swift`, `VitalsCharts.swift` and
/// `ActivityCharts.swift` are all opaque to screen readers. This is the pattern to back-port.
struct ReadinessTrendChart: View {
    let points: [ReadinessTrendPoint]
    var height: CGFloat = 220

    /// Trailing 7-point mean. Emitted only once there are enough points behind it to mean
    /// something, so the line doesn't start by tracking the bars exactly.
    private var rollingMean: [(date: Date, value: Double)] {
        guard points.count >= 3 else { return [] }
        let window = 7
        return points.indices.compactMap { index in
            let lower = max(0, index - window + 1)
            let slice = points[lower...index]
            guard slice.count >= 3 else { return nil }
            let mean = Double(slice.reduce(0) { $0 + $1.score }) / Double(slice.count)
            return (points[index].date, mean)
        }
    }

    private func color(_ band: ReadinessBand) -> Color {
        ReadinessZones.all.first { $0.label == band.rawValue }?.color ?? PulseColors.readiness
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Readiness", point.score)
                )
                .foregroundStyle(color(point.band).opacity(0.85))
                .cornerRadius(3)
                .accessibilityLabel(Self.dayFormatter.string(from: point.date))
                .accessibilityValue("\(point.score), \(point.band.rawValue)")
            }

            ForEach(rollingMean, id: \.date) { entry in
                LineMark(
                    x: .value("Day", entry.date, unit: .day),
                    y: .value("7-day average", entry.value)
                )
                .foregroundStyle(PulseColors.textPrimary.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 55, 70, 85, 100]) { value in
                AxisGridLine().foregroundStyle(PulseColors.textMuted.opacity(0.15))
                AxisValueLabel {
                    if let score = value.as(Int.self) {
                        Text("\(score)")
                            .font(PulseFont.micro)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.axisFormatter.string(from: date))
                            .font(PulseFont.micro)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityChartDescriptor(self)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
}

/// Makes the trend chart navigable with the VoiceOver rotor — swipe through days and hear each
/// score rather than being told only "chart".
extension ReadinessTrendChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let scores = points.map { Double($0.score) }
        let dates = points.map(\.date)

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Day",
            categoryOrder: dates.map { Self.dayFormatter.string(from: $0) }
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: "Readiness",
            range: 0...100,
            gridlinePositions: [55, 70, 85]
        ) { value in
            // The framework probes this closure with values we don't control, including non-finite
            // ones. `Int(someDouble)` traps on infinity and NaN, which would crash the app outright
            // — and only ever for VoiceOver users, who are the last people who should hit it.
            guard value.isFinite else { return "No value" }
            let score = Int(min(100, max(0, value.rounded())))
            return "\(score) out of 100, \(ReadinessScore.band(score).rawValue)"
        }

        let series = AXDataSeriesDescriptor(
            name: "Readiness",
            isContinuous: false,
            dataPoints: zip(dates, scores).map { date, score in
                AXDataPoint(
                    x: Self.dayFormatter.string(from: date),
                    y: score,
                    additionalValues: [],
                    label: ReadinessScore.band(Int(score)).rawValue
                )
            }
        )

        return AXChartDescriptor(
            title: "Readiness over time",
            summary: summaryText,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    /// Spoken before the data — the shape of the trend, so a screen-reader user gets the point
    /// without stepping through every bar.
    private var summaryText: String {
        guard !points.isEmpty else { return "No readiness scores yet." }
        let scores = points.map(\.score)
        let mean = scores.reduce(0, +) / scores.count
        return "\(points.count) scored days, averaging \(mean) out of 100, "
            + "ranging from \(scores.min() ?? 0) to \(scores.max() ?? 0)."
    }
}

/// One contributor's share of the score: name, its explanation, and an earned/possible bar.
/// The bar is what makes the arithmetic legible — "18 of 30" is abstract; a two-thirds-filled bar
/// next to a full one is not.
struct ReadinessContributorRow: View {
    let record: ReadinessContributorRecord

    private var fraction: Double {
        guard record.maxPoints > 0 else { return 0 }
        return max(0, min(1, record.earned / record.maxPoints))
    }

    /// Green when it earned nearly everything, amber mid, orange when it's the thing holding the
    /// score down. Colouring by *share earned* rather than by contributor identity means the eye
    /// lands on the problem.
    private var barColor: Color {
        if fraction >= 0.85 { return PulseColors.zoneMint }
        if fraction >= 0.55 { return PulseColors.zoneAmber }
        return PulseColors.zoneOrange
    }

    private var title: String {
        record.kind?.title ?? record.kindRaw.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(PulseFont.callout.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer(minLength: 8)
                Text("\(formatted(record.earned)) of \(formatted(record.maxPoints))")
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PulseColors.textMuted.opacity(0.15))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)

            Text(record.detail)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(record.detail). Earned \(formatted(record.earned)) of \(formatted(record.maxPoints)) points.")
    }

    /// Points are fractional but rarely interestingly so — trim a trailing ".0".
    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
