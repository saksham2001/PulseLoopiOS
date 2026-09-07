import Foundation

/// Overnight signs that the body is working harder than usual — PulseLoop's equivalent of Oura's
/// Symptom Radar or Ultrahuman's Sleep Screener.
///
/// **This is not a diagnosis and never names a condition.** It reports that several overnight signals
/// moved away from your own baselines together, which is a pattern that often precedes feeling
/// unwell by about a day — and equally often follows alcohol, heat, a hard session, or a bad night.
/// The copy says so every time.
///
/// Pure maths; `HealthWatchService` reads the store.
enum HealthWatch {

    /// One signal's departure from its own baseline.
    enum Level: Int, Comparable {
        case normal = 0
        case notable = 1
        case strong = 2

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The signals this reads. Each has a direction: only the side that indicates strain counts.
    ///
    /// A resting HR *below* baseline, an HRV *above* it, or a cooler night are not warning signs, and
    /// flagging them would turn good news into an alert — the same asymmetry the resting-HR drift
    /// detector applies.
    enum Signal: String, CaseIterable {
        case skinTemperature
        case restingHeartRate
        case hrv
        case respiratoryRate
        case bloodOxygen

        var title: String {
            switch self {
            case .skinTemperature: return "Skin temperature"
            case .restingHeartRate: return "Resting heart rate"
            case .hrv: return "HRV"
            case .respiratoryRate: return "Breathing rate"
            case .bloodOxygen: return "Blood oxygen"
            }
        }

        /// `(notable, strong)` departures from baseline, in the direction that indicates strain.
        ///
        /// Temperature and resting HR come first because they are the two that move earliest and
        /// most reliably on consumer optical hardware. HRV's knots are proportional rather than
        /// absolute because HRV spans an order of magnitude across healthy adults.
        var thresholds: (notable: Double, strong: Double) {
            switch self {
            case .skinTemperature: return (0.5, 1.0)      // °C above baseline
            case .restingHeartRate: return (5, 10)        // bpm above baseline
            case .hrv: return (0.15, 0.30)                // fraction below baseline
            case .respiratoryRate: return (2, 4)          // brpm above baseline
            case .bloodOxygen: return (2, 4)              // percentage points below baseline
            }
        }

        /// Whether a departure is measured as a fraction of baseline rather than an absolute step.
        var isProportional: Bool { self == .hrv }

        /// Whether strain shows as a value *below* baseline.
        var strainIsBelowBaseline: Bool { self == .hrv || self == .bloodOxygen }

        var unit: String {
            switch self {
            case .skinTemperature: return "°C"
            case .restingHeartRate: return "bpm"
            case .hrv: return "ms"
            case .respiratoryRate: return "brpm"
            case .bloodOxygen: return "%"
            }
        }
    }

    /// One signal's reading against its baseline.
    struct Reading: Equatable {
        let signal: Signal
        let value: Double
        let baseline: Double
        let level: Level

        /// Signed departure in the strain direction: positive means "further into strain".
        var strainDelta: Double {
            let raw = signal.strainIsBelowBaseline ? baseline - value : value - baseline
            return signal.isProportional && baseline != 0 ? raw / baseline : raw
        }

        var detail: String {
            if signal.isProportional {
                return "\(Int((strainDelta * 100).rounded()))% below your usual"
            }
            let magnitude = abs(strainDelta)
            let formatted = signal == .skinTemperature
                ? String(format: "%.1f", magnitude)
                : "\(Int(magnitude.rounded()))"
            let direction = strainDelta >= 0 ? "above" : "below"
            return "\(formatted) \(signal.unit) \(direction) your usual"
        }
    }

    enum Status: String {
        /// Nothing unusual, or not enough signals to say.
        case clear = "No signs of strain"
        case minor = "Minor signs of strain"
        case major = "Major signs of strain"
    }

    struct Result: Equatable {
        let status: Status
        /// Every signal that had a baseline to be judged against, in descending order of departure.
        let readings: [Reading]
        /// How many signals could be judged at all.
        var signalsAvailable: Int { readings.count }
        /// The ones that departed far enough to count.
        var flagged: [Reading] { readings.filter { $0.level > .normal } }
    }

    /// Fewest judgeable signals before this says anything. One signal moving is noise; the whole
    /// value of a multi-signal detector is that it waits for agreement.
    static let minSignals = 2

    /// Total departure score at which the result turns `major`. Levels are 0/1/2 per signal, so 3 is
    /// "one strong plus one notable", or "one strong and something else stirring".
    static let majorScore = 3

    /// Score at which it turns `minor` — two notable signals, or a single strong one.
    static let minorScore = 2

    static func level(for signal: Signal, value: Double, baseline: Double) -> Level {
        let reading = Reading(signal: signal, value: value, baseline: baseline, level: .normal)
        let delta = reading.strainDelta
        guard delta.isFinite, delta > 0 else { return .normal }
        let thresholds = signal.thresholds
        if delta >= thresholds.strong { return .strong }
        if delta >= thresholds.notable { return .notable }
        return .normal
    }

    /// Judges a night. `values` and `baselines` need only overlap — a signal missing from either is
    /// simply not judged, which is how a jring (no temperature sensor, no breathing rate) still gets
    /// a useful answer from the three it does have.
    static func evaluate(values: [Signal: Double], baselines: [Signal: Double]) -> Result {
        var readings: [Reading] = []
        for signal in Signal.allCases {
            guard let value = values[signal], let baseline = baselines[signal],
                  value.isFinite, baseline.isFinite, baseline != 0 else { continue }
            readings.append(Reading(signal: signal, value: value, baseline: baseline,
                                    level: level(for: signal, value: value, baseline: baseline)))
        }
        readings.sort { $0.strainDelta > $1.strainDelta }

        // Below the floor there is nothing to corroborate, so the honest answer is "clear" rather
        // than a warning built on one reading.
        guard readings.count >= minSignals else {
            return Result(status: .clear, readings: readings)
        }

        let score = readings.reduce(0) { $0 + $1.level.rawValue }
        let status: Status
        switch score {
        case majorScore...: status = .major
        case minorScore...: status = .minor
        default: status = .clear   // a single notable signal on its own is noise
        }

        return Result(status: status, readings: readings)
    }

    /// One grounded sentence naming what moved, for the alert body and the coach.
    static func facts(_ result: Result) -> String {
        let flagged = result.flagged
        guard !flagged.isEmpty else { return "Overnight signals all sat close to your usual ranges." }
        let parts = flagged.map { "\($0.signal.title.lowercased()) \($0.detail)" }
        let list = parts.count == 1
            ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "Last night \(list). Several signals moving together like this often shows up a day "
            + "before you feel run down — though alcohol, heat, and a hard session the day before do "
            + "the same thing."
    }
}
