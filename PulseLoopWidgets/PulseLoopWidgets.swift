import WidgetKit
import SwiftUI

// The three PulseLoop home-screen widgets (issue #36). All use `PulseColors.card` as the container
// background so the system corner mask produces the same card the Today grid draws by hand.

// MARK: - 1. Full-width activity (fixed)

/// The Activity-page daily summary as a medium widget: colored Steps / Distance / Calories on the
/// left, the three concentric progress rings on the right.
struct PulseLoopActivityWidget: Widget {
    let kind = "PulseLoopActivityWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActivitySnapshotProvider()) { entry in
            WidgetActivityFullContent(payload: entry.snapshot?.activity, rolledOver: entry.rolledOver)
                .overlay(alignment: .topTrailing) {
                    if let asOf = entry.stalenessDate {
                        Text(asOf, style: .time)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(PulseColors.textMuted.opacity(0.8))
                    }
                }
                .containerBackground(PulseColors.card, for: .widget)
        }
        .configurationDisplayName("Daily Activity")
        .description("Steps, distance, and calories with your progress rings.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - 2. Half-width configurable metric

/// One Today tile of your choice as a small widget (long-press → Edit Widget to pick the metric).
struct PulseLoopMetricWidget: Widget {
    let kind = "PulseLoopMetricWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SingleMetricConfigIntent.self,
                               provider: SingleMetricProvider()) { entry in
            WidgetMetricTileView(metric: entry.single, entry: entry)
                .containerBackground(PulseColors.card, for: .widget)
        }
        .configurationDisplayName("Metric Tile")
        .description("A Today tile of your choice — activity, sleep, heart rate, and more.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - 3. Full-width configurable pair

/// Two Today tiles side by side on one continuous card (no inner borders), left and right
/// independently configurable.
struct PulseLoopDualMetricWidget: Widget {
    let kind = "PulseLoopDualMetricWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DualMetricConfigIntent.self,
                               provider: DualMetricProvider()) { entry in
            HStack(spacing: 16) {
                WidgetMetricTileView(metric: entry.left, entry: entry)
                WidgetMetricTileView(metric: entry.right, entry: entry)
            }
            .containerBackground(PulseColors.card, for: .widget)
        }
        .configurationDisplayName("Two Metric Tiles")
        .description("Two Today tiles side by side, each configurable.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Previews (render against the bundled sample snapshot)

#Preview("Activity", as: .systemMedium) {
    PulseLoopActivityWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample)
}

#Preview("Single metric", as: .systemSmall) {
    PulseLoopMetricWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample, single: .activity)
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample, single: .heartRate)
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample, single: .stress)
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample, single: .sleep)
}

#Preview("Dual metric", as: .systemMedium) {
    PulseLoopDualMetricWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample, left: .activity, right: .heartRate)
    SnapshotEntry(date: .now, snapshot: WidgetSnapshotLoader.sample, left: .sleep, right: .stress)
}
