import SwiftUI

// The proportional sleep-stage bar, extracted from TodayTiles.swift so the widget extension can
// render the Sleep tile without pulling in `SleepStageDistribution` (which needs the SwiftData-backed
// `SleepSummary`). Segments are plain value inputs; the app derives them from a sleep summary, the
// widget decodes them from the shared snapshot. Shared between the app and PulseLoopWidgets targets.

/// One colored segment of the sleep-stage bar, with a short label ("DEEP"/"LIGHT"/"REM"/"AWAKE").
struct SleepStageSegment: Identifiable {
    let id = UUID()
    let minutes: Double
    let color: Color
    let label: String
}

/// A rounded horizontal bar whose segment widths are proportional to their minutes, with a tiny
/// stage label under each segment. Labels are dropped (not squeezed) when their segment is too
/// narrow to fit them, so short awake/REM slivers never render clipped text.
struct SleepStageBar: View {
    let segments: [SleepStageSegment]

    private let spacing: CGFloat = 2
    private let barHeight: CGFloat = 12
    private var total: Double { max(segments.reduce(0) { $0 + $1.minutes }, 1) }

    /// Segment pixel widths for a given track width, after reserving inter-segment spacing.
    private func widths(for trackWidth: CGFloat) -> [CGFloat] {
        let gaps = CGFloat(max(0, segments.count - 1)) * spacing
        let usable = max(0, trackWidth - gaps)
        return segments.map { CGFloat($0.minutes / total) * usable }
    }

    /// Segments below this share of the night don't get a label — a sliver's label would dominate
    /// the sliver itself and clutter the bar.
    private let minLabelShare = 0.10

    private func showsLabel(_ segment: SleepStageSegment) -> Bool {
        segment.minutes / total >= minLabelShare
    }

    var body: some View {
        GeometryReader { geo in
            let ws = widths(for: geo.size.width)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: spacing) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        segment.color.frame(width: ws[index])
                    }
                }
                .frame(height: barHeight)
                .clipShape(Capsule())
                HStack(spacing: spacing) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        Text(showsLabel(segment) ? segment.label : "")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(segment.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: ws[index])
                    }
                }
            }
        }
    }
}
