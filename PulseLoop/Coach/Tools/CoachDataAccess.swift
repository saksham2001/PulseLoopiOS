import Foundation
import SwiftData

/// Date-range reads over the existing repositories, shared by retrieval,
/// charting, and analysis tools. The LLM never queries SwiftData directly — it
/// only ever reaches data through these deterministic helpers (the iOS analogue
/// of the web app's tool data layer).
@MainActor
enum CoachDataAccess {
    /// Inclusive local-date bounds parsed from "YYYY-MM-DD" (time component ignored).
    static func dayBounds(_ start: String, _ end: String) -> (start: Date, end: Date)? {
        guard let s = parseLocalDate(start), let e = parseLocalDate(end) else { return nil }
        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e)) ?? e
        return (cal.startOfDay(for: s), endOfDay)
    }

    static func parseLocalDate(_ value: String) -> Date? {
        let trimmed = String(value.prefix(10))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        if let d = f.date(from: trimmed) { return d }
        // Fall back to ISO datetime.
        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }

    static func localDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Reads

    static func measurements(
        kind: MeasurementKind, start: String, end: String, context: ModelContext
    ) -> [Measurement] {
        guard let bounds = dayBounds(start, end) else { return [] }
        // Windowed DB query (predicate + limit) instead of fetching the whole table and filtering.
        return MetricsRepository.measurements(kind: kind, start: bounds.start, end: bounds.end, limit: 5000, context: context)
            .sorted { $0.timestamp < $1.timestamp }
    }

    static func activityRows(start: String, end: String, context: ModelContext) -> [ActivityDaily] {
        guard let bounds = dayBounds(start, end) else { return [] }
        return MetricsRepository.activityRows(context: context)
            .filter { $0.date >= bounds.start && $0.date < bounds.end }
            .sorted { $0.date < $1.date }
    }

    static func activityRow(on date: String, context: ModelContext) -> ActivityDaily? {
        guard let day = parseLocalDate(date) else { return nil }
        return MetricsRepository.activity(on: day, context: context)
    }

    static func sleepSessions(start: String, end: String, context: ModelContext) -> [SleepSession] {
        guard let bounds = dayBounds(start, end) else { return [] }
        return SleepRepository.sessions(context: context)
            .filter { $0.date >= bounds.start && $0.date < bounds.end }
            .sorted { $0.date < $1.date }
    }

    static func activitySessions(start: String, end: String, context: ModelContext) -> [ActivitySession] {
        guard let bounds = dayBounds(start, end) else { return [] }
        return ActivityRepository.sessions(context: context)
            .filter { $0.startedAt >= bounds.start && $0.startedAt < bounds.end }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Stats

    struct Stats: Encodable {
        var count: Int
        var avg: Double?
        var min: Double?
        var max: Double?
    }

    static func stats(_ values: [Double]) -> Stats {
        guard !values.isEmpty else { return Stats(count: 0, avg: nil, min: nil, max: nil) }
        let avg = (values.reduce(0, +) / Double(values.count)).rounded(toPlaces: 1)
        return Stats(count: values.count, avg: avg, min: values.min(), max: values.max())
    }

    /// Daily-aligned value series for a metric over a range, used by analysis +
    /// charts. Activity metrics come from daily rollups; hr/spo2 are averaged per
    /// day; sleep uses total minutes per night.
    static func dailySeries(
        metric: CoachChartMetric, start: String, end: String, context: ModelContext
    ) -> [(date: Date, value: Double)] {
        switch metric {
        case .steps, .calories, .distance, .activeMinutes:
            return activityRows(start: start, end: end, context: context).map { row in
                let v: Double
                switch metric {
                case .steps: v = Double(row.steps)
                case .calories: v = row.calories
                case .distance: v = row.distanceMeters / 1000
                case .activeMinutes: v = Double(row.activeMinutes)
                default: v = 0
                }
                return (row.date, v)
            }
        case .hr, .spo2:
            let kind: MeasurementKind = metric == .hr ? .heartRate : .spo2
            let rows = measurements(kind: kind, start: start, end: end, context: context)
            let cal = Calendar.current
            let grouped = Dictionary(grouping: rows) { cal.startOfDay(for: $0.timestamp) }
            return grouped.map { day, ms in
                (day, (ms.map(\.value).reduce(0, +) / Double(ms.count)).rounded(toPlaces: 1))
            }.sorted { $0.date < $1.date }
        case .sleep:
            return sleepSessions(start: start, end: end, context: context)
                .map { ($0.date, Double($0.totalMinutes)) }
        }
    }

    /// Granularity-aware series for charts/series tools. For hr/spo2, "raw" yields
    /// the individual timestamped samples (intraday trend), "hour" averages per
    /// hour, "day" averages per day. Activity/sleep metrics are daily rollups and
    /// always return one point per day. Capped to 300 points (even downsample).
    static func seriesPoints(
        metric: CoachChartMetric, start: String, end: String, granularity: String, context: ModelContext
    ) -> [(x: String, y: Double)] {
        let dated: [(Date, Double)]
        let labeler: (Date) -> String

        switch metric {
        case .hr, .spo2:
            let kind: MeasurementKind = metric == .hr ? .heartRate : .spo2
            let rows = measurements(kind: kind, start: start, end: end, context: context)
            switch granularity {
            case "hour":
                let cal = Calendar.current
                let grouped = Dictionary(grouping: rows) { row -> Date in
                    cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: row.timestamp)) ?? row.timestamp
                }
                dated = grouped
                    .map { ($0.key, ($0.value.map(\.value).reduce(0, +) / Double($0.value.count)).rounded(toPlaces: 1)) }
                    .sorted { $0.0 < $1.0 }
                labeler = hourLabel
            case "day":
                dated = dailySeries(metric: metric, start: start, end: end, context: context).map { ($0.date, $0.value) }
                labeler = localDateString
            default:  // "raw" / "minute" → individual samples
                dated = rows.map { ($0.timestamp, $0.value) }
                labeler = isoString
            }
        default:  // activity/sleep are daily rollups
            dated = dailySeries(metric: metric, start: start, end: end, context: context).map { ($0.date, $0.value) }
            labeler = localDateString
        }

        return downsample(dated, max: 300).map { (x: labeler($0.0), y: $0.1) }
    }

    private static func downsample(_ points: [(Date, Double)], max: Int) -> [(Date, Double)] {
        guard points.count > max else { return points }
        let step = Double(points.count) / Double(max)
        return (0..<max).map { points[Int(Double($0) * step)] }
    }

    private static func hourLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:00"
        f.timeZone = .current
        return f.string(from: date)
    }
}
