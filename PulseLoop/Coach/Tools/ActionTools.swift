import Foundation
import SwiftData

/// Write/action tools (gated by `enableWriteTools`) and live measurement (gated
/// by `enableLiveMeasurements`). Low-risk writes apply immediately; risky ones
/// (delete, or editing a past session) return `needs_confirmation` and queue a
/// `PendingAction` rendered as a Confirm/Cancel card.
@MainActor
enum ActionTools {
    static var writeTools: [AnyCoachTool] {
        [setGoal, logUserNote, logActivityCorrection, createActivitySession, updateActivitySession, deleteActivitySession]
    }
    static var measurementTools: [AnyCoachTool] { [triggerMeasurement] }

    private static let activityEnum = ["walk", "run", "cycle", "gym", "squash", "sport", "yoga", "dance", "hike", "other"]

    // MARK: set_goal

    private struct SetGoalArgs: Decodable {
        let goalType: String, target: Double, reason: String
        enum CodingKeys: String, CodingKey { case goalType = "goal_type", target, reason }
    }

    private static var setGoal: AnyCoachTool {
        .make(
            name: "set_goal",
            label: "Saving your goal",
            description: "Create or update a daily/weekly fitness goal.",
            parameters: JSONSchema.object([
                "goal_type": JSONSchema.enumString(["steps", "sleep_hours", "active_minutes", "exercise_days"]),
                "target": JSONSchema.number,
                "reason": JSONSchema.string,
            ], required: ["goal_type", "target", "reason"]),
            argsType: SetGoalArgs.self
        ) { args, ctx in
            let goal = MetricsRepository.goals(context: ctx.modelContext) ?? {
                let g = UserGoal(); ctx.modelContext.insert(g); return g
            }()
            switch args.goalType {
            case "steps": goal.steps = Int(args.target)
            case "sleep_hours": goal.sleepMinutes = Int(args.target * 60)
            case "active_minutes": goal.activeMinutes = Int(args.target)
            case "exercise_days": goal.workoutsPerWeek = Int(args.target)
            default: return .error("invalid goal_type '\(args.goalType)'")
            }
            goal.updatedAt = Date()
            try? ctx.modelContext.save()
            return .object(["ok": true, "goal_type": args.goalType, "target": args.target])
        }
    }

    // MARK: log_user_note

    private struct NoteArgs: Decodable {
        let date: String, noteType: String, content: String
        enum CodingKeys: String, CodingKey { case date, noteType = "note_type", content }
    }

    private static var logUserNote: AnyCoachTool {
        .make(
            name: "log_user_note",
            label: "Noting that down",
            description: "Save a dated note about symptoms, perceived exertion, mood, injury, sleep, diet, or activity context.",
            parameters: JSONSchema.object([
                "date": JSONSchema.string,
                "note_type": JSONSchema.enumString(["symptom", "injury", "activity_context", "sleep_context", "diet_context", "mood", "general"]),
                "content": JSONSchema.string,
            ], required: ["date", "note_type", "content"]),
            argsType: NoteArgs.self
        ) { args, ctx in
            let mem = MemoryTools.save(
                context: ctx.modelContext, memoryType: "health_note",
                key: "\(args.noteType) · \(args.date)", value: args.content, importance: 2
            )
            return .object(["ok": true, "note_id": mem.id.uuidString, "note_type": args.noteType])
        }
    }

    // MARK: log_activity_correction

    private struct CorrectionArgs: Decodable {
        let date: String, activityType: String
        let durationMin: Double?, distanceKm: Double?, intensity: String?, notes: String
        enum CodingKeys: String, CodingKey {
            case date, activityType = "activity_type", durationMin = "duration_min"
            case distanceKm = "distance_km", intensity, notes
        }
    }

    private static var logActivityCorrection: AnyCoachTool {
        .make(
            name: "log_activity_correction",
            label: "Logging your activity",
            description: "Log or correct a user-stated activity the ring missed or misclassified. Stored as a durable note; never mutates ring rollups.",
            parameters: JSONSchema.object([
                "date": JSONSchema.string,
                "activity_type": JSONSchema.enumString(activityEnum),
                "duration_min": ["type": ["number", "null"]],
                "distance_km": ["type": ["number", "null"]],
                "intensity": ["type": ["string", "null"], "enum": ["easy", "moderate", "hard", NSNull()]],
                "notes": JSONSchema.string,
            ], required: ["date", "activity_type", "duration_min", "distance_km", "intensity", "notes"]),
            argsType: CorrectionArgs.self
        ) { args, ctx in
            var summary = "\(args.activityType) on \(args.date)"
            if let d = args.durationMin { summary += ", \(Int(d)) min" }
            if let km = args.distanceKm { summary += ", \(km) km" }
            if let i = args.intensity { summary += " (\(i))" }
            let mem = MemoryTools.save(
                context: ctx.modelContext, memoryType: "manual_correction",
                key: "Ring-missed: \(summary)", value: args.notes, importance: 3
            )
            return .object(["ok": true, "correction_id": mem.id.uuidString, "logged": summary])
        }
    }

    // MARK: create_activity_session_from_description

    private struct CreateArgs: Decodable {
        let activityType: String, date: String, startTime: String?
        let durationMin: Double?, distanceKm: Double?, notes: String, confidence: String
        enum CodingKeys: String, CodingKey {
            case activityType = "activity_type", date, startTime = "start_time"
            case durationMin = "duration_min", distanceKm = "distance_km", notes, confidence
        }
    }

    private static var createActivitySession: AnyCoachTool {
        .make(
            name: "create_activity_session_from_description",
            label: "Logging your session",
            description: "Create a finished manual workout from a description. If activity_type and date are known but duration is missing, returns needs_follow_up — ask how long, then call again.",
            parameters: JSONSchema.object([
                "activity_type": JSONSchema.enumString(activityEnum),
                "date": JSONSchema.string,
                "start_time": ["type": ["string", "null"]],
                "duration_min": ["type": ["number", "null"]],
                "distance_km": ["type": ["number", "null"]],
                "notes": JSONSchema.string,
                "confidence": JSONSchema.enumString(["low", "medium", "high"]),
            ], required: ["activity_type", "date", "start_time", "duration_min", "distance_km", "notes", "confidence"]),
            argsType: CreateArgs.self
        ) { args, ctx in
            guard let duration = args.durationMin else {
                return .object(["ok": false, "needs_follow_up": true, "reason": "duration_missing",
                                "suggested_question": "Roughly how long was the \(args.activityType) session?"])
            }
            let now = Date()
            var start: Date = args.startTime.flatMap(CoachDataAccess.parseLocalDate)
                ?? CoachDataAccess.parseLocalDate(args.date).map { $0.addingTimeInterval(12 * 3600) }
                ?? now
            // The same-day noon default can land in the future (logging "today"
            // in the morning) and ManualActivityService rejects future sessions;
            // pull an unspecified start back so the session ends by now.
            if args.startTime == nil, start.addingTimeInterval(duration * 60) > now {
                start = now.addingTimeInterval(-duration * 60)
            }
            let session: ActivitySession
            do {
                session = try ManualActivityService.create(
                    type: args.activityType,
                    startedAt: start,
                    durationMinutes: duration,
                    distanceMeters: args.distanceKm.map { $0 * 1000 },
                    notes: args.notes,
                    context: ctx.modelContext
                )
            } catch {
                return .error(error.localizedDescription)
            }
            ctx.loggedActivityIds.append(session.id)
            return .object(["ok": true, "created": true, "activity_id": session.id.uuidString,
                            "type": args.activityType, "duration_min": duration])
        }
    }

    // MARK: update_activity_session

    private struct UpdateArgs: Decodable {
        let activityId: String
        let type: String?, notes: String?, distanceKm: Double?, durationMin: Double?
        let perceivedEffort: String?, startTime: String?, reason: String
        enum CodingKeys: String, CodingKey {
            case activityId = "activity_id", type, notes, distanceKm = "distance_km"
            case durationMin = "duration_min", perceivedEffort = "perceived_effort", startTime = "start_time", reason
        }
    }

    private static var updateActivitySession: AnyCoachTool {
        .make(
            name: "update_activity_session",
            label: "Updating that workout",
            description: "Edit a saved workout. Applies immediately for today's session; for an older session, returns needs_confirmation and shows a Confirm card.",
            parameters: JSONSchema.object([
                "activity_id": JSONSchema.string,
                "type": ["type": ["string", "null"], "enum": activityEnum + [NSNull()]],
                "notes": ["type": ["string", "null"]],
                "distance_km": ["type": ["number", "null"]],
                "duration_min": ["type": ["number", "null"]],
                "perceived_effort": ["type": ["string", "null"], "enum": ["easy", "moderate", "hard", "very_hard", NSNull()]],
                "start_time": ["type": ["string", "null"]],
                "reason": JSONSchema.string,
            ], required: ["activity_id", "type", "notes", "distance_km", "duration_min", "perceived_effort", "start_time", "reason"]),
            argsType: UpdateArgs.self
        ) { args, ctx in
            guard let id = UUID(uuidString: args.activityId),
                  let session = ActivityRepository.sessions(context: ctx.modelContext).first(where: { $0.id == id }) else {
                return .error("activity '\(args.activityId)' not found")
            }
            let updates = ActivityUpdates(
                type: args.type, notes: args.notes, distanceKm: args.distanceKm,
                durationMin: args.durationMin, perceivedEffort: args.perceivedEffort, startTime: args.startTime
            )
            let isToday = Calendar.current.isDateInToday(session.startedAt)
            if isToday {
                applyUpdatesNow(updates, to: session, context: ctx.modelContext)
                ctx.loggedActivityIds.append(session.id)
                return .object(["ok": true, "updated": true, "activity_id": args.activityId])
            }
            // Older session → confirm.
            ctx.pendingActions.append(PendingAction(
                kind: .updateActivitySession, activityId: args.activityId,
                summary: "Update your \(ActivityMeta.label(session.type)) session from \(CoachDataAccess.localDateString(session.startedAt))?",
                confirmLabel: "Save changes", updates: updates
            ))
            return .object(["ok": true, "needs_confirmation": true,
                            "summary": "Awaiting your confirmation to edit that workout."])
        }
    }

    // MARK: delete_activity_session

    private struct DeleteArgs: Decodable {
        let activityId: String, reason: String
        enum CodingKeys: String, CodingKey { case activityId = "activity_id", reason }
    }

    private static var deleteActivitySession: AnyCoachTool {
        .make(
            name: "delete_activity_session",
            label: "Removing that workout",
            description: "Delete a workout. Always returns needs_confirmation and shows a Confirm card; the deletion only happens after the user taps Confirm.",
            parameters: JSONSchema.object([
                "activity_id": JSONSchema.string, "reason": JSONSchema.string,
            ], required: ["activity_id", "reason"]),
            argsType: DeleteArgs.self
        ) { args, ctx in
            guard let id = UUID(uuidString: args.activityId),
                  let session = ActivityRepository.sessions(context: ctx.modelContext).first(where: { $0.id == id }) else {
                return .error("activity '\(args.activityId)' not found")
            }
            ctx.pendingActions.append(PendingAction(
                kind: .deleteActivitySession, activityId: args.activityId,
                summary: "Delete your \(ActivityMeta.label(session.type)) session from \(CoachDataAccess.localDateString(session.startedAt))? This can't be undone.",
                confirmLabel: "Delete", updates: nil
            ))
            return .object(["ok": true, "needs_confirmation": true,
                            "summary": "Awaiting your confirmation to delete that workout."])
        }
    }

    // MARK: trigger_measurement (live)

    private struct MeasureArgs: Decodable {
        let measurementType: String, reason: String
        enum CodingKeys: String, CodingKey { case measurementType = "measurement_type", reason }
    }

    private static var triggerMeasurement: AnyCoachTool {
        .make(
            name: "trigger_measurement",
            label: "Starting a ring measurement",
            description: "Take a live HR or SpO2 reading from the ring if it's connected.",
            parameters: JSONSchema.object([
                "measurement_type": JSONSchema.enumString(["hr", "spo2"]),
                "reason": JSONSchema.string,
            ], required: ["measurement_type", "reason"]),
            argsType: MeasureArgs.self
        ) { args, ctx in
            guard let coordinator = ctx.coordinator, coordinator.isConnected else {
                return .object(["error": "ring_not_connected",
                                "message": "The ring isn't connected, so I can't take a live reading."])
            }
            let value: Int? = args.measurementType == "hr"
                ? await coordinator.measureHR()
                : await coordinator.measureSpO2()
            guard let value else {
                return .object(["error": "no_reading", "message": "Couldn't get a stable reading."])
            }
            return .object(["ok": true, "measurement_type": args.measurementType, "value": value])
        }
    }

    // MARK: - shared

    private static func applyUpdatesNow(_ updates: ActivityUpdates, to session: ActivitySession, context: ModelContext) {
        if let notes = updates.notes { session.notes = notes }
        if let effort = updates.perceivedEffort { session.perceivedEffort = effort }

        // Type/time changes must route through the edit service so aggregates, the sample window,
        // and the daily rollup stay consistent — setting the fields directly left them all stale
        // (Today/Activity kept the old duration/distance/calories). Mirrors `PendingActionExecutor`.
        let newType = updates.type ?? session.type
        var newStart = session.startedAt
        if let start = updates.startTime, let date = CoachDataAccess.parseLocalDate(start) { newStart = date }
        var newEnd = session.endedAt ?? Date()
        if let durationMin = updates.durationMin {
            newEnd = newStart.addingTimeInterval(durationMin * 60 + session.totalPauseSeconds)
        } else if newStart != session.startedAt {
            // Start moved without a new duration: shift the whole window, keeping its span.
            newEnd = newStart.addingTimeInterval((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        }
        let didEdit = newType != session.type || newStart != session.startedAt || newEnd != session.endedAt
        if didEdit {
            _ = ActivityService.applyEdit(
                session: session, newType: newType, newStartedAt: newStart, newEndedAt: newEnd, context: context
            )
        }

        // A user-stated distance overrides the GPS recompute, so apply it after the edit.
        if let distanceKm = updates.distanceKm { session.distanceMeters = distanceKm * 1000 }

        session.updatedAt = Date()
        try? context.save()
        // `applyEdit` already notified; only notify again when it didn't run or we changed
        // something after it (the distance override), so a plain edit doesn't double-bump.
        if !didEdit || updates.distanceKm != nil { PulseDataChange.shared.notify() }
    }
}
