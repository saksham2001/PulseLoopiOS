import Foundation
import SwiftData

/// Resolves last night's values and their 30-day baselines, and hands them to `HealthWatch`.
///
/// Every signal is measured **over the night itself**, bounded by the sleep session rather than a
/// fixed clock window — the same choice the resting-HR drift detector makes, and for the same
/// reason: a shift worker's night is still their night.
@MainActor
enum HealthWatchService {

    /// How far back the per-signal baselines look.
    static let baselineWindowDays = 30

    /// Fewest nights a baseline needs before it is trusted. Matches `BaselineStats.isEstablished`'s
    /// week-of-wear floor, counted in nights rather than samples because these are nightly figures.
    static let minBaselineNights = 7

    /// Fewest readings within one night for that night's figure to stand. A YCBT ring floors its
    /// all-day interval at 30 minutes, so a full night is only ~14 samples there.
    static let minNightSamples = 6

    /// Last night judged against your own baselines, or nil when there is no recent night to judge.
    static func evaluate(now: Date = Date(), context: ModelContext) -> HealthWatch.Result? {
        guard let night = SleepService.latestSleep(context: context) else { return nil }
        let start = night.session.startAt
        let end = night.session.endAt

        var values: [HealthWatch.Signal: Double] = [:]
        var baselines: [HealthWatch.Signal: Double] = [:]

        for signal in HealthWatch.Signal.allCases {
            guard let value = nightValue(signal, start: start, end: end, context: context) else { continue }
            guard let baseline = baseline(signal, before: start, context: context) else { continue }
            values[signal] = value
            baselines[signal] = baseline
        }

        return HealthWatch.evaluate(values: values, baselines: baselines)
    }

    /// One signal's figure for a single night.
    ///
    /// Heart rate uses the 10th percentile — its resting figure, matching how
    /// `RestingHRBaselineService` builds the long-run baseline it is compared against. Everything
    /// else uses the mean, since none of them have a "resting" notion distinct from their average.
    static func nightValue(
        _ signal: HealthWatch.Signal, start: Date, end: Date, context: ModelContext
    ) -> Double? {
        let samples = MetricsRepository.measurements(
            kind: measurementKind(signal), start: start, end: end, limit: 2000, context: context
        ).map(\.value).filter { $0 > 0 }
        guard samples.count >= minNightSamples else { return nil }

        if signal == .restingHeartRate {
            return RestingHRBaselineService.percentile(samples.sorted(), RestingHRBaselineService.restingPercentile)
        }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// The signal's own baseline: the median of the preceding nights' figures.
    ///
    /// **Median of per-night figures, not a mean of every sample.** One night the ring recorded four
    /// times as often as usual would otherwise dominate a raw sample mean, and a single feverish
    /// night would drag the very baseline it needs to be judged against.
    static func baseline(
        _ signal: HealthWatch.Signal, before night: Date, context: ModelContext, calendar: Calendar = .current
    ) -> Double? {
        let windowStart = calendar.date(byAdding: .day, value: -baselineWindowDays, to: night) ?? night
        // Windowed predicate fetch — the whole-table `SleepRepository.sessions` would read every
        // night ever recorded to answer a 30-day question.
        let descriptor = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.startAt >= windowStart && $0.startAt < night },
            sortBy: [SortDescriptor(\.startAt, order: .reverse)]
        )
        let sessions = (try? context.fetch(descriptor)) ?? []

        let nightly = sessions.compactMap {
            nightValue(signal, start: $0.startAt, end: $0.endAt, context: context)
        }
        guard nightly.count >= minBaselineNights else { return nil }

        let sorted = nightly.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func measurementKind(_ signal: HealthWatch.Signal) -> MeasurementKind {
        switch signal {
        case .skinTemperature: return .temperature
        case .restingHeartRate: return .heartRate
        case .hrv: return .hrv
        case .respiratoryRate: return .respiratoryRate
        case .bloodOxygen: return .spo2
        }
    }
}
