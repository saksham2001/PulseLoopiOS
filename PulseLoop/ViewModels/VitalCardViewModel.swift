import SwiftUI

/// Fully-prepared state for a single vitals card. Computed once per `VitalsStore` rebuild (off the
/// SwiftUI `body` path) so views never run threshold/baseline/trend math during layout. Equatable so
/// SwiftUI can diff cheaply.

enum TrendDirection: Equatable {
    case rising
    case falling
    case stable
    case insufficientData
}

struct TrendSummary: Equatable {
    let direction: TrendDirection
    let deltaText: String?
    /// SF Symbol name for the trend arrow.
    let symbol: String

    static let insufficient = TrendSummary(direction: .insufficientData, deltaText: nil, symbol: "minus")

    /// Compute a trend from samples. Dense series (many points across the window) compare the recent
    /// half-window mean to the prior half-window mean; sparse series compare the latest two readings.
    /// HRV compares the latest value to its baseline mean. Requires ≥3 meaningful samples.
    static func compute(samples: [ChartSample],
                        metric: MetricKind,
                        baseline: BaselineStats? = nil,
                        unitLabel: String = "") -> TrendSummary {
        let values = samples.map(\.value).filter { $0 > 0 }
        guard values.count >= 3 else { return .insufficient }

        // HRV: latest vs personal baseline.
        if metric == .hrv, let baseline, baseline.isEstablished {
            let latest = values.last ?? baseline.mean
            return summarize(delta: latest - baseline.mean, unitLabel: unitLabel, suffix: "vs baseline")
        }

        // Dense (≥8 points over the window): split at the time midpoint, compare half means.
        if samples.count >= 8, let first = samples.first?.timestamp, let last = samples.last?.timestamp {
            let mid = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
            let recent = samples.filter { $0.timestamp >= mid }.map(\.value)
            let prior = samples.filter { $0.timestamp < mid }.map(\.value)
            if let r = mean(recent), let p = mean(prior) {
                return summarize(delta: r - p, unitLabel: unitLabel, suffix: "vs earlier")
            }
        }

        // Sparse: latest minus previous.
        let latest = values[values.count - 1]
        let previous = values[values.count - 2]
        return summarize(delta: latest - previous, unitLabel: unitLabel, suffix: "vs previous")
    }

    private static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Build a summary from a signed delta. A small delta reads as "stable"; otherwise rising/falling
    /// with a `+N unit suffix` label.
    private static func summarize(delta: Double, unitLabel: String, suffix: String) -> TrendSummary {
        let rounded = (abs(delta) < 1 && delta != 0) ? Double(Int(delta * 10)) / 10 : delta.rounded()
        if abs(rounded) < 0.5 {
            return TrendSummary(direction: .stable, deltaText: "Stable \(suffix)", symbol: "arrow.right")
        }
        let unit = unitLabel.isEmpty ? "" : " \(unitLabel)"
        let sign = rounded > 0 ? "+" : "−"
        let magnitude = abs(rounded) == abs(rounded).rounded() ? "\(Int(abs(rounded)))" : "\(abs(rounded))"
        let text = "\(sign)\(magnitude)\(unit) \(suffix)"
        return TrendSummary(
            direction: rounded > 0 ? .rising : .falling,
            deltaText: text,
            symbol: rounded > 0 ? "arrow.up.right" : "arrow.down.right"
        )
    }
}

/// The complete, view-ready model for one metric card.
struct VitalCardViewModel: Identifiable, Equatable {
    var id: MetricKind { metric }
    let metric: MetricKind
    let title: String
    let valueText: String
    let unitText: String?
    let statusText: String
    let statusColor: Color
    let subtitleText: String?
    let samples: [ChartSample]
    let zones: [MetricZone]
    let yDomain: ClosedRange<Double>
    let referenceBands: [ReferenceBand]
    let dashedRules: [Double]
    let trend: TrendSummary
    let sourceQuality: SourceQuality
    let isEstimated: Bool
    let confidenceLabel: String?
    let lastUpdatedText: String?
    /// True when there's nothing to chart yet (drives the empty-state card while preserving height).
    let isEmpty: Bool

    var accentColor: Color { metric.accentColor }
}
