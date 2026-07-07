import Foundation
import SwiftData

/// Which daily check-in this is.
enum CoachNotificationSlot: String, Codable, CaseIterable {
    case morning
    case midday
    case evening

    var label: String { rawValue.capitalized }

    /// The active slot for `date` given the user's configured hours, or nil when
    /// outside all windows. Each window opens at its hour and stays open ~4h,
    /// clamped to end before the next window opens so they never overlap.
    static func current(
        for date: Date, morningHour: Int, middayHour: Int, eveningHour: Int, calendar: Calendar = .current
    ) -> CoachNotificationSlot? {
        let hour = calendar.component(.hour, from: date)
        if hour >= morningHour, hour <= min(morningHour + 4, middayHour - 1) { return .morning }
        if hour >= middayHour, hour <= min(middayHour + 4, eveningHour - 1) { return .midday }
        if hour >= eveningHour, hour <= eveningHour + 4 { return .evening }
        return nil
    }

    /// Next time a slot window opens at or after `date` — used to schedule the
    /// next background wake.
    static func nextWindowStart(
        after date: Date, morningHour: Int, middayHour: Int, eveningHour: Int, calendar: Calendar = .current
    ) -> Date {
        let candidates = [morningHour, middayHour, eveningHour].sorted()
        for hour in candidates {
            if let d = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date), d > date {
                return d
            }
        }
        // Both windows passed today → first window tomorrow.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return calendar.date(bySettingHour: candidates.first ?? morningHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// Persisted record of a delivered check-in — enforces the twice-a-day cap
/// (one per slot per day) and feeds the "don't repeat" uniqueness history.
@Model
final class CoachNotificationRecord {
    @Attribute(.unique) var id: UUID
    var slotRaw: String
    var dateKey: String   // "yyyy-MM-dd" local
    var title: String
    var body: String
    var createdAt: Date

    convenience init(id: UUID = UUID(), slot: CoachNotificationSlot, dateKey: String, title: String, body: String) {
        self.init(id: id, slotRaw: slot.rawValue, dateKey: dateKey, title: title, body: body)
    }

    /// Raw-slot init for non-slot records (e.g. proactive anomaly alerts, whose
    /// `slotRaw` is an `anomaly:<kind>` dedupe key rather than a daily slot).
    init(id: UUID = UUID(), slotRaw: String, dateKey: String, title: String, body: String) {
        self.id = id
        self.slotRaw = slotRaw
        self.dateKey = dateKey
        self.title = title
        self.body = body
        self.createdAt = Date()
    }

    var slot: CoachNotificationSlot { CoachNotificationSlot(rawValue: slotRaw) ?? .morning }

    static func dateKey(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }
}
