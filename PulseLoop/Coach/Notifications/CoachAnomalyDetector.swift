import Foundation

/// A notable, gently-actionable pattern detected in the user's recent data.
enum CoachAnomalyKind: String, Codable, Equatable {
    case lowSpO2
    case poorSleep
    /// Last night's resting HR sitting well above the learned 30-day baseline.
    case restingHRDrift
    /// Several overnight signals departing from their own baselines together.
    case healthWatch
}

struct CoachAnomaly: Equatable {
    let kind: CoachAnomalyKind
    /// Short, factual, already-grounded description used both for the prompt and
    /// the deterministic fallback copy.
    let facts: String

    /// Once-per-kind-per-day dedupe key (stored as a notification record slot).
    var dedupeKey: String { "anomaly:\(kind.rawValue)" }
}

/// Pure, conservative anomaly detection over the notification context packet.
/// Thresholds are intentionally cautious — a missed alert is far better than a
/// false alarm on health data. Returns at most one anomaly, highest-priority
/// first.
enum CoachAnomalyDetector {
    /// How far last night's resting HR must sit above the learned baseline before it's worth
    /// interrupting for.
    ///
    /// Five bpm is the usual consumer-wearable threshold for "your body is working harder than
    /// usual at rest" — the signal that moves first with infection, alcohol, heat and
    /// under-recovery, typically a day before the user notices anything. Below that the day-to-day
    /// noise in an optical ring's overnight sampling swamps it.
    static let driftBpm: Double = 5

    /// …and the night must be recent. The baseline is a 30-day figure, so an old night compared
    /// against it says nothing about today; `SleepService.latestSleep` already withholds stale
    /// sessions, and this is the belt-and-braces check on the packet's own date string.
    static let driftMaxNightAgeDays = 2

    static func detect(_ packet: NotificationContextPacket, now: Date = Date()) -> CoachAnomaly? {
        // 1. Low SpO₂ — most clinically meaningful. Require a few readings so a
        //    single noisy sample doesn't trigger an alert.
        if packet.spo2Last12h.count >= 3, let lowest = packet.spo2Last12h.min, lowest < 90 {
            let pct = Int(lowest.rounded())
            return CoachAnomaly(
                kind: .lowSpO2,
                facts: "The lowest blood-oxygen reading in the last 12 hours was \(pct)%, below the typical 95–100% range."
            )
        }

        // 2. Short sleep — fires after a sleep download, when it's most relevant.
        if let sleep = packet.latestSleep, (1..<300).contains(sleep.totalMin) {
            let h = sleep.totalMin / 60, m = sleep.totalMin % 60
            let target = packet.goals.sleepHours
            return CoachAnomaly(
                kind: .poorSleep,
                facts: "Last night's sleep was \(h)h \(m)m, well under the \(Int(target))h target."
            )
        }

        // 3. Health Watch — several overnight signals departing together. Outranks resting-HR drift
        //    below because drift is *one of its own signals*: when both trip, the multi-signal
        //    result is strictly the better-corroborated message about the same night, and firing
        //    the single-signal one instead would understate what was actually seen.
        if let watch = healthWatch(packet) { return watch }

        // 4. Resting-HR drift on its own — the case where resting HR moved but nothing corroborated
        //    it, or where it was the only signal with a baseline at all (a jring with a week of wear
        //    can reach this while Health Watch is still short of two judgeable signals).
        if let drift = restingHRDrift(packet, now: now) { return drift }

        return nil
    }

    // MARK: - Health Watch

    /// Fires on a `major` result only.
    ///
    /// `minor` is deliberately silent: it means two signals nudged past their notable knots, which
    /// happens after a glass of wine or a warm room often enough that alerting on it would train the
    /// user to dismiss the ones that matter. The minor result still reaches the Today card and the
    /// coach — it just doesn't interrupt.
    private static func healthWatch(_ packet: NotificationContextPacket) -> CoachAnomaly? {
        guard let watch = packet.healthWatch,
              watch.status == HealthWatch.Status.major.rawValue,
              !watch.flagged.isEmpty else { return nil }
        return CoachAnomaly(kind: .healthWatch, facts: watch.facts)
    }

    // MARK: - Resting-HR drift

    /// Fires when last night's resting HR sits `driftBpm` or more above the learned baseline.
    ///
    /// Only the elevated direction is reported. A resting HR *below* baseline is usually good news
    /// (fitness, a genuinely restful night) and is not something to push an unprompted alert about —
    /// the same asymmetry the readiness score applies to HRV.
    private static func restingHRDrift(
        _ packet: NotificationContextPacket, now: Date
    ) -> CoachAnomaly? {
        guard let resting = packet.restingHR else { return nil }

        let drift = resting.lastNightBpm - resting.baselineBpm
        guard drift >= driftBpm else { return nil }
        guard isRecentNight(resting.nightOf, now: now) else { return nil }

        let night = Int(resting.lastNightBpm.rounded())
        let base = Int(resting.baselineBpm.rounded())
        let delta = Int(drift.rounded())
        return CoachAnomaly(
            kind: .restingHRDrift,
            facts: "Resting heart rate overnight was \(night) bpm, \(delta) bpm above the usual \(base) bpm "
                + "learned over the last 30 days. An elevated resting heart rate often shows up a day before "
                + "you feel run down, and also follows alcohol, heat, or a hard session the day before."
        )
    }

    /// Whether the packet's night date is recent enough to say anything about today.
    private static func isRecentNight(_ nightOf: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard let date = CoachDataAccess.parseLocalDate(nightOf) else { return false }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        return days <= driftMaxNightAgeDays
    }
}
