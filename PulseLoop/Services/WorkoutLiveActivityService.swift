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

    // MARK: - Re-attach (app relaunch)

    /// Rebuild the in-memory activity map from the system's live activities. The OS keeps a Live
    /// Activity alive across app relaunches, but this dict is populated only by `start()` — without
    /// re-attaching, every later `update`/`end` silently no-ops and the Lock Screen card freezes
    /// (and its self-counting timer runs for up to 48 h). Activities whose session is no longer
    /// active are orphans and are ended immediately.
    func reattach(activeSessionIDs: Set<String>) {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            let sid = activity.attributes.sessionID
            if activeSessionIDs.contains(sid) {
                activities[sid] = activity
            } else {
                liveActivityLog.info("Ending orphaned Live Activity for session \(sid, privacy: .public)")
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

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

    /// Ends the Live Activity for the session, then forgets it. With a `finalState` (finished
    /// workout) the Lock Screen keeps a "Workout complete" card for ~10 minutes before
    /// auto-dismissing; without one (discard/cancel) it disappears immediately.
    func end(sessionID: String, finalState: WorkoutActivityAttributes.ContentState? = nil) {
        guard let activity = activities.removeValue(forKey: sessionID) else { return }
        Task {
            if let finalState {
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .after(.now + 10 * 60)
                )
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
