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
            HealthSyncService.shared.triggerAutomaticSync(context: context, delaySeconds: 1.0)
            return "Deleted the \(typeLabel) session."

        case .updateActivitySession:
            apply(action.updates, to: session)
            session.updatedAt = Date()
            try? context.save()
            HealthSyncService.shared.triggerAutomaticSync(context: context, delaySeconds: 1.0)
            return "Updated the \(typeLabel) session."
        }
    }

    private static func apply(_ updates: ActivityUpdates?, to session: ActivitySession) {
        guard let updates else { return }
        if let type = updates.type { session.type = type }
        if let notes = updates.notes { session.notes = notes }
        if let distanceKm = updates.distanceKm { session.distanceMeters = distanceKm * 1000 }
        if let effort = updates.perceivedEffort { session.perceivedEffort = effort }
        if let start = updates.startTime, let date = CoachDataAccess.parseLocalDate(start) {
            session.startedAt = date
        }
        if let durationMin = updates.durationMin {
            session.endedAt = session.startedAt.addingTimeInterval(durationMin * 60 + session.totalPauseSeconds)
        }
    }
}
