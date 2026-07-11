import Foundation
import SwiftData

/// Performs a `PendingAction`'s real mutation — only ever called after the user
/// taps Confirm on the action card. Returns a short human result string.
@MainActor
enum PendingActionExecutor {
    static func execute(_ action: PendingAction, context: ModelContext) -> String {
        guard let id = UUID(uuidString: action.activityId),
              let session = ActivityRepository.sessions(context: context).first(where: { $0.id == id }) else {
            return "That workout no longer exists."
        }
        let typeLabel = ActivityMeta.label(session.type)

        switch action.kind {
        case .deleteActivitySession:
            for sample in ActivityRepository.samples(sessionId: id, context: context) { context.delete(sample) }
            for point in ActivityRepository.gpsPoints(sessionId: id, context: context) { context.delete(point) }
            for event in ActivityRepository.events(sessionId: id, context: context) { context.delete(event) }
            context.delete(session)
            try? context.save()
            HealthSyncService.shared.deleteExportedWorkout(sessionId: id)
            PulseDataChange.shared.notify()
            return "Deleted the \(typeLabel) session."

        case .updateActivitySession:
            apply(action.updates, to: session, context: context)
            session.updatedAt = Date()
            try? context.save()
            PulseDataChange.shared.notify()
            return "Updated the \(typeLabel) session."
        }
    }

    private static func apply(_ updates: ActivityUpdates?, to session: ActivitySession, context: ModelContext) {
        guard let updates else { return }
        if let notes = updates.notes { session.notes = notes }
        if let effort = updates.perceivedEffort { session.perceivedEffort = effort }

        // Type/time changes route through the edit service so aggregates, the sample window, and
        // the daily rollup stay consistent (setting the fields directly left them all stale).
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
        if newType != session.type || newStart != session.startedAt || newEnd != session.endedAt {
            _ = ActivityService.applyEdit(
                session: session, newType: newType, newStartedAt: newStart, newEndedAt: newEnd, context: context
            )
        }

        // A user-stated distance overrides the GPS recompute, so apply it after the edit.
        if let distanceKm = updates.distanceKm { session.distanceMeters = distanceKm * 1000 }
    }
}
