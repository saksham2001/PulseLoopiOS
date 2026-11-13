import Foundation

/// How the circadian tile decides which optional events to show.
enum CircadianSelectionMode: String, Codable, CaseIterable {
    /// The app includes an event only when it is logged often enough to be a habit.
    case smart
    /// The user's own choices, regardless of how often the event is logged.
    case manual
}

/// User-tunable circadian-tile preferences, persisted as JSON in `UserDefaults`.
///
/// Unlike nutrition, the tile is **on by default**: it only reads data the app already has.
/// Mirrors the `NutritionPrefsStore` pattern — no SwiftData, no migration — with tolerant decode
/// so adding a future key never wipes an existing user's blob.
struct CircadianPrefs: Codable, Equatable {
    /// Show the circadian tile on the Sleep page.
    var enabled = true
    /// Put meals on the dial (still requires nutrition tracking to be on).
    var showMeals = true
    var mealSelection: CircadianSelectionMode = .smart
    // Which meals to show when `mealSelection` is `.manual`.
    var showBreakfast = true
    var showLunch = true
    var showDinner = true
    /// Put workouts on the dial.
    var showWorkouts = true
    /// `.smart` shows workouts only when they are a regular habit; `.manual` always shows them.
    var workoutSelection: CircadianSelectionMode = .smart

    static let `default` = CircadianPrefs()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CircadianPrefs.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        showMeals = try c.decodeIfPresent(Bool.self, forKey: .showMeals) ?? d.showMeals
        mealSelection = try c.decodeIfPresent(CircadianSelectionMode.self, forKey: .mealSelection) ?? d.mealSelection
        showBreakfast = try c.decodeIfPresent(Bool.self, forKey: .showBreakfast) ?? d.showBreakfast
        showLunch = try c.decodeIfPresent(Bool.self, forKey: .showLunch) ?? d.showLunch
        showDinner = try c.decodeIfPresent(Bool.self, forKey: .showDinner) ?? d.showDinner
        showWorkouts = try c.decodeIfPresent(Bool.self, forKey: .showWorkouts) ?? d.showWorkouts
        workoutSelection = try c.decodeIfPresent(CircadianSelectionMode.self, forKey: .workoutSelection) ?? d.workoutSelection
    }

    /// The manual per-meal choice for a meal anchor.
    func includesMeal(_ kind: CircadianAnchorKind) -> Bool {
        switch kind {
        case .breakfast: return showBreakfast
        case .lunch: return showLunch
        case .dinner: return showDinner
        case .wake, .bed: return false
        }
    }
}

/// Observable, `UserDefaults`-backed store for circadian preferences.
/// Follows the `NutritionPrefsStore` pattern; persists on `didSet`, reads at use-time.
@MainActor
@Observable
final class CircadianPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = CircadianPrefsStore()

    private static let prefsKey = "pulseloop.circadian.prefs.v1"
    private let defaults: UserDefaults

    var prefs: CircadianPrefs {
        didSet { persist(prefs) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.prefsKey),
           let stored = try? JSONDecoder().decode(CircadianPrefs.self, from: data) {
            self.prefs = stored
        } else {
            self.prefs = .default
        }
    }

    private func persist(_ value: CircadianPrefs) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.prefsKey)
    }
}
