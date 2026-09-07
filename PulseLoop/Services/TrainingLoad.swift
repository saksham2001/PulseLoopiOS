import Foundation

/// Heart-rate training load: how much cardiovascular work a day actually contained, and whether the
/// last week of it is in line with the last month.
///
/// Pure maths — the SwiftData-facing side lives in `TrainingLoadService`.
///
/// The model is **Edwards' summated heart-rate zones**, not Banister's TRIMP. Banister needs a
/// reliable average HR over a bounded session; PulseLoop's all-day data is sparse, irregularly
/// spaced, and has no session boundaries, so Edwards — which just weights time spent in each zone —
/// degrades far more gracefully. It is also the model the app can already show its working for,
/// since the workout summary screen already renders exactly these five zones.
enum TrainingLoad {
    /// Edwards' weights: a minute in zone 5 counts five times a minute in zone 1.
    static let zoneWeights: [Double] = [1, 2, 3, 4, 5]

    /// Zone floors as a fraction of maximum heart rate, matching the boundaries the workout summary
    /// already draws (`hrZoneDurations`) so the two can never disagree.
    static let zoneFloors: [Double] = [0.00, 0.60, 0.70, 0.80, 0.90]

    /// Age-predicted maximum heart rate. The plain 220 − age form, and the same fallback the workout
    /// summary uses when age is unknown.
    static func maxHeartRate(age: Int?) -> Double {
        Double(age.map { 220 - $0 } ?? 190)
    }

    /// Seconds spent in each of the five zones, low to high.
    ///
    /// Each sample is credited the gap to the next one, capped adaptively: fully up to about twice
    /// the median spacing, and never more than five minutes. Without that cap an overnight gap
    /// between two all-day readings would be credited as hours of zone-1 "work". Copied in spirit
    /// from `hrZoneDurations`, which does the same for a single workout.
    static func zoneSeconds(samples: [MetricSample], hrMax: Double) -> [Double] {
        var seconds = [Double](repeating: 0, count: 5)
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1, hrMax > 0 else { return seconds }

        let gaps = zip(sorted, sorted.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .filter { $0 > 0 }
            .sorted()
        let median = gaps.isEmpty ? 30 : gaps[gaps.count / 2]
        let cap = min(300, max(30, median * 2))

        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let dt = min(cap, b.timestamp.timeIntervalSince(a.timestamp))
            guard dt > 0 else { continue }
            seconds[zoneIndex(forHeartRate: a.value, hrMax: hrMax)] += dt
        }
        return seconds
    }

    /// Which zone a reading falls in, 0-based.
    static func zoneIndex(forHeartRate bpm: Double, hrMax: Double) -> Int {
        guard hrMax > 0 else { return 0 }
        let fraction = bpm / hrMax
        // Walk down so the highest floor a reading clears wins.
        for index in stride(from: zoneFloors.count - 1, through: 1, by: -1) where fraction >= zoneFloors[index] {
            return index
        }
        return 0
    }

    /// Edwards load for a set of readings: Σ (minutes in zone × zone weight).
    ///
    /// Unitless by construction — it is a weighted minute count, not an energy figure. A day of
    /// gentle walking lands in the tens; a hard hour lands in the low hundreds.
    static func load(samples: [MetricSample], hrMax: Double) -> Double {
        zip(zoneSeconds(samples: samples, hrMax: hrMax), zoneWeights)
            .reduce(0) { $0 + ($1.0 / 60) * $1.1 }
    }

    // MARK: - Acute vs chronic

    /// Days of recent load against the longer-run baseline.
    struct Balance: Equatable {
        /// Mean daily load over the last 7 days.
        let acute: Double
        /// Mean daily load over the last 28 days.
        let chronic: Double
        /// `acute / chronic`, or nil when the chronic window is empty or too thin to trust.
        let ratio: Double?
        /// How many of the 28 chronic days actually carried data.
        let chronicDaysCovered: Int

        var band: Band { Band(ratio: ratio) }
    }

    /// The acute:chronic workload ratio's usual reading. Bands are the sports-science convention:
    /// roughly 0.8–1.3 is the range associated with the lowest injury risk in the literature, with
    /// anything past 1.5 flagged as a spike.
    ///
    /// Presented as guidance, not a verdict: the evidence base is contested and was built on
    /// athletes with far better data than an optical ring provides.
    enum Band: String {
        case detraining = "Detraining"
        case steady = "Steady"
        case building = "Building"
        case spike = "Spike"
        case unknown = "Not enough history"

        init(ratio: Double?) {
            guard let ratio, ratio.isFinite else { self = .unknown; return }
            // Upper bounds inclusive: a ratio of exactly 1.3 is the top of steady, not the bottom
            // of building.
            switch ratio {
            case ..<0.8: self = .detraining
            case ...1.3: self = .steady
            case ...1.5: self = .building
            default: self = .spike
            }
        }

        var detail: String {
            switch self {
            case .detraining: return "This week is lighter than your recent normal."
            case .steady: return "This week is in line with your recent normal."
            case .building: return "This week is a step up from your recent normal."
            case .spike: return "This week is well above your recent normal — worth easing off."
            case .unknown: return "A few more weeks of wear and this will have something to compare against."
            }
        }
    }

    /// Fewest covered days in the 28-day window before a ratio means anything. Below this the
    /// chronic average is really a short-window average wearing a long window's name.
    static let minChronicDays = 14

    /// Acute (7-day) against chronic (28-day) mean daily load.
    ///
    /// **Days with no data are excluded from both means, not counted as rest.** A week the ring
    /// wasn't worn is not a week of recovery, and averaging in zeros would manufacture a
    /// "detraining" reading out of a charging cable.
    static func balance(dailyLoad: [Date: Double], now: Date = Date(), calendar: Calendar = .current) -> Balance {
        func mean(overLastDays days: Int) -> (mean: Double, covered: Int) {
            let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
                ?? calendar.startOfDay(for: now)
            let values = dailyLoad.filter { $0.key >= cutoff }.map(\.value)
            guard !values.isEmpty else { return (0, 0) }
            return (values.reduce(0, +) / Double(values.count), values.count)
        }

        let acute = mean(overLastDays: 7)
        let chronic = mean(overLastDays: 28)
        let ratio: Double? = (chronic.covered >= minChronicDays && chronic.mean > 0)
            ? acute.mean / chronic.mean
            : nil

        return Balance(acute: acute.mean, chronic: chronic.mean,
                       ratio: ratio, chronicDaysCovered: chronic.covered)
    }
}
