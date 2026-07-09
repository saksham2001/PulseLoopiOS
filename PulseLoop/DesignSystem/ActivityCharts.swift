import SwiftUI
import Charts

// Zone-colored charts for a recorded activity. Same visual language as the vitals detail charts
// (x & y axes, zone-colored + threshold-split line, reference bands), but the x-axis is MINUTES INTO
// THE ACTIVITY (0→N) rather than clock time. Reuses `ZoneLineSplitter` (value-space overload) and the
// threshold engine so activity HR/SpO₂ color exactly like everywhere else. Sizes are caller-driven so
// the surrounding activity card UI stays unchanged.

/// One activity sample already reduced to elapsed minutes + value.
private struct MinuteSample: Identifiable {
    let id = UUID()
    let minute: Double
    let value: Double
}

struct ActivityZoneLineChart: View {
    let metric: MetricKind
    let yDomain: ClosedRange<Double>
    var referenceBands: [ReferenceBand] = []
    var dashedRules: [Double] = []
    var showPoints: Bool = false
    /// Zone boundaries (y-values) where the line color changes; the line is split at each crossing.
    var thresholds: [Double] = []
    var height: CGFloat = 120
    /// Maps a value to its zone color (injected once from the threshold engine).
    let colorForValue: (Double) -> Color

    // Sorted/reduced once at init — inputs are immutable per instantiation, so recomputing these
    // as computed properties on every body evaluation was pure waste.
    private let minuteSamples: [MinuteSample]
    private let maxMinute: Double

    /// - Parameters:
    ///   - samples: Absolute-timestamp samples for the session (HR or SpO₂).
    ///   - startAt: Session start; each sample's x = minutes since this.
    init(samples: [MetricSample], startAt: Date, metric: MetricKind, yDomain: ClosedRange<Double>,
         referenceBands: [ReferenceBand] = [], dashedRules: [Double] = [], showPoints: Bool = false,
         thresholds: [Double] = [], height: CGFloat = 120,
         colorForValue: @escaping (Double) -> Color) {
        self.metric = metric
        self.yDomain = yDomain
        self.referenceBands = referenceBands
        self.dashedRules = dashedRules
        self.showPoints = showPoints
        self.thresholds = thresholds
        self.height = height
        self.colorForValue = colorForValue
        self.minuteSamples = samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { MinuteSample(minute: $0.timestamp.timeIntervalSince(startAt) / 60, value: $0.value) }
        self.maxMinute = max(minuteSamples.last?.minute ?? 1, 1)
    }

    /// The gap (in minutes) above which we break the line, adapted to THIS session's own sampling
    /// cadence. A retroactively-backfilled session may only have an HR reading every few minutes; a
    /// live-recorded one has them every few seconds. A fixed threshold would leave the sparse one as
    /// disconnected dots. So we break only when a gap is much larger than the median spacing —
    /// connecting normally-spaced data of any cadence while still splitting on real dropouts.
    private func breakGapMinutes(_ points: [MinuteSample]) -> Double {
        guard points.count > 2 else { return .greatestFiniteMagnitude }   // too few to break
        let gaps = zip(points, points.dropFirst()).map { $1.minute - $0.minute }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return .greatestFiniteMagnitude }
        let median = gaps[gaps.count / 2]
        // Break at >4× the typical spacing, but never below 3 min (so tiny jitter never breaks) nor
        // above 15 min (so a genuine long dropout always breaks).
        return min(15, max(3, median * 4))
    }

    var body: some View {
        let points = minuteSamples
        Chart {
            ForEach(referenceBands) { band in
                RectangleMark(yStart: .value("Band low", band.lower), yEnd: .value("Band high", band.upper))
                    .foregroundStyle(band.color)
            }
            ForEach(dashedRules, id: \.self) { rule in
                RuleMark(y: .value("Rule", rule))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(PulseColors.textMuted.opacity(0.5))
            }
            if showPoints {
                ForEach(points) { p in
                    PointMark(x: .value("Minutes", p.minute), y: .value("Value", p.value))
                        .symbolSize(28)
                        .foregroundStyle(colorForValue(p.value))
                }
            }
        }
        .chartXScale(domain: 0...maxMinute)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let minute = value.as(Double.self) {
                        Text("\(Int(minute))m").font(PulseFont.micro.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(PulseColors.borderSubtle)
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel().font(PulseFont.micro.weight(.regular)).foregroundStyle(PulseColors.textMuted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Canvas { context, _ in
                    guard let anchor = proxy.plotFrame else { return }
                    let plot = geo[anchor]
                    drawLine(points, context: &context, plot: plot, proxy: proxy)
                }
            }
        }
        .frame(height: height)
    }

    /// Draw the zone-colored line: break at dropouts, split each pair at zone thresholds, color each
    /// piece by its midpoint value. Mirrors `ZoneLineChart.drawSegment` but on a numeric minutes x.
    private func drawLine(_ points: [MinuteSample], context: inout GraphicsContext, plot: CGRect, proxy: ChartProxy) {
        guard points.count > 1 else {
            if let only = points.first,
               let x = proxy.position(forX: only.minute), let y = proxy.position(forY: only.value) {
                let p = CGPoint(x: plot.minX + x, y: plot.minY + y)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(colorForValue(only.value)))
            }
            return
        }
        let breakGap = breakGapMinutes(points)
        for (a, b) in zip(points, points.dropFirst()) {
            guard b.minute - a.minute <= breakGap else { continue }   // real dropout → break the line
            let pieces = ZoneLineSplitter.split(x0: a.minute, v0: a.value, x1: b.minute, v1: b.value, thresholds: thresholds)
            for (start, end) in pieces {
                guard let x1 = proxy.position(forX: start.x), let y1 = proxy.position(forY: start.value),
                      let x2 = proxy.position(forX: end.x), let y2 = proxy.position(forY: end.value) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: plot.minX + x1, y: plot.minY + y1))
                path.addLine(to: CGPoint(x: plot.minX + x2, y: plot.minY + y2))
                let mid = (start.value + end.value) / 2
                context.stroke(path, with: .color(colorForValue(mid)),
                               style: StrokeStyle(lineWidth: showPoints ? 1.5 : 3, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
