import Foundation
import SwiftData

/// One day of the current cycle prepared for the BBT chart.
struct CycleChartDay: Identifiable, Equatable {
    let date: Date
    let temperature: Double?   // °C, nil = gap
    let excluded: Bool         // disturbed night — drawn hollow, skipped by the analysis
    let isPeriod: Bool

    var id: Date { date }
}

/// Everything the cycle UI needs, computed in one pass off the render path.
struct CycleOverview: Equatable {
    var analysis: CycleAnalysis?
    /// Current-cycle days for the chart, oldest first (empty until a period is logged).
    var chartDays: [CycleChartDay]
    /// Days the user flagged (or confirmed) in any way, keyed by `CycleDay.key(for:)` —
    /// lets the calendar mark period/disturbed days without refetching.
    var loggedDays: [String: CycleDayFacts]

    struct CycleDayFacts: Equatable {
        var isPeriod: Bool
        var isDisturbed: Bool
        var hasNote: Bool
    }
}

/// Glue between storage and the pure analyzer: merges user-logged `CycleDay` facts with
/// `CycleBBTService` nightly temperatures into `CycleDayRecord`s, runs `CycleAnalyzer`, and
/// packages chart/calendar data. All reads, no writes.
@MainActor
enum CycleService {
    /// Analysis window cap: sleep/temperature extraction is bounded, and cycles older than
    /// this add nothing to luteal statistics (we keep at most the last 6 anyway).
    static let maxHistoryDays = 400

    /// The cycle feature needs a ring that measures temperature; the jring doesn't declare
    /// the capability, so the card/settings never appear for it (same gating as elsewhere).
    static func isAvailable(context: ModelContext) -> Bool {
        MetricsService.deviceCapabilities(context).contains(.temperature)
    }

    static func overview(context: ModelContext, today: Date = Date()) -> CycleOverview {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: today)
        let logged = CycleRepository.days(context: context)

        var loggedFacts: [String: CycleOverview.CycleDayFacts] = [:]
        for day in logged {
            loggedFacts[day.dateString] = CycleOverview.CycleDayFacts(
                isPeriod: day.isPeriod,
                isDisturbed: day.isDisturbed,
                hasNote: !(day.notes?.isEmpty ?? true)
            )
        }

        guard let firstPeriod = logged.first(where: \.isPeriod)?.date else {
            return CycleOverview(analysis: nil, chartDays: [], loggedDays: loggedFacts)
        }

        let horizon = calendar.date(byAdding: .day, value: -maxHistoryDays, to: today) ?? today
        let windowStart = max(calendar.startOfDay(for: firstPeriod), horizon)
        let dayCount = CycleAnalyzer.daysBetween(windowStart, today, calendar: calendar) + 1
        let allDays = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: windowStart) }

        let temperatures = CycleBBTService.nightlyTemperatures(days: allDays, context: context)
        let loggedByKey = Dictionary(uniqueKeysWithValues: logged.map { ($0.dateString, $0) })

        let records = zip(allDays, temperatures).map { day, night -> CycleDayRecord in
            let facts = loggedByKey[CycleDay.key(for: day)]
            return CycleDayRecord(
                date: day,
                temperature: night.celsius,
                isPeriod: facts?.isPeriod ?? false,
                isDisturbed: facts?.isDisturbed ?? false
            )
        }

        let settings = CycleSettingsStore.shared.settings
        // Under hormonal contraception the thermal analysis has no biological meaning: keep
        // period bookkeeping (cycle day, calendar) but drop every temperature-derived output.
        let analysis: CycleAnalysis?
        if settings.onHormonalContraception {
            analysis = CycleAnalyzer.analyze(
                days: records.map { CycleDayRecord(date: $0.date, temperature: nil, isPeriod: $0.isPeriod, isDisturbed: $0.isDisturbed) },
                goal: settings.goal, today: today, calendar: calendar
            )
        } else {
            analysis = CycleAnalyzer.analyze(days: records, goal: settings.goal, today: today, calendar: calendar)
        }

        let chartDays: [CycleChartDay]
        if let start = analysis?.cycleStart {
            chartDays = records.filter { $0.date >= start }.map {
                CycleChartDay(date: $0.date, temperature: $0.temperature, excluded: $0.isDisturbed, isPeriod: $0.isPeriod)
            }
        } else {
            chartDays = []
        }

        return CycleOverview(analysis: analysis, chartDays: chartDays, loggedDays: loggedFacts)
    }

    /// Chart/calendar data for an arbitrary past cycle (index into `analysis.completedCycles`).
    static func chartDays(for cycle: CompletedCycleSummary, context: ModelContext) -> [CycleChartDay] {
        let calendar = Calendar.current
        let days = (0..<cycle.lengthDays).compactMap { calendar.date(byAdding: .day, value: $0, to: cycle.start) }
        let temperatures = CycleBBTService.nightlyTemperatures(days: days, context: context)
        let logged = CycleRepository.days(context: context)
        let loggedByKey = Dictionary(uniqueKeysWithValues: logged.map { ($0.dateString, $0) })
        return zip(days, temperatures).map { day, night in
            let facts = loggedByKey[CycleDay.key(for: day)]
            return CycleChartDay(
                date: day,
                temperature: night.celsius,
                excluded: facts?.isDisturbed ?? false,
                isPeriod: facts?.isPeriod ?? false
            )
        }
    }
}
