import Foundation

/// How the user chose to seed Apple Health the first time they enabled sync.
///
/// Asked once, on first master-toggle enable:
/// - `.notAsked` — the dialog hasn't been shown yet (initial state).
/// - `.fullHistory` — export everything the ring has ever recorded (watermarks cleared).
/// - `.newDataOnly` — only export data recorded from the enable moment forward (watermarks stamped to now).
enum HealthBackfillChoice: String, Codable {
    case notAsked
    case fullHistory
    case newDataOnly
}

/// User-tunable Apple Health export preferences, persisted as JSON in `UserDefaults`.
///
/// Privacy-first: `masterEnabled` defaults to **false** — the app never writes to Apple Health until the
/// user explicitly opts in from the Apple Health settings screen. Once the master toggle is on, the six
/// per-type toggles and the workout-export toggle each default **on**, so a single tap starts a complete
/// export; the user can then narrow it. Mirrors the `WorkoutPrefsStore` pattern — no SwiftData, no
/// migration — with tolerant decode so adding a future key never wipes an existing user's blob.
struct AppleHealthPrefs: Codable, Equatable {
    /// Master opt-in. Default **false** — no Health writes happen while this is off.
    var masterEnabled = false
    var syncHeartRate = true
    var syncSpO2 = true
    var syncHRV = true
    var syncTemperature = true
    var syncSleep = true
    var syncActivity = true
    /// Whether finished workout sessions export as `HKWorkout`s (calories, distance, HR stats, GPS route).
    var exportWorkouts = true
    /// Backfill decision captured on first enable. Default `.notAsked`.
    var backfillChoice: HealthBackfillChoice = .notAsked

    static let `default` = AppleHealthPrefs()

    init() {}

    /// Tolerant decode: any missing key falls back to its default, so a stored blob written by an older
    /// build (lacking a newer key) is never discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppleHealthPrefs.default
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? d.masterEnabled
        syncHeartRate = try c.decodeIfPresent(Bool.self, forKey: .syncHeartRate) ?? d.syncHeartRate
        syncSpO2 = try c.decodeIfPresent(Bool.self, forKey: .syncSpO2) ?? d.syncSpO2
        syncHRV = try c.decodeIfPresent(Bool.self, forKey: .syncHRV) ?? d.syncHRV
        syncTemperature = try c.decodeIfPresent(Bool.self, forKey: .syncTemperature) ?? d.syncTemperature
        syncSleep = try c.decodeIfPresent(Bool.self, forKey: .syncSleep) ?? d.syncSleep
        syncActivity = try c.decodeIfPresent(Bool.self, forKey: .syncActivity) ?? d.syncActivity
        exportWorkouts = try c.decodeIfPresent(Bool.self, forKey: .exportWorkouts) ?? d.exportWorkouts
        backfillChoice = try c.decodeIfPresent(HealthBackfillChoice.self, forKey: .backfillChoice) ?? d.backfillChoice
    }
}

/// Export progress, tracked entirely in the prefs store so no SwiftData model or schema ever changes.
///
/// Export state is a set of **watermark dates**: each pass only writes rows newer than its watermark, then
/// advances the watermark. This makes exports incremental and interrupt-safe (a killed backfill resumes
/// from the last saved watermark), and — combined with `HKMetadataKeySyncIdentifier` upserts on the write
/// side — makes re-running an export harmless (overlapping rows replace rather than duplicate).
///
/// Watermark fields deliberately track different timestamps:
/// - `measurementWatermarks` is keyed by `MeasurementKind.rawValue` on **`Measurement.createdAt`** (not the
///   sample's own timestamp) because history rows arrive late carrying old measurement times; watermarking
///   on `createdAt` guarantees late-arriving history is still picked up. Each kind advances independently,
///   so disabling one type freezes its watermark and re-enabling backfills exactly the gap.
/// - `activityExportedThrough` / `sleepExportedThrough` / `workoutsExportedThrough` track **`updatedAt`** on
///   `ActivityDaily` / `SleepSession` / `ActivitySession`, so an edited day/session re-exports and replaces.
struct AppleHealthSyncState: Codable, Equatable {
    /// Per-`MeasurementKind` (rawValue) high-water mark on `Measurement.createdAt`.
    var measurementWatermarks: [String: Date] = [:]
    /// High-water mark on `ActivityDaily.updatedAt`.
    var activityExportedThrough: Date?
    /// High-water mark on `SleepSession.updatedAt`.
    var sleepExportedThrough: Date?
    /// High-water mark on `ActivitySession.updatedAt`.
    var workoutsExportedThrough: Date?
    var lastSyncAt: Date?
    var lastSyncSummary: String?

    static let `default` = AppleHealthSyncState()

    init() {}

    /// Tolerant decode: missing keys fall back to defaults so a partial/older blob survives.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppleHealthSyncState.default
        measurementWatermarks = try c.decodeIfPresent([String: Date].self, forKey: .measurementWatermarks) ?? d.measurementWatermarks
        activityExportedThrough = try c.decodeIfPresent(Date.self, forKey: .activityExportedThrough) ?? d.activityExportedThrough
        sleepExportedThrough = try c.decodeIfPresent(Date.self, forKey: .sleepExportedThrough) ?? d.sleepExportedThrough
        workoutsExportedThrough = try c.decodeIfPresent(Date.self, forKey: .workoutsExportedThrough) ?? d.workoutsExportedThrough
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt) ?? d.lastSyncAt
        lastSyncSummary = try c.decodeIfPresent(String.self, forKey: .lastSyncSummary) ?? d.lastSyncSummary
    }
}

/// Observable, `UserDefaults`-backed store for Apple Health preferences and export watermarks.
///
/// Follows the `WorkoutPrefsStore` pattern. Uses **two independent storage keys** so that frequent
/// watermark writes (every export chunk) never rewrite the user's preference blob and vice-versa:
/// - `prefs` → `"pulseloop.applehealth.prefs.v1"`
/// - `syncState` → `"pulseloop.applehealth.state.v1"`
///
/// Each property persists on `didSet`. Reads happen at use-time so a settings change applies to the next
/// export pass.
@MainActor
@Observable
final class AppleHealthPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = AppleHealthPrefsStore()

    private static let prefsKey = "pulseloop.applehealth.prefs.v1"
    private static let stateKey = "pulseloop.applehealth.state.v1"
    private let defaults: UserDefaults

    /// User-facing export preferences. Master toggle defaults **off** (privacy-first).
    var prefs: AppleHealthPrefs {
        didSet { persist(prefs, forKey: Self.prefsKey) }
    }

    /// Export watermarks and last-sync summary. Written after each export chunk.
    var syncState: AppleHealthSyncState {
        didSet { persist(syncState, forKey: Self.stateKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = Self.load(AppleHealthPrefs.self, forKey: Self.prefsKey, from: defaults) ?? .default
        self.syncState = Self.load(AppleHealthSyncState.self, forKey: Self.stateKey, from: defaults) ?? .default
    }

    /// Reset every export watermark in one shot.
    ///
    /// - Parameter date: `nil` clears all watermarks so the next export is a full-history backfill; a
    ///   concrete date (typically `Date()`) stamps all watermarks so only data newer than that instant
    ///   exports (new-data-only). Sets all four watermark slots — the per-`MeasurementKind` map and the
    ///   three `updatedAt` watermarks — atomically.
    func resetWatermarks(to date: Date?) {
        var state = syncState
        if let date {
            var marks: [String: Date] = [:]
            for kind in MeasurementKind.allCases {
                marks[kind.rawValue] = date
            }
            state.measurementWatermarks = marks
            state.activityExportedThrough = date
            state.sleepExportedThrough = date
            state.workoutsExportedThrough = date
        } else {
            state.measurementWatermarks = [:]
            state.activityExportedThrough = nil
            state.sleepExportedThrough = nil
            state.workoutsExportedThrough = nil
        }
        syncState = state
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
