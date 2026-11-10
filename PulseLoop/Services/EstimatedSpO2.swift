import Foundation
import SwiftData

/// Hourly SpO₂ that a ring computes from heart rate rather than measures (Android issue #103).
///
/// On a YCBT ring (`Ale-Hop2211`, a SmartHealth Colmi) the reporter read all 304 hourly combined
/// ("All", `05 09`) records out of the ring and the same heart rate always came with the same SpO₂, without
/// one exception: HR 48 → 88, 57 → 94, 67–92 → 98, 105 → 96, never 99. That is a fixed function of
/// heart rate, not a second sensor, and the night "dips" were just a low sleeping heart rate. A spot
/// SpO₂ on the same ring is a real measurement (red LED, values up to 99), and the ring logs it in the
/// same combined record with heart rate and respiration both 0.
///
/// **Decided from the data, not from the family.** A capability set is a per-family constant and says
/// nothing about one ring; another ring in the family may measure hourly SpO₂ for real, and calling
/// that "estimated" would be a false statement about the user's hardware. So the verdict is earned per
/// ring, from what it actually logged.
///
/// ## What is stored, and why the rule has this shape
///
/// `YCBTHealthRecords.combinedVitals` writes a combined record's SpO₂ (byte 9) and respiratory rate
/// (byte 10) as two history rows at the record's own timestamp. It does **not** store the record's
/// heart rate (byte 6) — HR history comes from `05 15`, at that log's own timestamps. Hence:
///
/// - **Hourly vs spot** is decided by the respiratory row: an SpO₂ history row with a respiratory
///   history row at the *identical* timestamp came from a combined record that carried more than SpO₂.
///   A spot record logs respiration 0, which the decoder never stores, so a spot reading can never
///   qualify — not by threshold, by construction.
/// - **"A function of heart rate"** is tested by pairing each hourly row with the nearest HR history
///   row within `pairWindow`, and asking whether any heart rate ever came with two different SpO₂
///   values. A real oximeter sampled twice at the same heart rate disagrees with itself sooner or later;
///   this ring never did across 304 records, so the test allows no exceptions.
///
/// Nothing is labelled until the evidence is there: an unearned label on a health screen is a claim
/// about the hardware. Stored rows are never changed — this only decides how they are shown/exported.
enum EstimatedSpO2 {
    /// How far an HR history row may sit from an hourly SpO₂ row and still be the same measurement.
    /// The combined records land ~35 s after the hour (the end of the ring's ~35 s HR run), and the ring
    /// runs one measurement at a time, so a neighbour inside two minutes is that measurement.
    static let pairWindow: TimeInterval = 2 * 60

    /// A day of hourly records — fewer, and a constant-looking stretch is a coincidence.
    static let minPairs = 24

    /// Pairs whose heart rate had already been seen. Only these *test* the mapping; a heart rate seen
    /// once is trivially consistent with itself.
    static let minRepeats = 12

    /// How much history the verdict is drawn from: wider than a chart's 24 h so one quiet day doesn't
    /// decide it, and bounded so a previously paired ring ages out of it.
    static let lookback: TimeInterval = 7 * 86_400

    /// The Vitals card's footnote, shared with the detail disclaimer so the two never drift.
    static let note = "Hourly readings are estimated from heart rate — this ring's hourly SpO₂ isn't a "
        + "separate measurement. Spot readings you take are measured."

    /// The detail chart's disclaimer.
    static let disclaimer = note + " On this ring the same heart rate always comes with the same hourly "
        + "SpO₂, so a night-time dip here follows a low sleeping heart rate rather than measuring oxygen."

    /// One row reduced to what the rule reads.
    struct Sample: Equatable {
        let timestamp: Date
        let value: Double
    }

    /// One hourly SpO₂ row and the heart rate it was paired with, as whole numbers.
    struct Pair: Equatable {
        let heartRate: Int
        let spo2: Int
    }

    // MARK: - Pure rule

    /// The SpO₂ rows that came from an hourly combined record: those with a respiratory-rate row at
    /// the identical timestamp. Spot records (respiration 0) are excluded by construction.
    static func hourly(_ spo2: [Sample], respiratoryTimestamps: Set<Date>) -> [Sample] {
        spo2.filter { respiratoryTimestamps.contains($0.timestamp) }
    }

    /// Each hourly row paired with the nearest heart-rate sample within `pairWindow`. Rows with no
    /// heart rate close enough are left out.
    static func pairs(hourly: [Sample], heartRate: [Sample]) -> [Pair] {
        guard !hourly.isEmpty, !heartRate.isEmpty else { return [] }
        let hr = heartRate.sorted { $0.timestamp < $1.timestamp }
        return hourly.compactMap { s in
            // First HR at or after the SpO₂ row; its predecessor is the only other candidate.
            var lo = 0, hi = hr.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if hr[mid].timestamp < s.timestamp { lo = mid + 1 } else { hi = mid }
            }
            let candidates = [lo - 1, lo].filter { hr.indices.contains($0) }.map { hr[$0] }
            guard let nearest = candidates.min(by: {
                abs($0.timestamp.timeIntervalSince(s.timestamp)) < abs($1.timestamp.timeIntervalSince(s.timestamp))
            }), abs(nearest.timestamp.timeIntervalSince(s.timestamp)) <= pairWindow else { return nil }
            return Pair(heartRate: Int(nearest.value), spo2: Int(s.value))
        }
    }

    /// Whether `pairs` show SpO₂ as a fixed function of heart rate: enough pairs, enough repeated
    /// heart rates to actually test the mapping, more than one SpO₂ value (a constant reading is a
    /// function of anything and says nothing about where it came from), and no heart rate ever paired
    /// with two different SpO₂ values.
    static func derivesFromHeartRate(_ pairs: [Pair]) -> Bool {
        guard pairs.count >= minPairs else { return false }
        let byHeartRate = Dictionary(grouping: pairs, by: \.heartRate).mapValues { Set($0.map(\.spo2)) }
        guard pairs.count - byHeartRate.count >= minRepeats else { return false }
        guard Set(pairs.map(\.spo2)).count >= 2 else { return false }
        return byHeartRate.values.allSatisfy { $0.count == 1 }
    }

    /// The timestamps of the `spo2` rows to label as estimated: the hourly ones, and only when the
    /// hourly rows in `evidence` (with `evidenceHeartRate`) show the ring deriving them from heart rate.
    static func estimated(spo2: [Sample], respiratoryTimestamps: Set<Date>,
                          evidence: [Sample], evidenceRespiratoryTimestamps: Set<Date>,
                          evidenceHeartRate: [Sample]) -> Set<Date> {
        let evidencePairs = pairs(hourly: hourly(evidence, respiratoryTimestamps: evidenceRespiratoryTimestamps),
                                  heartRate: evidenceHeartRate)
        guard derivesFromHeartRate(evidencePairs) else { return [] }
        return Set(hourly(spo2, respiratoryTimestamps: respiratoryTimestamps).map(\.timestamp))
    }

    // MARK: - Over SwiftData

    /// `estimated` over the store: the SpO₂ history rows in `from...to` this ring computed from heart
    /// rate, judged on the last `lookback` of its history. Reads only — nothing stored is changed.
    ///
    /// Cheap on rings that never log respiration (every non-YCBT family): the respiratory probe comes
    /// back empty and the heart-rate history is never fetched.
    @MainActor
    static func estimatedTimestamps(from: Date, to: Date, now: Date = Date(), context: ModelContext) -> Set<Date> {
        let spo2 = historySamples(.spo2, from: from, to: to, context: context)
        guard !spo2.isEmpty else { return [] }
        let since = now.addingTimeInterval(-lookback)
        let respiratory = Set(historySamples(.respiratoryRate, from: min(from, since), to: max(to, now),
                                             context: context).map(\.timestamp))
        guard !respiratory.isEmpty else { return [] }
        let evidence = historySamples(.spo2, from: since, to: now, context: context)
        let heartRate = historySamples(.heartRate, from: since.addingTimeInterval(-pairWindow),
                                       to: now.addingTimeInterval(pairWindow), context: context)
        return estimated(spo2: spo2, respiratoryTimestamps: respiratory,
                         evidence: evidence, evidenceRespiratoryTimestamps: respiratory,
                         evidenceHeartRate: heartRate)
    }

    /// The ring's own log only: a live or spot row is the app's reading, never a combined record.
    @MainActor
    private static func historySamples(_ kind: MeasurementKind, from: Date, to: Date,
                                       context: ModelContext) -> [Sample] {
        let raw = kind.rawValue
        let history = MeasurementSource.history.rawValue
        let descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw && $0.sourceRaw == history && $0.timestamp >= from && $0.timestamp <= to },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { Sample(timestamp: $0.timestamp, value: $0.value) }
    }
}
