//
//  WorkoutActivityAttributes.swift
//  PulseLoop
//
//  Shared types for the workout Live Activity. Must compile in BOTH the app
//  target (PulseLoop) and the widget extension target
//  (PulseLoopLiveActivityExtension). Reference only Foundation / ActivityKit /
//  AppIntents / SwiftUI here — no app-only types.
//

import Foundation
import ActivityKit
import AppIntents
import SwiftUI

// MARK: - Activity Attributes

struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String            // "recording" | "paused"
        var elapsedSeconds: Int       // non-live fallback only; the widget self-counts from startDate
        /// Effective timer origin = startedAt + totalPauseSeconds, so `now - startDate` is the
        /// elapsed time excluding pauses. Drives the widget's self-counting `Text(timerInterval:)`.
        var startDate: Date
        /// When paused, the instant to freeze the timer at; nil while recording.
        var pausedAt: Date?
        /// Whether this activity records GPS — drives whether Distance/Pace fields are shown.
        var usesGps: Bool
        var distanceMeters: Double
        var paceSecondsPerKm: Double?
        var lastHeartRate: Int?
        var lastSpO2: Int?
        var activityType: String      // "run","walk","cycle",...
        var lastUpdated: Date
    }

    var sessionID: String
    var activityName: String
}

// MARK: - App Group command channel

/// The widget control buttons write commands here; the app reads & clears them.
/// `nonisolated` so the App Intents' nonisolated `perform()` can call it under Swift 6
/// (this target defaults to MainActor isolation).
nonisolated enum WorkoutAppGroup {
    static let suite = "group.xyz.sakshambhutani.pulseloop2"
    static let commandKey = "pendingWorkoutCommand"          // "pause" | "resume" | "finish"
    static let commandSessionKey = "pendingWorkoutCommandSession"
    static let commandTimeKey = "pendingWorkoutCommandTime"  // Date for de-dupe

    /// Mirror of the user's units preference (canonical source is `UserProfile.units`). Kept in the
    /// app group so the Live Activity widget extension — which can't read SwiftData — can format
    /// distance/pace, and so model-layer helpers have a cheap synchronous read. Written by the app
    /// whenever the profile's units change (see `ProfileSettingsView.save`).
    static var useImperialUnits: Bool {
        get { UserDefaults(suiteName: suite)?.bool(forKey: "useImperialUnits") ?? false }
        set { UserDefaults(suiteName: suite)?.set(newValue, forKey: "useImperialUnits") }
    }

    static func post(_ command: String, sessionID: String) {
        guard let d = UserDefaults(suiteName: suite) else { return }
        d.set(command, forKey: commandKey)
        d.set(sessionID, forKey: commandSessionKey)
        d.set(Date(), forKey: commandTimeKey)
    }
}

// MARK: - Live Activity Intents (run in the app process)

struct PauseWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause Workout"

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        WorkoutAppGroup.post("pause", sessionID: sessionID)
        return .result()
    }
}

struct ResumeWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Workout"

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        WorkoutAppGroup.post("resume", sessionID: sessionID)
        return .result()
    }
}

struct FinishWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish Workout"

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        WorkoutAppGroup.post("finish", sessionID: sessionID)
        return .result()
    }
}

// MARK: - Shared palette + helpers for the widget

enum WorkoutLAColors {
    // #7C5CFF
    static let accent = Color(.sRGB, red: 0.486, green: 0.361, blue: 1.0, opacity: 1)
    // #FF4D6D
    static let heartRate = Color(.sRGB, red: 1.0, green: 0.302, blue: 0.427, opacity: 1)
    // #4DDCFF
    static let spo2 = Color(.sRGB, red: 0.302, green: 0.863, blue: 1.0, opacity: 1)
    // #4DA3FF
    static let distance = Color(.sRGB, red: 0.302, green: 0.639, blue: 1.0, opacity: 1)
    // #6F7A8C
    static let textMuted = Color(.sRGB, red: 0.435, green: 0.478, blue: 0.549, opacity: 1)
    // #080A0F
    static let background = Color(.sRGB, red: 0.031, green: 0.039, blue: 0.059, opacity: 1)

    static func icon(for activityType: String) -> String {
        switch activityType.lowercased() {
        case "run", "running":          return "figure.run"
        case "walk", "walking":         return "figure.walk"
        case "cycle", "cycling", "bike": return "figure.outdoor.cycle"
        case "gym", "strength", "weights": return "dumbbell.fill"
        case "hike", "hiking":          return "figure.hiking"
        case "yoga":                    return "figure.yoga"
        case "squash", "tennis":        return "figure.tennis"
        case "sport", "soccer", "football": return "figure.soccer"
        default:                        return "sparkles"
        }
    }

    static func paceLabel(_ secPerKm: Double?) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let isImperial = WorkoutAppGroup.useImperialUnits
        let factor = isImperial ? 1.60934 : 1.0
        let secPerUnit = secPerKm * factor
        let total = Int(secPerUnit.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d /%@", minutes, seconds, isImperial ? "mi" : "km")
    }

    static func distanceLabel(_ meters: Double) -> String {
        guard meters >= 50 else { return "—" }
        let isImperial = WorkoutAppGroup.useImperialUnits
        let divisor = isImperial ? 1609.34 : 1000.0
        return String(format: "%.2f %@", meters / divisor, isImperial ? "mi" : "km")
    }
}
