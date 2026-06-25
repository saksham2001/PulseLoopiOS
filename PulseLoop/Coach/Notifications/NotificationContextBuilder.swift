import Foundation
import SwiftData

/// Compact ~12-hour context the notification generator sees. Reuses
/// `CoachContextBuilder` for the shared profile/goals/today/sleep/memory blocks
/// and adds a rolling 12h HR/SpO₂ window plus the slot.
///
/// Each notification is generated **independently** — we deliberately do *not*
/// thread prior check-ins through this packet. The dedup window for "don't
/// schedule two of the same slot in one day" lives in `isDuplicate`.
struct NotificationContextPacket: Encodable {
    var slot: String
    var generatedAt: String
    var timezone: String
    var profileName: String?
    var goals: CoachContextPacket.GoalContext
    var today: CoachContextPacket.DayContext
    var latestSleep: CoachContextPacket.SleepContext?
    var latestVitals: CoachContextPacket.VitalsContext
    var hrLast12h: CoachDataAccess.Stats
    var spo2Last12h: CoachDataAccess.Stats
    var recentWorkouts: [CoachContextPacket.WorkoutContext]
    var memories: [CoachContextPacket.MemoryContext]
    var dataQualityWarnings: [String]
}

@MainActor
enum NotificationContextBuilder {
    static func build(
        slot: CoachNotificationSlot, context: ModelContext, now: Date = Date()
    ) -> NotificationContextPacket {
        let packet = CoachContextBuilder.build(context: context, now: now)
        let cutoff = now.addingTimeInterval(-12 * 3600)

        // Windowed DB queries for the last 12h instead of fetching the whole table and filtering.
        let hr = MetricsRepository.measurements(kind: .heartRate, start: cutoff, end: now, context: context)
            .map(\.value)
        let spo2 = MetricsRepository.measurements(kind: .spo2, start: cutoff, end: now, context: context)
            .map(\.value)

        return NotificationContextPacket(
            slot: slot.rawValue,
            generatedAt: CoachDataAccess.isoString(now),
            timezone: TimeZone.current.identifier,
            profileName: packet.profile.name,
            goals: packet.goals,
            today: packet.today,
            latestSleep: packet.latestSleep,
            latestVitals: packet.latestVitals,
            hrLast12h: CoachDataAccess.stats(hr),
            spo2Last12h: CoachDataAccess.stats(spo2),
            recentWorkouts: packet.recentWorkouts,
            memories: packet.memories,
            dataQualityWarnings: packet.dataQualityWarnings
        )
    }
}
