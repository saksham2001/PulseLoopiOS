import Foundation

/// A notable, gently-actionable pattern detected in the user's recent data.
enum CoachAnomalyKind: String, Codable, Equatable {
    case lowSpO2
    case poorSleep
    /// Reserved for a future baseline-aware detector (needs multi-day history).
    case restingHRDrift
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
/// first. (Resting-HR drift is deferred — it needs a multi-day baseline the
/// 12-hour packet doesn't carry.)
enum CoachAnomalyDetector {
    static func detect(_ packet: NotificationContextPacket) -> CoachAnomaly? {
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

        return nil
    }
}
