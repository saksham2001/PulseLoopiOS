import AppIntents
import WidgetKit

/// Configuration for the half-width (systemSmall) widget: one metric, picked via Edit Widget.
struct SingleMetricConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Metric"
    static let description = IntentDescription("Pick which PulseLoop metric this widget shows.")

    @Parameter(title: "Metric", default: .activity)
    var metric: WidgetMetric
}

/// Configuration for the full-width (systemMedium) widget: two tiles side by side.
struct DualMetricConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Metrics"
    static let description = IntentDescription("Pick the left and right PulseLoop metrics.")

    @Parameter(title: "Left Metric", default: .activity)
    var left: WidgetMetric

    @Parameter(title: "Right Metric", default: .heartRate)
    var right: WidgetMetric
}
