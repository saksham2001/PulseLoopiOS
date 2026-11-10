import Foundation
import SwiftData

/// One calendar day's activity totals as the Activity summary card shows them (issues #76 / #101).
///
/// Read from that day's own `ActivityDaily` row — a day with nothing stored is all-nil and renders
/// "—", never falling back to the latest day the way the Today summary does. Calories go through the
/// same read path as Today (`effectiveCalories`: the ring's figure when it reported one, else BMR
/// accrued plus the on-device active estimate), so the two screens agree on today.
struct ActivityDayTotals: Equatable {
    var steps: Int?
    var distanceMeters: Double?
    var calories: Double?
    /// The active-energy part of `calories` — what the calorie goal ring measures.
    var activeCalories: Double?

    static let empty = ActivityDayTotals()

    @MainActor
    static func load(day: Date, context: ModelContext, now: Date = Date()) -> ActivityDayTotals {
        guard let row = MetricsRepository.activity(on: day, context: context) else { return .empty }
        let profile = MetricsProfileValues(profile: ProfileRepository.profile(context: context))
        return ActivityDayTotals(
            steps: row.steps,
            distanceMeters: row.distanceMeters,
            calories: row.effectiveCalories(profile: profile, now: now),
            activeCalories: row.effectiveActiveCalories
        )
    }
}
