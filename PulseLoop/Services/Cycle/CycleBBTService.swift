import Foundation
import SwiftData

/// One night's basal-temperature estimate for cycle analysis.
struct CycleNightTemperature: Equatable {
    /// The waking-morning day the night belongs to (same keying as `SleepSession.date`).
    let date: Date
    /// Median of the ring's overnight skin-temperature samples, °C. `nil` when the night
    /// produced too few samples to trust.
    let celsius: Double?
    let sampleCount: Int
}

/// Extracts a nightly basal body temperature (BBT) from the ring's passive skin-temperature
/// history. The ring samples every ~30 min; a night therefore yields ~10–16 points. We take
/// the **median** of the samples inside the sleep session (excluding awake blocks) rather
/// than the mean: samples are quantized to 0.1 °C and a hand outside the blanket produces
/// low outliers the median shrugs off.
@MainActor
enum CycleBBTService {
    /// Fewer overnight samples than this and the night is reported as "no data" — a couple
    /// of stray readings say nothing about basal temperature.
    static let minimumSamples = 4

    /// Nightly temperatures for every day in `days` (inclusive, newest last). Days without a
    /// usable night are still present with `celsius == nil` so charts can show gaps honestly.
    /// Sessions and awake blocks are fetched once for the whole span — never per night.
    static func nightlyTemperatures(days: [Date], context: ModelContext) -> [CycleNightTemperature] {
        guard !days.isEmpty else { return [] }
        let calendar = Calendar.current
        let sessions = SleepRepository.sessions(context: context)
        let awakeRaw = SleepStage.awake.rawValue
        let awakeBlocks = (try? context.fetch(FetchDescriptor<SleepStageBlock>(
            predicate: #Predicate { $0.stageRaw == awakeRaw }
        ))) ?? []
        let awakeBySession = Dictionary(grouping: awakeBlocks, by: \.sessionId)
        return days.map { day in
            nightTemperature(for: calendar.startOfDay(for: day), sessions: sessions, awakeBySession: awakeBySession, context: context)
        }
    }

    /// The basal temperature for the night that ended on the morning of `day`.
    static func nightTemperature(for day: Date, context: ModelContext) -> CycleNightTemperature {
        nightlyTemperatures(days: [day], context: context)[0]
    }

    private static func nightTemperature(
        for day: Date,
        sessions: [SleepSession],
        awakeBySession: [UUID: [SleepStageBlock]],
        context: ModelContext
    ) -> CycleNightTemperature {
        let calendar = Calendar.current
        if let session = sessions.first(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            let awake = (awakeBySession[session.id] ?? [])
                .map { block -> ClosedRange<Date> in
                    block.startAt...(block.startAt.addingTimeInterval(TimeInterval(block.durationMinutes * 60)))
                }
            let samples = MetricsRepository.measurements(
                kind: .temperature, start: session.startAt, end: session.endAt, context: context
            )
            .filter { sample in !awake.contains { $0.contains(sample.timestamp) } }
            .map(\.value)
            .filter { $0 > 0 }
            return night(day: day, values: samples)
        }
        // No sleep session detected (missed sync, unusual schedule). Fall back to the most
        // *stable* stretch of temperature in the surrounding 24 h: skin temperature during
        // rest is steady, daytime readings are noisy — so the lowest-variance 4 h window is
        // the best guess at the rest period. A fixed clock window (e.g. 2–5 AM) would be
        // wrong for night-shift users.
        return stableWindowFallback(for: day, context: context)
    }

    private static func stableWindowFallback(for day: Date, context: ModelContext) -> CycleNightTemperature {
        let calendar = Calendar.current
        // Noon-to-noon around the waking morning, mirroring the sleep grouping boundary.
        guard let windowStart = calendar.date(byAdding: .hour, value: -12, to: day),
              let windowEnd = calendar.date(byAdding: .hour, value: 12, to: day) else {
            return CycleNightTemperature(date: day, celsius: nil, sampleCount: 0)
        }
        let samples = MetricsRepository.measurements(kind: .temperature, start: windowStart, end: windowEnd, context: context)
            .filter { $0.value > 0 }
            .sorted { $0.timestamp < $1.timestamp }
        // 4 h at the ring's ~30 min cadence ⇒ 8 samples per window; require enough for a median.
        let windowSize = 8
        guard samples.count >= max(windowSize, minimumSamples) else {
            return CycleNightTemperature(date: day, celsius: nil, sampleCount: 0)
        }
        var best: (variance: Double, values: [Double])?
        for start in 0...(samples.count - windowSize) {
            let slice = samples[start..<(start + windowSize)]
            // Reject windows spanning a data gap — "contiguous" means the cadence held.
            let span = slice.last!.timestamp.timeIntervalSince(slice.first!.timestamp)
            guard span <= TimeInterval(windowSize) * 45 * 60 else { continue }
            let values = slice.map(\.value)
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            if best == nil || variance < best!.variance {
                best = (variance, values)
            }
        }
        guard let best else { return CycleNightTemperature(date: day, celsius: nil, sampleCount: 0) }
        return night(day: day, values: best.values)
    }

    private static func night(day: Date, values: [Double]) -> CycleNightTemperature {
        guard values.count >= minimumSamples else {
            return CycleNightTemperature(date: day, celsius: nil, sampleCount: values.count)
        }
        return CycleNightTemperature(date: day, celsius: median(values), sampleCount: values.count)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
