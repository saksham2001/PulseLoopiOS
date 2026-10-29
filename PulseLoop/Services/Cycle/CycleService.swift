import Foundation
import SwiftData

/// One day of the current cycle prepared for the BBT chart.
struct CycleChartDay: Identifiable, Equatable {
    let date: Date
    let temperature: Double?   // °C, nil = gap
    /// The value the 3-over-6 rule actually reads: rolling 3-night median over valid nights.
    /// nil on gaps and excluded nights.
    let smoothedTemperature: Double?
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
            chartDays = makeChartDays(from: records.filter { $0.date >= start })
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
        let records = zip(days, temperatures).map { day, night -> CycleDayRecord in
            let facts = loggedByKey[CycleDay.key(for: day)]
            return CycleDayRecord(
                date: day,
                temperature: night.celsius,
                isPeriod: facts?.isPeriod ?? false,
                isDisturbed: facts?.isDisturbed ?? false
            )
        }
        return makeChartDays(from: records)
    }

    /// Chart rows for one cycle's records, carrying both the raw nightly median and the smoothed
    /// value the analyzer reads (rolling 3-night median over valid nights). The chart draws its
    /// line through the smoothed series — the one the 3-over-6 rule evaluates — so a one-quantum
    /// dip in a raw median no longer reads as "back to baseline" on a day the rule counts as high.
    static func makeChartDays(from records: [CycleDayRecord]) -> [CycleChartDay] {
        let valid = records.filter(\.isValidTemperature)
        let smoothedByDate = Dictionary(uniqueKeysWithValues: zip(valid.map(\.date), CycleAnalyzer.smoothedValues(valid)))
        return records.map {
            CycleChartDay(
                date: $0.date,
                temperature: $0.temperature,
                smoothedTemperature: smoothedByDate[$0.date],
                excluded: $0.isDisturbed,
                isPeriod: $0.isPeriod
            )
        }
    }
}
