import Foundation
import CoreLocation

/// GPS accuracy/battery tradeoff for workout route recording.
enum GpsAccuracy: String, Codable, CaseIterable, Identifiable, Sendable {
    case best       // kCLLocationAccuracyBest — most precise, most battery
    case balanced   // ~10 m
    case economic   // ~100 m

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .economic: return "Economic"
        }
    }

    var blurb: String {
        switch self {
        case .best: return "Most precise route, highest battery use"
        case .balanced: return "Good accuracy, less battery"
        case .economic: return "Coarse route, lowest battery"
        }
    }

    var clValue: CLLocationAccuracy {
        switch self {
        case .best: return kCLLocationAccuracyBest
        case .balanced: return kCLLocationAccuracyNearestTenMeters
        case .economic: return kCLLocationAccuracyHundredMeters
        }
    }
}

/// User-tunable activity-recording preferences (which sensors to capture during a workout, their poll
/// cadence, and GPS defaults), persisted as JSON in `UserDefaults`. Mirrors the `MetricPrefsStore`
/// pattern — no SwiftData, no migration. Read at use-time by the recording services so changes apply to
/// the next workout / next poll.
struct WorkoutPrefs: Codable, Equatable {
    var captureHeartRate = true
    var captureSpO2 = true
    /// Workout HR poll cadence (seconds). App-driven one-shot reads — independent of the all-day ring
    /// interval (`0x16`), since the ring's per-workout cadence isn't reliably honored.
    var hrPollIntervalSeconds = 60          // 15 / 30 / 60 / 90 / 120
    var spo2PollIntervalSeconds = 300       // 120 / 300 / 600
    var useGpsByDefault = true
    var gpsAccuracy: GpsAccuracy = .best
    /// Personalized Keytel-HR / MET calorie model (`WorkoutMetricsEngine`). Off falls back to a flat
    /// 8 kcal/min estimate. Default on — main ships the advanced model as the only behavior.
    var useAdvancedCalories = true

    static let `default` = WorkoutPrefs()

    init() {}

    /// Tolerant decode: missing keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkoutPrefs.default
        captureHeartRate = try c.decodeIfPresent(Bool.self, forKey: .captureHeartRate) ?? d.captureHeartRate
        captureSpO2 = try c.decodeIfPresent(Bool.self, forKey: .captureSpO2) ?? d.captureSpO2
        hrPollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .hrPollIntervalSeconds) ?? d.hrPollIntervalSeconds
        spo2PollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .spo2PollIntervalSeconds) ?? d.spo2PollIntervalSeconds
        useGpsByDefault = try c.decodeIfPresent(Bool.self, forKey: .useGpsByDefault) ?? d.useGpsByDefault
        gpsAccuracy = try c.decodeIfPresent(GpsAccuracy.self, forKey: .gpsAccuracy) ?? d.gpsAccuracy
        useAdvancedCalories = try c.decodeIfPresent(Bool.self, forKey: .useAdvancedCalories) ?? d.useAdvancedCalories
    }
}

/// Observable, UserDefaults-backed store for `WorkoutPrefs`. Mutating `settings` persists immediately.
@MainActor
@Observable
final class WorkoutPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = WorkoutPrefsStore()

    private static let storageKey = "pulseloop.workoutprefs.v1"
    private let defaults: UserDefaults

    var settings: WorkoutPrefs {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(WorkoutPrefs.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
