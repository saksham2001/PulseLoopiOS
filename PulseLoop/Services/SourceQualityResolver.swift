import Foundation

/// Resolves a metric's display-time `SourceQuality` from timestamps + calibration state. Nothing here
/// is persisted — quality is derived fresh on each rebuild so the UI can be honest about cheap-ring
/// data (estimated, stale, needs calibration) without a storage change.
@MainActor
enum SourceQualityResolver {
    /// Stale once the latest reading is older than this for a dashboard (24h) metric.
    private static let staleAfter: TimeInterval = 90 * 60

    /// The quality treatment for a metric given its newest sample.
    /// - Glucose is always `estimated` (the ring has no real glucose sensor); `needsCalibration` if
    ///   no reference has been entered.
    /// - Blood pressure is `needsCalibration` until a cuff reference exists, otherwise `estimated`.
    /// - Everything else is `stale` past the freshness window, else `good` (or `unknown` with no data).
    static func quality(for metric: MetricKind,
                        latest: Date?,
                        now: Date = Date(),
                        calibration: Calibration) -> SourceQuality {
        switch metric {
        case .glucose:
            return calibration.isGlucoseCalibrated ? .estimated : .needsCalibration
        case .bloodPressure:
            return calibration.hasBPReference ? .estimated : .needsCalibration
        default:
            guard let latest else { return .unknown }
            return now.timeIntervalSince(latest) > staleAfter ? .stale : .good
        }
    }
}
