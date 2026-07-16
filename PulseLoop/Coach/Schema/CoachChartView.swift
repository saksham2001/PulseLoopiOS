import SwiftUI
import Charts

/// Renders a `CoachChart` whose data is already embedded (computed by the
/// `prepare_chart` tool). Generic over the five chart types; uses the point
/// index for x-position so heterogeneous x labels (dates, minutes) stay ordered.
///
/// The y-axis autoscales to the data (trend charts never get forced through 0,
/// so trends stay visible and lines don't fall off-frame), and `sleep_stage`
/// reuses the Sleep page's hypnogram instead of thin bars.
struct CoachChartView: View {
    let chart: CoachChart
    var height: CGFloat = 170

    private var color: Color {
        switch chart.metric {
        case .steps: return PulseColors.steps
        case .hr: return PulseColors.heartRate
        case .spo2: return PulseColors.spo2
        case .sleep: return PulseColors.sleep
        case .activeMinutes: return PulseColors.accent
        case .calories: return PulseColors.calories
        case .distance: return PulseColors.distance
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chart.title)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textSecondary)

            if chart.data.isEmpty {
                Text("No data to plot for this range.")
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else if chart.chartType == .sleepStage {
                sleepHypnogram
            } else {
                plot.frame(height: height)
            }

            if !chart.annotations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chart.annotations) { a in
                        Text("• \(a.label)")
                            .font(PulseFont.caption2.weight(.regular))
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Solid card fill, not glass: this chart card renders inside the assistant bubble's
        // glass, and glass can't sample glass (renders flat). A card fill + hairline keeps it
        // reading as a distinct raised surface.
        .background(PulseColors.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Standard plot (line / dot / bar / sparkline)

    @ViewBuilder private var plot: some View {
        let indexed = Array(chart.data.enumerated())
        let domain = yDomain
        let showPoints = chart.data.count <= 8

        switch chart.chartType {
        case .line:
            Chart(indexed, id: \.offset) { i, point in
                LineMark(x: .value("i", i), y: .value("y", point.y))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(color)
                if showPoints {
                    PointMark(x: .value("i", i), y: .value("y", point.y))
                        .symbolSize(20)
                        .foregroundStyle(color)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis { axisMarks }

        case .sparkline:
            Chart(indexed, id: \.offset) { i, point in
                LineMark(x: .value("i", i), y: .value("y", point.y))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(color)
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)

        case .dot:
            Chart(indexed, id: \.offset) { i, point in
                PointMark(x: .value("i", i), y: .value("y", point.y))
                    .symbolSize(34)
                    .foregroundStyle(color)
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis { axisMarks }

        case .bar:
            Chart(indexed, id: \.offset) { i, point in
                BarMark(x: .value("x", point.x), y: .value("y", point.y))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                    .foregroundStyle(color.opacity(0.85))
            }
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(6, chart.data.count))) { _ in
                    AxisValueLabel().font(PulseFont.nano.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                }
            }
            .chartYAxis { axisMarks }

        case .sleepStage:
            EmptyView()  // handled by `sleepHypnogram`
        }
    }

    private var axisMarks: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(PulseColors.borderSubtle)
            AxisValueLabel().font(PulseFont.nano.weight(.regular)).foregroundStyle(PulseColors.textMuted)
        }
    }

    private var yDomain: ClosedRange<Double> {
        CoachChartView.yDomain(values: chart.data.map(\.y), chartType: chart.chartType, metric: chart.metric)
    }

    /// Data-hugging y-domain. Magnitude bars stay 0-based; trends pad around the
    /// data; hr/spo2 always autoscale (a 0 baseline is meaningless for them) and
    /// spo2 is clamped to ≤100. Pure + static so it can be unit-tested.
    static func yDomain(values: [Double], chartType: CoachChartType, metric: CoachChartMetric) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }

        let magnitudeBar = chartType == .bar
            && [.steps, .calories, .distance, .activeMinutes, .sleep].contains(metric)

        let range: ClosedRange<Double>
        if lo == hi {
            let pad = Swift.max(abs(lo) * 0.1, 1)
            range = (magnitudeBar ? 0 : lo - pad)...(hi + pad)
        } else if magnitudeBar {
            range = 0...(hi * 1.15)
        } else {
            let pad = Swift.max((hi - lo) * 0.15, hi * 0.02, 1)
            range = (lo - pad)...(hi + pad)
        }

        guard metric == .spo2 else { return range }
        let upper = Swift.min(range.upperBound, 100)
        return range.lowerBound...Swift.max(upper, range.lowerBound + 1)
    }

    // MARK: - Sleep hypnogram (reuses the Sleep page component)

    private var sleepHypnogram: some View {
        let blocks = chart.data.compactMap { point -> SleepStageBlock? in
            guard let stage = SleepStage(rawValue: point.series ?? ""), let start = Int(point.x) else { return nil }
            return SleepStageBlock(
                sessionId: UUID(), startAt: Date(),
                startMinute: start, durationMinutes: Int(point.y), stage: stage
            )
        }
        let total = blocks.map { $0.startMinute + $0.durationMinutes }.max() ?? 0
        return Group {
            if blocks.isEmpty || total == 0 {
                Text("No sleep stages to plot.")
                    .font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                SleepHypnogramView(blocks: blocks, totalMin: total, startTs: nil, height: height + 30)
            }
        }
    }
}
