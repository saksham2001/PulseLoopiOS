import Foundation

/// User-tunable nutrition-tracking preferences, persisted as JSON in `UserDefaults`.
///
/// Privacy-first: `masterEnabled` defaults to **false** — no nutrition UI, no coach context, no
/// tools, no export until the user explicitly opts in from Settings → Nutrition. Once the master
/// toggle is on, the sub-toggles each default **on** so a single tap lights up the full feature;
/// the user can then narrow it. Mirrors the `AppleHealthPrefsStore` pattern — no SwiftData, no
/// migration — with tolerant decode so adding a future key never wipes an existing user's blob.
///
/// Goal *values* (intake kcal + macro grams) live on `UserGoal`, not here — one source of truth
/// shared by the goals editor and the coach's `set_goal` tool.
struct NutritionPrefs: Codable, Equatable {
    /// Master opt-in. Default **false** — the feature does not exist in the UI while this is off.
    var masterEnabled = false
    /// Include nutrition data (meals, totals, goals) in the coach's context packet and tools.
    var shareWithCoach = true
    /// Mention nutrition in daily check-in notifications (only when `shareWithCoach` is also on).
    var includeInNotifications = true
    /// Allow sending meal photos to the configured LLM provider for analysis.
    var photoAnalysisEnabled = true
    /// Show the nutrition tile on the Today dashboard and in the widget snapshot.
    var showOnToday = true

    static let `default` = NutritionPrefs()

    init() {}

    /// Tolerant decode: any missing key falls back to its default, so a stored blob written by an
    /// older build (lacking a newer key) is never discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NutritionPrefs.default
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? d.masterEnabled
        shareWithCoach = try c.decodeIfPresent(Bool.self, forKey: .shareWithCoach) ?? d.shareWithCoach
        includeInNotifications = try c.decodeIfPresent(Bool.self, forKey: .includeInNotifications) ?? d.includeInNotifications
        photoAnalysisEnabled = try c.decodeIfPresent(Bool.self, forKey: .photoAnalysisEnabled) ?? d.photoAnalysisEnabled
        showOnToday = try c.decodeIfPresent(Bool.self, forKey: .showOnToday) ?? d.showOnToday
    }
}

/// Observable, `UserDefaults`-backed store for nutrition preferences.
/// Follows the `AppleHealthPrefsStore` pattern; persists on `didSet`, reads at use-time.
@MainActor
@Observable
final class NutritionPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = NutritionPrefsStore()

    private static let prefsKey = "pulseloop.nutrition.prefs.v1"
    private let defaults: UserDefaults

    var prefs: NutritionPrefs {
        didSet { persist(prefs, forKey: Self.prefsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = Self.load(NutritionPrefs.self, forKey: Self.prefsKey, from: defaults) ?? .default
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
