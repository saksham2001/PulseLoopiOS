import Foundation
import SwiftData

/// Learns the user's resting heart rate — the 10th percentile of the last 30 days of HR samples —
/// and persists it on `UserProfile.hrRestingBaseline` for the threshold engine's `.auto` zone mode.
///
/// Persisting (rather than computing per-view) guarantees the dashboard card and the detail screen
/// always color the same value identically: every zone lookup reads the same stored baseline via
/// `UserPhysiologyProfile`, never view-local samples. Refreshes are throttled and windowed so this
/// never becomes a hot path.
enum RestingHRBaselineService {
    static let refreshInterval: TimeInterval = 6 * 3600
    static let windowDays = 30
    /// Establishment gate, mirroring `BaselineStats.isEstablished`: about a week of wear with
    /// enough samples before we trust a personal baseline.
    static let minSamples = 20
    static let minSpanDays = 7.0
    /// 30 days of continuous ring sampling is a few thousand rows; cap the fetch defensively.
    static let fetchLimit = 5000

    /// Recompute the learned resting HR if the last refresh is stale. Bumps `profile.updatedAt`
    /// only when the rounded value actually changes, so the `VitalsStore` signature invalidates
    /// exactly when colors must change (and not every 6 hours).
    @MainActor
    static func refreshIfStale(context: ModelContext, now: Date = Date()) {
        let profiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        guard let profile = profiles.first else { return }
        if let last = profile.hrRestingBaselineUpdatedAt, now.timeIntervalSince(last) < refreshInterval {
            return
        }

        let start = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let samples = MetricsRepository.measurements(
            kind: .heartRate, start: start, end: now, limit: fetchLimit, context: context
        )
        let values = samples.map(\.value).filter { $0 > 0 }
        let timestamps = samples.map(\.timestamp)
        let spanDays: Double
        if let first = timestamps.min(), let last = timestamps.max() {
            spanDays = last.timeIntervalSince(first) / 86_400
        } else {
            spanDays = 0
        }

        let established = values.count >= minSamples && spanDays >= minSpanDays
        let newBaseline = established ? percentile(values.sorted(), 0.10) : nil

        // Stamp the refresh time even when not established, so we don't rescan on every foreground.
        profile.hrRestingBaselineUpdatedAt = now
        let changed = Int(newBaseline?.rounded() ?? -1) != Int(profile.hrRestingBaseline?.rounded() ?? -1)
        if changed {
            profile.hrRestingBaseline = newBaseline
            profile.updatedAt = now
        }
        try? context.save()
    }

    /// Interpolated percentile (same formula as `BaselineStats.compute`).
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
