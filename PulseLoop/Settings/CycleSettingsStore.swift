import Foundation

/// User-tunable cycle-tracking configuration, persisted as JSON in `UserDefaults` (same
/// pattern as `CoachSettings`). The health facts themselves live in SwiftData (`CycleDay`);
/// this is only preferences.
struct CycleSettings: Codable, Equatable {
    /// Master switch. Off by default — the feature is invisible until the user opts in and
    /// accepts the disclaimer.
    var enabled: Bool = false
    var goal: CycleGoal = .understand
    /// Hormonal contraception suppresses ovulation, so the thermal analysis is meaningless —
    /// period logging stays available but shift detection and predictions are hidden.
    var onHormonalContraception: Bool = false
    /// Explicit opt-in before any cycle data is included in the AI coach context. Off by
    /// default and deliberately separate from the coach's own toggles: menstrual data must
    /// never leave the device as a side effect of enabling something else.
    var shareWithCoach: Bool = false
    /// "Your period is due today — has it started?" local notification with a one-tap log action.
    var periodPromptEnabled: Bool = true
    /// Optional heads-up two days before the predicted period.
    var preAlertEnabled: Bool = false
    /// When the user accepted the not-a-medical-device disclaimer; `nil` = never accepted,
    /// so the feature cannot be on.
    var disclaimerAcceptedAt: Date?

    static let `default` = CycleSettings()

    init() {}

    /// Tolerant decode: missing keys (older stored settings, new fields) fall back to
    /// defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CycleSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        goal = try c.decodeIfPresent(CycleGoal.self, forKey: .goal) ?? d.goal
        onHormonalContraception = try c.decodeIfPresent(Bool.self, forKey: .onHormonalContraception) ?? d.onHormonalContraception
        shareWithCoach = try c.decodeIfPresent(Bool.self, forKey: .shareWithCoach) ?? d.shareWithCoach
        periodPromptEnabled = try c.decodeIfPresent(Bool.self, forKey: .periodPromptEnabled) ?? d.periodPromptEnabled
        preAlertEnabled = try c.decodeIfPresent(Bool.self, forKey: .preAlertEnabled) ?? d.preAlertEnabled
        disclaimerAcceptedAt = try c.decodeIfPresent(Date.self, forKey: .disclaimerAcceptedAt)
    }
}

/// Observable, UserDefaults-backed store for `CycleSettings`. Mutating `settings` persists
/// immediately. A shared instance keeps Settings, the Vitals card, and notifications in sync.
@MainActor
@Observable
final class CycleSettingsStore {
    static let shared = CycleSettingsStore()

    private static let storageKey = "pulseloop.cycle.settings.v1"
    private let defaults: UserDefaults

    var settings: CycleSettings {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(CycleSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    /// The feature is only active with both the switch on and the disclaimer accepted.
    var isActive: Bool { settings.enabled && settings.disclaimerAcceptedAt != nil }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
