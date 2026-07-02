import SwiftUI
import Charts

// MARK: - Phase ring

/// One colored arc of the cycle ring, as fractions of the full turn (0…1, clockwise from top).
struct CyclePhaseSegment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let color: Color
}

/// The canonical cycle visual: a ring segmented by phase (period / fertile / luteal over a
/// quiet follicular track) with a marker on the current day and free-form center content.
struct CyclePhaseRing<Center: View>: View {
    let segments: [CyclePhaseSegment]
    /// Current-day position, 0…1 clockwise from top.
    let progress: Double
    var lineWidth: CGFloat = 14
    @ViewBuilder let center: Center

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .stroke(PulseColors.cardSoft, lineWidth: lineWidth)
                ForEach(segments) { segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .fill(PulseColors.textPrimary)
                    .frame(width: lineWidth * 0.62, height: lineWidth * 0.62)
                    .offset(y: -(side - lineWidth) / 2)
                    .rotationEffect(.degrees(progress * 360))
                center
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - BBT chart

/// The basal-temperature chart for one cycle: nightly medians joined by a line, excluded
/// (disturbed) nights as hollow points off the line, the coverline as a dashed rule, and the
/// fertile window as a soft band. Values are stored °C and converted for display only.
struct CycleBBTChart: View {
    let days: [CycleChartDay]
    let coverline: Double?                    // °C
    let fertileWindow: ClosedRange<Date>?
    let units: UnitsPreference

    private func display(_ celsius: Double) -> Double {
        units == .metric ? celsius : celsius * 9 / 5 + 32
    }

    private var validDays: [CycleChartDay] { days.filter { $0.temperature != nil && !$0.excluded } }
    private var excludedDays: [CycleChartDay] { days.filter { $0.temperature != nil && $0.excluded } }

    private var yDomain: ClosedRange<Double> {
        let values = days.compactMap(\.temperature).map(display)
        let pad = units == .metric ? 0.2 : 0.4
        guard let lo = values.min(), let hi = values.max() else {
            return units == .metric ? 35.0...37.5 : 95.0...99.5
        }
        var lower = lo - pad
        var upper = hi + pad
        if let coverline {
            lower = min(lower, display(coverline) - pad)
            upper = max(upper, display(coverline) + pad)
        }
        return lower...upper
    }

    var body: some View {
        Chart {
            if let fertileWindow {
                RectangleMark(
                    xStart: .value("Fertile start", fertileWindow.lowerBound),
                    xEnd: .value("Fertile end", fertileWindow.upperBound.addingTimeInterval(24 * 3600))
                )
                .foregroundStyle(PulseColors.cycleFertile.opacity(0.08))
            }
            ForEach(validDays) { day in
                LineMark(x: .value("Day", day.date), y: .value("Temp", display(day.temperature ?? 0)))
                    .foregroundStyle(PulseColors.cycle)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Day", day.date), y: .value("Temp", display(day.temperature ?? 0)))
                    .foregroundStyle(PulseColors.cycle)
                    .symbolSize(26)
            }
            ForEach(excludedDays) { day in
                PointMark(x: .value("Day", day.date), y: .value("Temp", display(day.temperature ?? 0)))
                    .foregroundStyle(.clear)
                    .symbol {
                        Circle()
                            .strokeBorder(PulseColors.warning, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                    }
            }
            if let coverline {
                RuleMark(y: .value("Coverline", display(coverline)))
                    .foregroundStyle(PulseColors.textMuted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("Coverline")
                            .font(.system(size: 9))
                            .foregroundStyle(PulseColors.textMuted)
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 10))
                    .foregroundStyle(PulseColors.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(PulseColors.borderSubtle)
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)))
                    .font(.system(size: 10))
                    .foregroundStyle(PulseColors.textMuted)
            }
        }
        .frame(height: 210)
    }
}
