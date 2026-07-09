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

/// Which screen a visibility/chart-detail preference applies to. The Today and Vitals pages keep
/// fully independent preference scopes so hiding a tile (or coarsening a chart) on one page never
/// affects the other.
enum MetricScope: String, Codable, Sendable {
    case today
    case vitals
}

/// User-tunable metric/display preferences, persisted as JSON in `UserDefaults`. Mirrors the
/// `CoachSettingsStore` pattern.
///
/// The original single-scope fields (`hiddenMetrics`/`resolution`) are retained as the **Vitals**
/// scope so existing users' saved preferences migrate for free; the `today*` fields default to
/// visible/full for anyone upgrading.
struct MetricPrefs: Codable, Equatable {
    /// Vitals-scope hidden metrics (by `MetricKey.rawValue`). Opt-out set so a newly supported metric
    /// defaults to *visible* without any migration.
    var hiddenMetrics: Set<String> = []
    var resolution: GraphResolution = .full
    /// Today-scope hidden metrics, independent of the Vitals scope.
    var todayHiddenMetrics: Set<String> = []
    var todayResolution: GraphResolution = .full
    /// User-chosen card order per scope, stored as `MetricKey.rawValue`s. Empty means
    /// "use the screen's default order". Keys not present here fall back to their
    /// default position, so a newly supported metric appears without any migration.
    var vitalsOrder: [String] = []
    var todayOrder: [String] = []

    static let `default` = MetricPrefs()

    init() {}

    /// Tolerant decode: missing keys fall back to defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MetricPrefs.default
        hiddenMetrics = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenMetrics) ?? d.hiddenMetrics
        resolution = try c.decodeIfPresent(GraphResolution.self, forKey: .resolution) ?? d.resolution
        todayHiddenMetrics = try c.decodeIfPresent(Set<String>.self, forKey: .todayHiddenMetrics) ?? d.todayHiddenMetrics
        todayResolution = try c.decodeIfPresent(GraphResolution.self, forKey: .todayResolution) ?? d.todayResolution
        vitalsOrder = try c.decodeIfPresent([String].self, forKey: .vitalsOrder) ?? d.vitalsOrder
        todayOrder = try c.decodeIfPresent([String].self, forKey: .todayOrder) ?? d.todayOrder
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

    /// Whether the user has hidden a metric in a given scope (visibility is layered on top of device
    /// capability elsewhere — see `MetricsService.isVisible`). Non-scoped callers default to `.vitals`.
    func isHidden(_ metric: MetricKey, scope: MetricScope = .vitals) -> Bool {
        switch scope {
        case .vitals: return settings.hiddenMetrics.contains(metric.rawValue)
        case .today: return settings.todayHiddenMetrics.contains(metric.rawValue)
        }
    }

    func setHidden(_ metric: MetricKey, _ hidden: Bool, scope: MetricScope = .vitals) {
        switch scope {
        case .vitals:
            if hidden { settings.hiddenMetrics.insert(metric.rawValue) } else { settings.hiddenMetrics.remove(metric.rawValue) }
        case .today:
            if hidden { settings.todayHiddenMetrics.insert(metric.rawValue) } else { settings.todayHiddenMetrics.remove(metric.rawValue) }
        }
    }

    /// The chart-detail (downsampling) resolution for a scope.
    func resolution(for scope: MetricScope) -> GraphResolution {
        switch scope {
        case .vitals: return settings.resolution
        case .today: return settings.todayResolution
        }
    }

    func setResolution(_ resolution: GraphResolution, for scope: MetricScope) {
        switch scope {
        case .vitals: settings.resolution = resolution
        case .today: settings.todayResolution = resolution
        }
    }

    // MARK: - Card order

    /// The saved card order (`MetricKey.rawValue`s) for a scope; empty until the user reorders.
    func order(for scope: MetricScope) -> [String] {
        scope == .today ? settings.todayOrder : settings.vitalsOrder
    }

    func setOrder(_ order: [String], for scope: MetricScope) {
        switch scope {
        case .today: settings.todayOrder = order
        case .vitals: settings.vitalsOrder = order
        }
    }

    /// Resolves the display order for a set of currently-visible card ids: the saved order (filtered
    /// to visible), with any visible-but-unordered id slotted into its `defaultOrder` neighbourhood
    /// rather than appended. A card restored from the Hidden tray, or a metric a newly-paired ring
    /// just unlocked, therefore reappears where the user expects instead of at the bottom. With no
    /// saved order this reduces to `defaultOrder` filtered by `visible`.
    func resolvedOrder(visible: Set<String>, defaultOrder: [String], scope: MetricScope) -> [String] {
        var result = order(for: scope).filter { visible.contains($0) }
        let saved = Set(result)
        for (i, id) in defaultOrder.enumerated() where visible.contains(id) && !saved.contains(id) {
            // Land just after the nearest metric that precedes `id` by default and already has a slot.
            // Earlier inserts are visible to later ones, so a run of missing ids keeps its default order.
            let anchor = defaultOrder[..<i].last { result.contains($0) }
            let at = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: at)
        }
        return result
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
