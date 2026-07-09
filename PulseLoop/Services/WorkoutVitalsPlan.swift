import Foundation

/// How a workout captures vitals from the connected wearable — computed once at session start
/// (and on recovery) from the device's declared capabilities plus the user's workout prefs, then
/// handed to `LiveWorkoutManager` / `WorkoutSensorPollingService` so both act on the same plan.
///
/// The strategy is capability-driven, not device-driven: a ring with a realtime HR stream gets the
/// stream for the whole workout (dense samples, no 30 s spot warm-ups); one without falls back to
/// timer-driven spot polls. SpO2 is only spot-polled on devices that can actually take an instant
/// reading — Colmi can't, so it surfaces the ring's all-day log instead of failing reads.
struct WorkoutVitalsPlan: Equatable, Sendable {
    enum HRMode: Equatable, Sendable {
        /// Continuous live HR stream for the whole workout (jring 0x14 / Colmi 0x1e).
        case stream
        /// Timer-driven one-shot reads (legacy behaviour; devices without `.realtimeHeartRate`).
        case spotPoll
        case off
    }

    enum SpO2Mode: Equatable, Sendable {
        /// Periodic instant readings (`.manualSpo2`, jring 0x23/0x3f).
        case spotPoll
        /// No instant reading exists; show the latest all-day value and backfill from the ring
        /// log after the workout (`.spo2History`, Colmi).
        case ringLog
        case off
    }

    var hrMode: HRMode
    var spo2Mode: SpO2Mode
    /// Bump the ring's all-day HR log to its densest interval for the workout (Colmi 0x16, 5-min
    /// floor) so the on-ring log backfills any stream gaps; the user's configured interval is
    /// restored at finish.
    var bumpRingInterval: Bool

    /// Legacy behaviour for devices with no stamped capabilities (never-connected row).
    static let spotFallback = WorkoutVitalsPlan(hrMode: .spotPoll, spo2Mode: .spotPoll, bumpRingInterval: false)

    /// Persisted on `ActivitySession.vitalsModeRaw` for the recording-quality report.
    var vitalsModeRaw: String { hrMode == .stream ? "stream" : "spot" }

    static func plan(for capabilities: Set<WearableCapability>, prefs: WorkoutPrefs) -> WorkoutVitalsPlan {
        guard !capabilities.isEmpty else { return .spotFallback }
        let hr: HRMode = !prefs.captureHeartRate ? .off
            : capabilities.contains(.realtimeHeartRate) ? .stream
            : .spotPoll
        let spo2: SpO2Mode = !prefs.captureSpO2 ? .off
            : capabilities.contains(.manualSpo2) ? .spotPoll
            : capabilities.contains(.spo2History) ? .ringLog
            : .off
        return WorkoutVitalsPlan(
            hrMode: hr,
            spo2Mode: spo2,
            // Only tighten the ring's HR log when HR capture is actually on.
            bumpRingInterval: hr != .off && capabilities.contains(.measurementInterval)
        )
    }
}
