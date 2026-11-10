import Foundation

/// The periods a vital's detail screen pages through (issue #102).
enum VitalPeriod: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }

    /// The range the chart styling keys off (axis stride, gap breaking, downsampling).
    var range: MetricRange {
        switch self {
        case .day: return .twentyFourHours
        case .week: return .sevenDays
        case .month: return .thirtyDays
        }
    }
}

/// The calendar window a vital detail chart shows for each `VitalPeriod` (issue #102).
///
/// The anchor is always the window's **start**: local midnight for a day, the first of the 7 days
/// for a week (the latest week ends today), the 1st for a month. Day used to be a rolling 24 h ending
/// now, so at 10:04 on Oct 6 it showed Oct 5 10:04 → Oct 6 10:04, and the evening of the 6th only
/// appeared under the 7th. Sleep and Activity already page by calendar day.
///
/// Steps go through calendar days rather than fixed seconds, so a day across a DST change is still
/// midnight to midnight (23 or 25 h). Pure — the calendar (and its time zone) is injected.
enum VitalPeriods {

    /// The latest window's anchor: today, the week ending today, or this month.
    static func latestAnchor(_ period: VitalPeriod, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .day:
            return today
        case .week:
            return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: today) ?? today)
        case .month:
            let parts = calendar.dateComponents([.year, .month], from: today)
            return calendar.date(from: parts).map { calendar.startOfDay(for: $0) } ?? today
        }
    }

    /// `anchor` moved by `steps` whole periods (negative = back).
    static func step(_ period: VitalPeriod, anchor: Date, by steps: Int, calendar: Calendar = .current) -> Date {
        let moved: Date?
        switch period {
        case .day: moved = calendar.date(byAdding: .day, value: steps, to: anchor)
        case .week: moved = calendar.date(byAdding: .day, value: 7 * steps, to: anchor)
        case .month: moved = calendar.date(byAdding: .month, value: steps, to: anchor)
        }
        return calendar.startOfDay(for: moved ?? anchor)
    }

    /// The window `[start, end)` an anchor covers.
    static func window(_ period: VitalPeriod, anchor: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: anchor)
        let end = step(period, anchor: start, by: 1, calendar: calendar)
        return DateInterval(start: start, end: max(end, start))
    }
}
