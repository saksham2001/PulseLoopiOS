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
        var status: String            // "recording" | "paused" | "finished"
        var elapsedSeconds: Int       // final duration when finished; otherwise the widget self-counts from startDate
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
        /// Whether to render distance/pace in imperial (mi, /mi). Mirrors the user's
        /// units preference; kept as a plain Bool because this shared type can't see
        /// the app-only `UnitsPreference`. Defaults to metric for older payloads.
        var useImperial: Bool = false
        /// Session average HR, shown on the final "Workout complete" card. Nil while recording
        /// (and for payloads from older app versions).
        var avgHeartRate: Int? = nil
    }

    var sessionID: String
    var activityName: String
}

extension WorkoutActivityAttributes.ContentState {
    private enum CodingKeys: String, CodingKey {
        case status
        case elapsedSeconds
        case startDate
        case pausedAt
        case usesGps
        case distanceMeters
        case paceSecondsPerKm
        case lastHeartRate
        case lastSpO2
        case activityType
        case lastUpdated
        case useImperial
        case avgHeartRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        elapsedSeconds = try container.decode(Int.self, forKey: .elapsedSeconds)
        startDate = try container.decode(Date.self, forKey: .startDate)
        pausedAt = try container.decodeIfPresent(Date.self, forKey: .pausedAt)
        usesGps = try container.decode(Bool.self, forKey: .usesGps)
        distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
        paceSecondsPerKm = try container.decodeIfPresent(Double.self, forKey: .paceSecondsPerKm)
        lastHeartRate = try container.decodeIfPresent(Int.self, forKey: .lastHeartRate)
        lastSpO2 = try container.decodeIfPresent(Int.self, forKey: .lastSpO2)
        activityType = try container.decode(String.self, forKey: .activityType)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        useImperial = try container.decodeIfPresent(Bool.self, forKey: .useImperial) ?? false
        avgHeartRate = try container.decodeIfPresent(Int.self, forKey: .avgHeartRate)
    }
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
        case "dance", "dancing":        return "figure.dance"
        case "squash", "tennis":        return "figure.tennis"
        case "sport", "soccer", "football": return "figure.soccer"
        default:                        return "sparkles"
        }
    }

    static func paceLabel(_ secPerKm: Double?, imperial: Bool = false) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let secPerUnit = imperial ? secPerKm * 1.609344 : secPerKm
        let total = Int(secPerUnit.rounded())
        return String(format: "%d:%02d %@", total / 60, total % 60, imperial ? "/mi" : "/km")
    }

    static func distanceLabel(_ meters: Double, imperial: Bool = false) -> String {
        guard meters >= 50 else { return "—" }
        return imperial
            ? String(format: "%.2f mi", meters / 1609.344)
            : String(format: "%.2f km", meters / 1000)
    }
}
