import Foundation

/// User-tunable readiness preferences, persisted as JSON in `UserDefaults`.
///
/// Unlike `NutritionPrefs`, `masterEnabled` defaults to **true**. Nutrition defaults off because it
/// is manual data entry that can ship meal photos to a third-party LLM — a genuinely new privacy
/// surface. Readiness is derived entirely from data the ring already collects locally: it adds no
/// permission, no network egress, and stores nothing the user didn't already have. It is also
/// self-gating, since the tile can't appear without HRV-or-sleep capability and can't score until
/// personal baselines establish, so defaulting it on can't produce a misleading empty tile.
///
/// Mirrors the `NutritionPrefsStore` pattern — no SwiftData, no migration — with tolerant decode so
/// adding a future key never wipes an existing user's blob.
struct ReadinessPrefs: Codable, Equatable {
    /// Master opt-in. While off there is no tile, no coach context, and no computation.
    var masterEnabled = true
    /// Show the readiness tile on the Today dashboard and in the widget snapshot.
    var showOnToday = true
    /// Include the score and its contributor breakdown in the coach's context packet and tools.
    var shareWithCoach = true
    /// Mention readiness in daily check-in notifications (only when `shareWithCoach` is also on).
    var includeInNotifications = true

    static let `default` = ReadinessPrefs()

    init() {}

    /// Tolerant decode: any missing key falls back to its default, so a stored blob written by an
    /// older build (lacking a newer key) is never discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReadinessPrefs.default
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? d.masterEnabled
        showOnToday = try c.decodeIfPresent(Bool.self, forKey: .showOnToday) ?? d.showOnToday
        shareWithCoach = try c.decodeIfPresent(Bool.self, forKey: .shareWithCoach) ?? d.shareWithCoach
        includeInNotifications = try c.decodeIfPresent(Bool.self, forKey: .includeInNotifications) ?? d.includeInNotifications
    }
}

/// Observable, `UserDefaults`-backed store for readiness preferences.
/// Follows the `NutritionPrefsStore` pattern; persists on `didSet`, reads at use-time.
@MainActor
@Observable
final class ReadinessPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = ReadinessPrefsStore()

    static let prefsKey = "pulseloop.readiness.prefs.v1"
    private let defaults: UserDefaults

    var prefs: ReadinessPrefs {
        didSet { persist(prefs, forKey: Self.prefsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = Self.load(ReadinessPrefs.self, forKey: Self.prefsKey, from: defaults) ?? .default
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
