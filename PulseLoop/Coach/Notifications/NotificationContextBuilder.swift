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
    var environment: CoachContextPacket.EnvironmentContext?
    /// Present only when nutrition tracking is on, shared with the coach, AND the
    /// check-in sub-toggle allows it.
    var nutrition: CoachContextPacket.NutritionContext?
    /// Last night measured against the learned resting-HR baseline.
    ///
    /// This is the one block the 12-hour window can't supply on its own: drift is only meaningful
    /// against a multi-day baseline, which is why `restingHRDrift` sat declared-but-unfired. The
    /// baseline is already learned and persisted by `RestingHRBaselineService`, so the packet just
    /// carries it in alongside the single night to compare it to.
    var restingHR: RestingHRContext?
    /// Last night's overnight signals against their own 30-day baselines. Present only when at
    /// least two of them had a baseline to be judged against.
    var healthWatch: HealthWatchContext?

    struct HealthWatchContext: Encodable {
        var status: String
        var signalsAvailable: Int
        /// Only the signals that departed far enough to count, worst first.
        var flagged: [HealthWatchSignal]
        /// The already-grounded sentence, so the model restates rather than re-derives it.
        var facts: String
    }

    /// One departed signal. A sibling of `HealthWatchContext` rather than nested inside it, to stay
    /// within SwiftLint's one-level nesting rule.
    struct HealthWatchSignal: Encodable {
        var signal: String
        var value: Double
        var baseline: Double
        var detail: String
    }

    struct RestingHRContext: Encodable {
        /// The learned 10th-percentile resting HR over 30 days. Non-nil implies established —
        /// `RestingHRBaselineService` stores nil until it has ≥20 samples spanning ≥7 days.
        var baselineBpm: Double
        /// Last night's resting HR, measured the same way over the night's own HR samples.
        var lastNightBpm: Double
        /// How many HR samples that night figure came from, so the model can weigh it.
        var sampleCount: Int
        /// Local date of the night, so a stale night is visible rather than implied to be recent.
        var nightOf: String
    }
}

@MainActor
enum NotificationContextBuilder {
    static func build(
        slot: CoachNotificationSlot, context: ModelContext, now: Date = Date(),
        environment: CoachContextPacket.EnvironmentContext? = nil
    ) -> NotificationContextPacket {
        // Check-ins honor their own nutrition sub-toggle on top of the share-with-coach gate.
        let packet = CoachContextBuilder.build(
            context: context, now: now,
            includeNutrition: NutritionPrefsStore.shared.prefs.includeInNotifications
        )
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
            dataQualityWarnings: packet.dataQualityWarnings,
            environment: environment,
            nutrition: packet.nutrition,
            restingHR: restingHR(context: context, now: now),
            healthWatch: healthWatch(context: context, now: now)
        )
    }

    /// Last night's overnight signals against their own baselines, or nil when fewer than two could
    /// be judged — see `HealthWatch.minSignals`.
    static func healthWatch(
        context: ModelContext, now: Date = Date()
    ) -> NotificationContextPacket.HealthWatchContext? {
        guard let result = HealthWatchService.evaluate(now: now, context: context),
              result.signalsAvailable >= HealthWatch.minSignals else { return nil }

        return .init(
            status: result.status.rawValue,
            signalsAvailable: result.signalsAvailable,
            flagged: result.flagged.map {
                .init(signal: $0.signal.title, value: ($0.value * 10).rounded() / 10,
                      baseline: ($0.baseline * 10).rounded() / 10, detail: $0.detail)
            },
            facts: HealthWatch.facts(result)
        )
    }

    /// Last night's resting HR beside the learned baseline, or nil when either is unavailable.
    ///
    /// The night is bounded by the sleep session itself rather than a fixed clock window, so a shift
    /// worker or a late night is measured over the hours they actually slept. `SleepService.latestSleep`
    /// already withholds stale sessions, so a ring that hasn't synced in days yields nil here rather
    /// than comparing against an old night.
    static func restingHR(
        context: ModelContext, now: Date = Date()
    ) -> NotificationContextPacket.RestingHRContext? {
        guard let baseline = ProfileRepository.profile(context: context)?.hrRestingBaseline,
              let night = SleepService.latestSleep(context: context) else { return nil }

        let samples = MetricsRepository.measurements(
            kind: .heartRate, start: night.session.startAt, end: night.session.endAt, context: context
        ).map(\.value).filter { $0 > 0 }

        // A YCBT ring floors its all-day interval at 30 minutes, so a full night is only ~14 samples
        // there against ~84 on a 5-minute Colmi. Ten keeps both usable while still refusing to call a
        // handful of readings a resting heart rate.
        guard samples.count >= minNightSamples else { return nil }

        return .init(
            baselineBpm: (baseline * 10).rounded() / 10,
            lastNightBpm: (RestingHRBaselineService.percentile(
                samples.sorted(), RestingHRBaselineService.restingPercentile
            ) * 10).rounded() / 10,
            sampleCount: samples.count,
            nightOf: CoachDataAccess.localDateString(night.session.date)
        )
    }

    /// Fewest overnight HR samples that can stand in for a night's resting heart rate.
    static let minNightSamples = 10
}
