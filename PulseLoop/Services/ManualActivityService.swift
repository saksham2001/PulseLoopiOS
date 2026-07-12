import Foundation
import SwiftData

enum ManualActivityCreationError: LocalizedError, Equatable {
    case invalidActivityType
    case invalidDuration
    case endsInFuture

    var errorDescription: String? {
        switch self {
        case .invalidActivityType: return "Choose a valid activity type."
        case .invalidDuration: return "Duration must be greater than zero."
        case .endsInFuture: return "The activity must end in the past."
        }
    }
}

/// Single creation path for completed workouts supplied manually by either the coach or the UI.
@MainActor
enum ManualActivityService {
    @discardableResult
    static func create(
        type: String,
        startedAt: Date,
        durationMinutes: Double,
        distanceMeters: Double? = nil,
        notes: String? = nil,
        now: Date = Date(),
        context: ModelContext
    ) throws -> ActivitySession {
        let canonicalType = ActivityMeta.meta(type).type
        guard ActivityMeta.allKinds.contains(where: { $0.type == canonicalType }) else {
            throw ManualActivityCreationError.invalidActivityType
        }
        guard durationMinutes > 0, durationMinutes.isFinite else {
            throw ManualActivityCreationError.invalidDuration
        }
        let endedAt = startedAt.addingTimeInterval(durationMinutes * 60)
        guard endedAt <= now else { throw ManualActivityCreationError.endsInFuture }

        let session = ActivitySession(
            type: canonicalType,
            status: .finished,
            startedAt: startedAt,
            endedAt: endedAt,
            distanceMeters: distanceMeters,
            notes: notes?.isEmpty == true ? nil : notes,
            useGps: false
        )
        context.insert(session)
        _ = ActivityService.finishSummary(for: session, endedAt: endedAt, context: context)
        try context.save()
        PulseDataChange.shared.notify()
        return session
    }
}
