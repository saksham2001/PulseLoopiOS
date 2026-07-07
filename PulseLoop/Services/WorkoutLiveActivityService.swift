//
//  WorkoutLiveActivityService.swift
//  PulseLoop
//
//  App-side controller for the workout Live Activity. Wraps
//  Activity<WorkoutActivityAttributes>. Every ActivityKit call is guarded so a
//  failure never throws to the caller (Live Activities are a non-fatal nicety).
//

import Foundation
import Combine
import ActivityKit
import os.log

private let liveActivityLog = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "LiveActivity")

struct WorkoutLiveActivityDisplayOptions {
    let usesGps: Bool
    let useImperial: Bool
}

@MainActor
final class WorkoutLiveActivityService: ObservableObject {

    private var activities: [String: Activity<WorkoutActivityAttributes>] = [:]

    // MARK: - Start

    /// Starts a Live Activity for the given session. Returns the activity id, or
    /// nil if Live Activities are unavailable / the request failed.
    @discardableResult
    func start(sessionID: String, activityName: String, activityType: String,
               startDate: Date, displayOptions: WorkoutLiveActivityDisplayOptions) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityLog.error("Live Activities not enabled (toggle off in Settings → PulseLoop → Live Activities, or unsupported). Skipping start.")
            return nil
        }

        let attributes = WorkoutActivityAttributes(sessionID: sessionID,
                                                   activityName: activityName)
        let initialState = WorkoutActivityAttributes.ContentState(
            status: "recording",
            elapsedSeconds: 0,
            startDate: startDate,
            pausedAt: nil,
            usesGps: displayOptions.usesGps,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            lastHeartRate: nil,
            lastSpO2: nil,
            activityType: activityType,
            lastUpdated: Date(),
            useImperial: displayOptions.useImperial
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil)
            )
            activities[sessionID] = activity
            return activity.id
        } catch {
            liveActivityLog.error("Activity.request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Update

    /// Pushes a new ContentState to the Live Activity for the session. Non-async:
    /// the actual `await` is dispatched onto a Task. Throttling is the caller's job.
    func update(sessionID: String, state: WorkoutActivityAttributes.ContentState) {
        guard let activity = activities[sessionID] else { return }

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    // MARK: - End

    /// Ends and dismisses the Live Activity for the session, then forgets it.
    func end(sessionID: String) {
        guard let activity = activities.removeValue(forKey: sessionID) else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
