import SwiftUI
import Charts

// Redesigned vitals charts: timestamp x-axis, quiet modern axes, reference bands, and a
// zone-colored line drawn segment-by-segment so excursions stand out without turning calm data
// into a rainbow. Built on top of the threshold engine via an injected `colorForValue` closure.

// MARK: - Reference band

/// A shaded horizontal band behind the line marking a useful range (e.g. SpO₂ 95–100). Resolves its
/// color through a `VitalColorToken`, so it stays consistent with zone coloring everywhere.
struct ReferenceBand: Identifiable, Equatable {
    let id = UUID()
    let lower: Double
    let upper: Double
    let colorToken: VitalColorToken
    var opacity: Double = 0.08

    var color: Color { colorToken.color.opacity(opacity) }
}

// MARK: - Modern axis styling

private extension View {
    /// Quiet dashboard axes: ≤4 time labels on X (hidden gridlines), trailing ≤3 value labels with a
    /// single faint horizontal gridline. Mirrors Apple's "highlight a few things" chart guidance.
    func vitalsAxes(showAxes: Bool, range: MetricRange) -> some View {
        chartXAxis {
            if showAxes {
                if let stride = VitalsAxisFormat.stride(for: range) {
                    // Fixed stride anchored to clean boundaries: 24h → every 6h (12a/6a/12p/6p),
                    // 7d → every day (all 7 weekdays). Avoids the automatic picker's odd offsets.
                    AxisMarks(values: .stride(by: stride.unit, count: stride.count)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick().foregroundStyle(.clear)
                        AxisValueLabel(format: VitalsAxisFormat.dateFormat(for: range))
                            .font(.system(size: 10))
                            .foregroundStyle(PulseColors.textMuted)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick().foregroundStyle(.clear)
                        AxisValueLabel(format: VitalsAxisFormat.dateFormat(for: range))
                            .font(.system(size: 10))
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(PulseColors.borderSubtle)
                    AxisTick().foregroundStyle(.clear)
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
        }
    }
}

enum VitalsAxisFormat {
    /// Time-axis label format per range: hour-of-day for 24h, weekday/day otherwise.
    static func dateFormat(for range: MetricRange) -> Date.FormatStyle {
        switch range {
        case .twentyFourHours: return .dateTime.hour()
        case .sevenDays: return .dateTime.weekday(.narrow)
        case .thirtyDays: return .dateTime.day().month(.abbreviated)
        case .twelveMonths: return .dateTime.month(.abbreviated)
        }
    }

    /// A fixed calendar stride for the x-axis (anchored to clean boundaries), or nil to let Charts
    /// pick automatically. 24h → every 6 hours; 7d → every day; longer ranges stay automatic.
    static func stride(for range: MetricRange) -> (unit: Calendar.Component, count: Int)? {
        switch range {
        case .twentyFourHours: return (.hour, 6)
        case .sevenDays: return (.day, 1)
        case .thirtyDays, .twelveMonths: return nil
        }
    }
}

// MARK: - ZoneLineChart

/// A reusable line chart whose line is colored by zone (via `colorForValue`) and whose background
/// carries reference bands. Swift Charts handles axes/scaling/accessibility; a Canvas overlay draws
/// the multi-colored, gap-broken line so each segment can take its own color.
struct ZoneLineChart: View {
    let samples: [ChartSample]
    let metric: MetricKind
    let yDomain: ClosedRange<Double>
    var referenceBands: [ReferenceBand] = []
    var range: MetricRange = .twentyFourHours
    var showPoints: Bool = false
    var showAxes: Bool = true
    var dashedRules: [Double] = []
    var height: CGFloat = 150
    /// Zone boundaries (y-values) where the line color may change. The line is split at each crossing
    /// so a piece never spans two zones. Empty = no splitting (whole-segment color).
    var thresholds: [Double] = []
    /// Injected from the threshold engine: maps a value to the color its segment should take.
    let colorForValue: (Double) -> Color

    private var timeDomain: ClosedRange<Date>? {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp, first < last else { return nil }
        return first...last
    }

    var body: some View {
        Chart {
            ForEach(referenceBands) { band in
                RectangleMark(
                    yStart: .value("Band low", band.lower),
                    yEnd: .value("Band high", band.upper)
                )
                .foregroundStyle(band.color)
            }
            ForEach(dashedRules, id: \.self) { rule in
                RuleMark(y: .value("Rule", rule))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(PulseColors.textMuted.opacity(0.5))
            }
            if showPoints {
                ForEach(samples) { sample in
                    PointMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Value", sample.value)
                    )
                    .symbolSize(showPoints ? 30 : 0)
                    .foregroundStyle(colorForValue(sample.value))
                    .opacity(sample.quality == .motionArtifact ? 0.4 : 1)
                }
            }
        }
        .chartYScale(domain: yDomain)
        .modify { chart in
            if let timeDomain { chart.chartXScale(domain: timeDomain) } else { chart }
        }
        .vitalsAxes(showAxes: showAxes, range: range)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Canvas { context, _ in
                    guard let plotAnchor = proxy.plotFrame else { return }
                    let plot = geo[plotAnchor]
                    let maxGap = ChartSampleBuilder.maxGap(for: range)
                    for segment in ChartSampleBuilder.segments(samples, maxGap: maxGap) {
                        drawSegment(segment, context: &context, plot: plot, proxy: proxy)
                    }
                }
            }
        }
        .frame(height: height)
    }

    /// Stroke one contiguous segment. Each sample-to-sample pair is split at every zone boundary it
    /// crosses, so each drawn piece lies entirely within one zone and takes that zone's color — the
    /// line then matches the reference bands and legend exactly (no "colored through the wrong area").
    private func drawSegment(_ segment: [ChartSample],
                             context: inout GraphicsContext,
                             plot: CGRect,
                             proxy: ChartProxy) {
        guard segment.count > 1 else {
            // A lone point: draw a small dot so single readings in a window are still visible.
            if let only = segment.first,
               let x = proxy.position(forX: only.timestamp),
               let y = proxy.position(forY: only.value) {
                let p = CGPoint(x: plot.minX + x, y: plot.minY + y)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(colorForValue(only.value)))
            }
            return
        }
        for (a, b) in zip(segment, segment.dropFirst()) {
            let pieces = ZoneLineSplitter.split(
                LinePoint(time: a.timestamp, value: a.value),
                LinePoint(time: b.timestamp, value: b.value),
                thresholds: thresholds
            )
            for (start, end) in pieces {
                guard let x1 = proxy.position(forX: start.time),
                      let y1 = proxy.position(forY: start.value),
                      let x2 = proxy.position(forX: end.time),
                      let y2 = proxy.position(forY: end.value) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: plot.minX + x1, y: plot.minY + y1))
                path.addLine(to: CGPoint(x: plot.minX + x2, y: plot.minY + y2))
                // Midpoint of a within-zone piece lands squarely in its zone.
                let mid = (start.value + end.value) / 2
                context.stroke(
                    path,
                    with: .color(colorForValue(mid)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

// MARK: - Conditional modifier helper

extension View {
    /// Apply a transform that returns a different concrete view type (used to conditionally set
    /// `chartXScale`, which has no "identity" form).
    @ViewBuilder
    func modify<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> some View {
        transform(self)
    }
}
