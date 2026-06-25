import Foundation

/// How densely vitals charts are drawn. High measurement frequency produces hundreds of points that
/// make charts noisy; coarser resolutions bucket-average those points into a smoother line. This is a
/// pure display preference — raw `Measurement` rows are never modified.
enum GraphResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case full      // every stored point
    case smooth    // light averaging
    case coarse    // heavy averaging

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full"
        case .smooth: return "Smooth"
        case .coarse: return "Coarse"
        }
    }

    var blurb: String {
        switch self {
        case .full: return "Every sample, no averaging"
        case .smooth: return "Lightly averaged for a cleaner line"
        case .coarse: return "Heavily averaged for the smoothest trend"
        }
    }

    /// Target number of plotted points for a given range. `0` means "no downsampling" (identity).
    /// Tuned per range so a denser 24h view smooths more aggressively than a sparse year view.
    func targetBuckets(for range: MetricRange) -> Int {
        switch self {
        case .full:
            return 0
        case .smooth:
            switch range {
            case .twentyFourHours: return 120
            case .sevenDays: return 168
            case .thirtyDays: return 120
            case .twelveMonths: return 0
            }
        case .coarse:
            switch range {
            case .twentyFourHours: return 48
            case .sevenDays: return 56
            case .thirtyDays: return 60
            case .twelveMonths: return 0
            }
        }
    }
}

/// User-tunable metric/display preferences, persisted as JSON in `UserDefaults`. Mirrors the
/// `CoachSettingsStore` pattern.
struct MetricPrefs: Codable, Equatable {
    /// Metrics the user has explicitly hidden (by `MetricKey.rawValue`). Stored as an opt-out set so a
    /// newly supported metric defaults to *visible* without any migration.
    var hiddenMetrics: Set<String> = []
    var resolution: GraphResolution = .full

    static let `default` = MetricPrefs()

    init() {}

    /// Tolerant decode: missing keys fall back to defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MetricPrefs.default
        hiddenMetrics = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenMetrics) ?? d.hiddenMetrics
        resolution = try c.decodeIfPresent(GraphResolution.self, forKey: .resolution) ?? d.resolution
    }
}

/// Observable, UserDefaults-backed store for `MetricPrefs`. Mutating `settings` persists immediately;
/// a shared instance keeps Settings and every vitals view in sync.
@MainActor
@Observable
final class MetricPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = MetricPrefsStore()

    private static let storageKey = "pulseloop.metricprefs.v1"
    private let defaults: UserDefaults

    var settings: MetricPrefs {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(MetricPrefs.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    /// Whether the user has hidden a metric (visibility is layered on top of device capability
    /// elsewhere — see `MetricsService.isVisible`).
    func isHidden(_ metric: MetricKey) -> Bool {
        settings.hiddenMetrics.contains(metric.rawValue)
    }

    func setHidden(_ metric: MetricKey, _ hidden: Bool) {
        if hidden {
            settings.hiddenMetrics.insert(metric.rawValue)
        } else {
            settings.hiddenMetrics.remove(metric.rawValue)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
