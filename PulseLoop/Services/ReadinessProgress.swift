import Foundation
import SwiftData

/// How far along a user is toward their first readiness score.
///
/// Readiness can't say anything useful until it has enough nights to know what *your* normal looks
/// like. Without this, the empty state is a dead end — "wear your ring overnight" gives no sense of
/// whether that means one more night or two more weeks, and a user with a month of history has no
/// way to tell the feature is working rather than broken.
struct ReadinessProgress: Equatable {
    /// Nights inside the baseline window that contributed any overnight signal.
    let nightsCollected: Int
    /// Nights needed before a personal baseline is trustworthy.
    let nightsNeeded: Int
    /// Why there's no score. nil once one exists.
    let reason: ReadinessUnavailableReason?

    var nightsRemaining: Int { max(0, nightsNeeded - nightsCollected) }
    var hasEnoughNights: Bool { nightsCollected >= nightsNeeded }

    /// 0–1, for a progress bar. Clamped so a long-running user doesn't overflow it.
    var fraction: Double {
        guard nightsNeeded > 0 else { return 1 }
        return min(1, Double(nightsCollected) / Double(nightsNeeded))
    }

    /// Headline for the empty state.
    var title: String {
        if reason == nil { return "Readiness" }
        return nightsCollected == 0 ? "No score yet" : "Learning your baseline"
    }

    /// One line saying exactly where the user stands and what unblocks a score.
    ///
    /// The `hasEnoughNights` branch matters: nights are a proxy for `BaselineStats.isEstablished`,
    /// which *also* requires enough individual readings. Claiming "0 more nights" while still
    /// showing no score would be a broken promise, so that case says something honest instead.
    var detail: String {
        guard reason != nil else { return "" }
        if nightsCollected == 0 {
            return "Wear your ring overnight. Readiness needs about \(nightsNeeded) nights before it can compare a night to your normal."
        }
        if hasEnoughNights {
            return "\(nightsCollected) nights collected. Still gathering enough overnight readings — keep wearing your ring while you sleep."
        }
        let nights = nightsRemaining == 1 ? "night" : "nights"
        return "\(nightsCollected) of \(nightsNeeded) nights collected · \(nightsRemaining) more \(nights) to go"
    }

    /// Caption under the night count in the progress ring.
    ///
    /// Once the night target is met the "of N" is dropped: a user who has worn the ring thirty
    /// nights should not be told "30 of 7", which reads as a broken counter rather than as
    /// progress. The remaining blocker is explained in `detail` instead.
    var centerCaption: String {
        hasEnoughNights ? (nightsCollected == 1 ? "night" : "nights") : "of \(nightsNeeded) nights"
    }

    /// Compact form for the half-height card footer.
    var shortDetail: String {
        guard reason != nil else { return "" }
        if nightsCollected == 0 { return "Wear your ring overnight" }
        if hasEnoughNights { return "Gathering overnight readings" }
        return "\(nightsCollected) of \(nightsNeeded) nights"
    }
}

extension ReadinessService {
    /// Nights needed before `BaselineStats` trusts a personal baseline.
    ///
    /// Mirrors `BaselineStats.isEstablished`, which requires `spanDays >= 7`. Pinned by a test so
    /// the number a user is counting down against can't drift from the one that actually gates the
    /// score.
    static var baselineNightsNeeded: Int { 7 }

    /// Count the nights that have contributed usable overnight signal, and say why there's no score.
    ///
    /// Counts *nights with data*, not calendar days since install: a user who wore the ring five
    /// nights out of thirty is five nights along, not thirty, and telling them otherwise would
    /// promise a score that isn't coming.
    @MainActor
    static func progress(context: ModelContext, now: Date = Date()) -> ReadinessProgress {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let outcome = ReadinessScore.evaluate(inputs(for: today, context: context))

        var reason: ReadinessUnavailableReason?
        if case .unavailable(let why) = outcome { reason = why }

        var nights = 0
        for offset in 0..<baselineWindowDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if hasOvernightSignal(on: day, context: context) { nights += 1 }
        }

        return ReadinessProgress(
            nightsCollected: nights,
            nightsNeeded: baselineNightsNeeded,
            reason: reason
        )
    }

    /// Minimum overnight readings before a sessionless night counts as worn.
    static let minOvernightSamples = 3
    /// …and the minimum span they must cover. Together these mean "the ring was on your finger for
    /// a stretch of the night", not "the ring produced one reading at some point".
    static let minOvernightSpanHours: Double = 3

    /// Whether a night was actually slept through wearing the ring.
    ///
    /// A decoded sleep session is unambiguous. Without one, the bar is deliberately high: these
    /// rings log heart rate all day, and the fallback overnight window runs 22:00–08:00, so a ring
    /// worn until 22:30 or put back on at 07:30 leaves readings inside it without a night having
    /// been slept in it. Counting those inflates the countdown toward a score that will not arrive
    /// — which is the exact broken promise this progress indicator exists to prevent.
    @MainActor
    private static func hasOvernightSignal(on day: Date, context: ModelContext) -> Bool {
        if let sleep = SleepService.sleepForDate(day, context: context), sleep.session.totalMinutes > 0 {
            return true
        }

        let window = overnightWindow(for: day, context: context)
        var timestamps: [Date] = []
        for kind: MeasurementKind in [.hrv, .heartRate, .temperature] {
            timestamps += MetricsRepository
                .measurements(kind: kind, start: window.start, end: window.end,
                              limit: fetchLimit, context: context)
                .filter { $0.value > 0 }
                .map(\.timestamp)
        }

        guard timestamps.count >= minOvernightSamples,
              let first = timestamps.min(), let last = timestamps.max() else { return false }
        return last.timeIntervalSince(first) >= minOvernightSpanHours * 3600
    }
}
