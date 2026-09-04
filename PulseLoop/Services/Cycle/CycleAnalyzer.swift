import Foundation

// MARK: - Inputs

/// Everything the analyzer needs to know about one calendar day. Built by `CycleService`
/// from user-logged `CycleDay` facts + `CycleBBTService` nightly temperatures.
struct CycleDayRecord: Equatable {
    var date: Date            // normalized startOfDay
    var temperature: Double?  // nightly BBT °C, nil = no usable night
    var isPeriod: Bool
    var isDisturbed: Bool

    /// A day whose temperature may participate in the thermal-shift analysis.
    var isValidTemperature: Bool { temperature != nil && !isDisturbed }
}

/// Why the user tracks. Changes display emphasis and how cautiously the fertile window is
/// drawn — never the underlying detection. `avoid` is deliberately supported but the UI
/// wraps it in explicit "this is not contraception" warnings.
enum CycleGoal: String, Codable, CaseIterable, Identifiable {
    case understand
    case conceive
    case avoid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .understand: return "Understand my cycle"
        case .conceive: return "Trying to conceive"
        case .avoid: return "Avoid pregnancy"
        }
    }
}

/// Tunable knobs of the detection. Defaults reflect *skin* temperature from a finger ring:
/// damped and noisier than the oral BBT the clinical Sensiplan rules were written for, so
/// the rise threshold is an engineering parameter — explicitly not the clinical 0.2 °C.
struct CycleAnalyzerConfig {
    /// Required excess of the confirming high over the coverline (on smoothed values).
    var risingDelta: Double = 0.15
    /// Consecutive valid low days that establish the coverline.
    var referenceDays: Int = 6
    /// Never look for a rise this early in the cycle (menstruation temps are unreliable).
    var minimumCycleDay: Int = 5
    /// Nightly temperature this far above the recent baseline suggests fever/disturbance.
    var disturbanceExcess: Double = 0.5
    /// Luteal-phase length bounds used when deriving the personal median.
    var lutealRange: ClosedRange<Int> = 10...16
    var defaultLutealDays: Int = 14
    /// `avoid` goal: widen the displayed fertile window by this many days on each side.
    var conservativeOpenLeadDays: Int = 2
    var conservativeCloseLagDays: Int = 1
}

// MARK: - Outputs

enum CyclePhase: String {
    case menstruation
    case follicular
    case fertile
    case luteal

    var label: String {
        switch self {
        case .menstruation: return "Period"
        case .follicular: return "Follicular"
        case .fertile: return "Fertile window"
        case .luteal: return "Luteal"
        }
    }
}

enum OvulationStatus: Equatable {
    case notDetected
    /// A rise is underway but the 3-over-6 rule hasn't fully confirmed yet.
    case probable(estimated: Date)
    /// The rule (with its exceptions) is satisfied.
    case confirmed(estimated: Date, confirmedOn: Date)

    var estimatedDate: Date? {
        switch self {
        case .notDetected: return nil
        case let .probable(estimated), let .confirmed(estimated, _): return estimated
        }
    }

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}

struct PeriodPrediction: Equatable {
    var expected: Date
    var earliest: Date
    var latest: Date
}

struct CompletedCycleSummary: Equatable, Identifiable {
    var start: Date
    var lengthDays: Int
    /// Days from cycle start to the estimated ovulation, when a shift was detected.
    var ovulationDayIndex: Int?

    var id: Date { start }
    var lutealDays: Int? { ovulationDayIndex.map { lengthDays - $0 } }
}

enum CycleFlag: Equatable {
    /// ≥ 18 days of sustained high temperature after a confirmed shift and no period —
    /// worth suggesting a pregnancy test, phrased neutrally.
    case possiblePregnancy
    /// Late in the cycle with no shift detected. Anovulatory cycles happen; say so honestly.
    case noThermalShiftYet
    /// Very long open cycle — stop pretending the numbers mean much.
    case longCycle
}

struct CycleAnalysis: Equatable {
    var cycleStart: Date
    var dayNumber: Int                       // 1-based, for `today`
    var phase: CyclePhase
    var coverline: Double?
    var ovulation: OvulationStatus
    var fertileWindow: ClosedRange<Date>?
    var nextPeriod: PeriodPrediction?
    var completedCycles: [CompletedCycleSummary]
    var typicalCycleLengthDays: Int?
    var lutealLengthDays: Int
    var flags: [CycleFlag]
    /// Most recent night that looks like fever/disturbance and isn't excluded yet — the UI
    /// offers a one-tap "exclude this night?" instead of expecting the user to remember.
    var disturbanceSuggestion: Date?

    /// The fertile span worth *drawing* (ring, chart, calendar). Until the shift is confirmed it
    /// is the full, deliberately wide `fertileWindow`. Once confirmed, that window is closed and
    /// only the days around the estimated ovulation carry meaning — sperm survival puts the real
    /// span at about five days before it — so the band shrinks to J−5…confirmation. On a long
    /// cycle (postpartum return, PCOS) a 75-day band said nothing. The analysis (`fertileWindow`,
    /// phase) is untouched: this is presentation only.
    func drawnFertileWindow(calendar: Calendar = .current) -> ClosedRange<Date>? {
        guard let fertileWindow else { return nil }
        guard case let .confirmed(estimated, _) = ovulation,
              let lead = calendar.date(byAdding: .day, value: -5, to: estimated) else { return fertileWindow }
        let start = max(fertileWindow.lowerBound, lead)
        return start <= fertileWindow.upperBound ? start...fertileWindow.upperBound : fertileWindow
    }
}

// MARK: - Analyzer

/// Pure, deterministic cycle analysis: Sensiplan's 3-over-6 mechanics (with both classical
/// exceptions) applied to *baseline-relative smoothed skin temperature*, plus next-period /
/// fertile-window estimation from personal history. No I/O, no clock reads, no globals —
/// everything comes in through the arguments so the whole thing is trivially unit-testable.
enum CycleAnalyzer {
    // MARK: Entry point

    /// `days` must be sorted by date and cover (at most) one record per day. Returns `nil`
    /// until the user has logged at least one period day at or before `today`.
    static func analyze(
        days: [CycleDayRecord],
        goal: CycleGoal,
        today: Date,
        calendar: Calendar = .current,
        config: CycleAnalyzerConfig = CycleAnalyzerConfig()
    ) -> CycleAnalysis? {
        let today = calendar.startOfDay(for: today)
        let starts = periodStarts(days: days, calendar: calendar).filter { $0 <= today }
        guard let currentStart = starts.last else { return nil }

        // History: each pair of consecutive starts closes a cycle; detect its shift for luteal stats.
        var completed: [CompletedCycleSummary] = []
        for (start, next) in zip(starts, starts.dropFirst()) {
            let length = daysBetween(start, next, calendar: calendar)
            let cycleRecords = records(days, from: start, before: next)
            let shift = detectShift(in: cycleRecords, cycleStart: start, calendar: calendar, config: config)
            let ovulationIndex = shift?.status.estimatedDate.map { daysBetween(start, $0, calendar: calendar) }
            completed.append(CompletedCycleSummary(start: start, lengthDays: length, ovulationDayIndex: ovulationIndex))
        }

        let currentRecords = records(days, from: currentStart, before: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        let shift = detectShift(in: currentRecords, cycleStart: currentStart, calendar: calendar, config: config)
        let dayNumber = daysBetween(currentStart, today, calendar: calendar) + 1

        let luteal = lutealLength(completed: completed, config: config)
        let typicalLength = typicalCycleLength(completed: completed)
        let prediction = nextPeriodPrediction(
            cycleStart: currentStart, ovulation: shift?.status, lutealDays: luteal,
            completed: completed, calendar: calendar
        )
        let window = fertileWindow(
            cycleStart: currentStart, ovulation: shift?.status, prediction: prediction,
            lutealDays: luteal, completed: completed, goal: goal, calendar: calendar, config: config
        )
        let phase = phase(
            today: today, records: currentRecords, ovulation: shift?.status,
            fertileWindow: window, calendar: calendar
        )

        return CycleAnalysis(
            cycleStart: currentStart,
            dayNumber: dayNumber,
            phase: phase,
            coverline: shift?.coverline,
            ovulation: shift?.status ?? .notDetected,
            fertileWindow: window,
            nextPeriod: prediction,
            completedCycles: completed,
            typicalCycleLengthDays: typicalLength,
            lutealLengthDays: luteal,
            flags: flags(dayNumber: dayNumber, records: currentRecords, shift: shift, calendar: calendar),
            disturbanceSuggestion: disturbanceSuggestion(records: currentRecords, shift: shift, config: config)
        )
    }

    // MARK: Cycle boundaries

    /// Derived day-1s: a period day counts as a new cycle start when the previous period day
    /// is more than 3 days earlier (so a spotting gap inside one period doesn't split it).
    static func periodStarts(days: [CycleDayRecord], calendar: Calendar = .current) -> [Date] {
        var starts: [Date] = []
        var previousPeriodDay: Date?
        for record in days where record.isPeriod {
            if let previous = previousPeriodDay {
                if daysBetween(previous, record.date, calendar: calendar) > 3 {
                    starts.append(record.date)
                }
            } else {
                starts.append(record.date)
            }
            previousPeriodDay = record.date
        }
        return starts
    }

    private static func records(_ days: [CycleDayRecord], from start: Date, before end: Date) -> [CycleDayRecord] {
        days.filter { $0.date >= start && $0.date < end }
    }

    // MARK: Thermal shift (Sensiplan 3-over-6 mechanics on smoothed values)

    struct ShiftResult: Equatable {
        var coverline: Double
        var firstHighDay: Date
        var status: OvulationStatus
    }

    /// Scan one cycle's records for a sustained temperature rise. Values are first smoothed
    /// (rolling median over the last 3 *valid* days) to tame the ring's 0.1 °C quantization,
    /// then the classical rule runs on the smoothed series:
    ///   - coverline = max of the 6 valid days before the first raised value;
    ///   - 3 consecutive valid values above the coverline, the 3rd ≥ coverline + delta;
    ///   - exception 1: a weak 3rd (above but < delta) is rescued by a 4th above the line;
    ///   - exception 2: one dip to/below the line among the 2nd/3rd is discarded, and the
    ///     replacement value must clear coverline + delta (exceptions never combine).
    static func detectShift(
        in cycleRecords: [CycleDayRecord],
        cycleStart: Date,
        calendar: Calendar = .current,
        config: CycleAnalyzerConfig = CycleAnalyzerConfig()
    ) -> ShiftResult? {
        let valid = cycleRecords.filter(\.isValidTemperature)
        guard valid.count > config.referenceDays else { return nil }
        let smoothed = smoothedValues(valid)

        var pending: ShiftResult?
        for candidate in config.referenceDays..<smoothed.count {
            let cycleDay = daysBetween(cycleStart, valid[candidate].date, calendar: calendar) + 1
            guard cycleDay >= config.minimumCycleDay else { continue }
            let coverline = smoothed[(candidate - config.referenceDays)..<candidate].max() ?? .infinity
            guard smoothed[candidate] > coverline else { continue }

            let estimated = calendar.date(byAdding: .day, value: -1, to: valid[candidate].date) ?? valid[candidate].date
            switch evaluateRise(candidate: candidate, coverline: coverline, values: smoothed, config: config) {
            case let .confirmed(index):
                return ShiftResult(
                    coverline: coverline,
                    firstHighDay: valid[candidate].date,
                    status: .confirmed(estimated: estimated, confirmedOn: valid[index].date)
                )
            case let .pending(highs):
                // Rise underway at the end of the data. One raised value is noise; from two
                // consecutive highs we surface it as "probable". Remember the earliest.
                if highs >= 2, pending == nil {
                    pending = ShiftResult(coverline: coverline, firstHighDay: valid[candidate].date,
                                          status: .probable(estimated: estimated))
                }
            case .failed:
                continue
            }
        }
        return pending
    }

    enum RiseEvaluation: Equatable {
        case confirmed(finalIndex: Int)
        case pending(highs: Int)
        case failed
    }

    /// Walk the values after a candidate first-high and apply the 3-high rule + exceptions.
    /// Internal (not private) so the exception mechanics are unit-testable without having to
    /// reverse-engineer sequences through the smoothing.
    static func evaluateRise(candidate: Int, coverline: Double, values: [Double], config: CycleAnalyzerConfig) -> RiseEvaluation {
        var highs = 1                    // values above the coverline collected so far
        var dipUsed = false              // exception 2 spent
        var requiresFullDelta = false    // after a dip, the closer must clear the full delta
        var index = candidate + 1

        while index < values.count {
            let value = values[index]
            if value > coverline {
                highs += 1
                let clearsDelta = value >= coverline + config.risingDelta
                if highs >= 3 {
                    if clearsDelta { return .confirmed(finalIndex: index) }
                    if requiresFullDelta { return .failed }   // exceptions don't combine
                    // Exception 1: weak 3rd — a 4th above the line (any amount) confirms.
                    if highs >= 4 { return .confirmed(finalIndex: index) }
                }
            } else {
                // A value on/below the line among the highs: one is forgiven (exception 2),
                // a second kills the candidate.
                if dipUsed { return .failed }
                dipUsed = true
                requiresFullDelta = true
            }
            index += 1
        }
        return .pending(highs: highs)
    }

    /// Rolling median over the last (up to) 3 valid values — quantization + outlier damping.
    static func smoothedValues(_ valid: [CycleDayRecord]) -> [Double] {
        valid.indices.map { index in
            let window = valid[max(0, index - 2)...index].compactMap(\.temperature)
            return CycleBBTService.median(window)
        }
    }

    // MARK: Personal statistics

    private static func lutealLength(completed: [CompletedCycleSummary], config: CycleAnalyzerConfig) -> Int {
        let lengths = completed.compactMap(\.lutealDays).suffix(6)
        guard !lengths.isEmpty else { return config.defaultLutealDays }
        let median = Int(CycleBBTService.median(lengths.map(Double.init)).rounded())
        return min(max(median, config.lutealRange.lowerBound), config.lutealRange.upperBound)
    }

    private static func typicalCycleLength(completed: [CompletedCycleSummary]) -> Int? {
        let lengths = completed.suffix(6).map(\.lengthDays)
        guard !lengths.isEmpty else { return nil }
        return Int(CycleBBTService.median(lengths.map(Double.init)).rounded())
    }

    // MARK: Predictions

    private static func nextPeriodPrediction(
        cycleStart: Date,
        ovulation: OvulationStatus?,
        lutealDays: Int,
        completed: [CompletedCycleSummary],
        calendar: Calendar
    ) -> PeriodPrediction? {
        // Confirmed ovulation pins the prediction: luteal length is the stable half of a cycle.
        if case let .confirmed(estimated, _) = ovulation,
           let expected = calendar.date(byAdding: .day, value: lutealDays, to: estimated) {
            return prediction(around: expected, spreadDays: 1, calendar: calendar)
        }
        // Otherwise fall back to cycle-length statistics; cycle 1 stays honestly silent.
        guard let typicalLength = typicalCycleLength(completed: completed),
              let expected = calendar.date(byAdding: .day, value: typicalLength, to: cycleStart) else { return nil }
        let lengths = completed.suffix(6).map { Double($0.lengthDays) }
        var spread = 2
        if lengths.count >= 3 {
            let mean = lengths.reduce(0, +) / Double(lengths.count)
            let std = (lengths.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lengths.count)).squareRoot()
            spread = max(2, Int(std.rounded()))
        }
        return prediction(around: expected, spreadDays: spread, calendar: calendar)
    }

    private static func prediction(around expected: Date, spreadDays: Int, calendar: Calendar) -> PeriodPrediction {
        PeriodPrediction(
            expected: expected,
            earliest: calendar.date(byAdding: .day, value: -spreadDays, to: expected) ?? expected,
            latest: calendar.date(byAdding: .day, value: spreadDays, to: expected) ?? expected
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func fertileWindow(
        cycleStart: Date,
        ovulation: OvulationStatus?,
        prediction: PeriodPrediction?,
        lutealDays: Int,
        completed: [CompletedCycleSummary],
        goal: CycleGoal,
        calendar: Calendar,
        config: CycleAnalyzerConfig
    ) -> ClosedRange<Date>? {
        // Opening, most personal rule available first:
        //  - Sensiplan minus-8: earliest first-high cycle day across past cycles − 8;
        //  - Döring fallback: shortest cycle length − 20;
        //  - no history: day 6.
        // Never earlier than day 6 (period + the first infertile days), except in `avoid`.
        let recent = completed.suffix(6)
        let earliestOvulationIndex = recent.compactMap(\.ovulationDayIndex).min()
        let shortest = recent.map(\.lengthDays).min()
        var openDayIndex: Int
        if let earliestOvulationIndex {
            openDayIndex = max(6, earliestOvulationIndex + 2 - 8)
        } else if let shortest {
            openDayIndex = max(6, shortest - 20)
        } else {
            openDayIndex = 6
        }

        var close: Date?
        switch ovulation {
        case let .confirmed(_, confirmedOn):
            // Sensiplan closes the fertile window on the evening of the confirming high day.
            close = confirmedOn
        case let .probable(estimated):
            close = calendar.date(byAdding: .day, value: 1, to: estimated)
        case .notDetected, nil:
            // No rise in sight: estimate ovulation backwards from the predicted period.
            guard let prediction else { return nil }
            close = calendar.date(byAdding: .day, value: -(lutealDays - 1), to: prediction.expected)
        }
        guard var closeDate = close else { return nil }

        if goal == .avoid {
            openDayIndex = max(1, openDayIndex - config.conservativeOpenLeadDays)
            if !(ovulation?.isConfirmed ?? false) {
                closeDate = calendar.date(byAdding: .day, value: config.conservativeCloseLagDays, to: closeDate) ?? closeDate
            }
        }

        guard let openDate = calendar.date(byAdding: .day, value: openDayIndex - 1, to: cycleStart),
              openDate <= closeDate else { return nil }
        return openDate...closeDate
    }

    // MARK: Phase & flags

    private static func phase(
        today: Date,
        records: [CycleDayRecord],
        ovulation: OvulationStatus?,
        fertileWindow: ClosedRange<Date>?,
        calendar: Calendar
    ) -> CyclePhase {
        if records.contains(where: { calendar.isDate($0.date, inSameDayAs: today) && $0.isPeriod }) {
            return .menstruation
        }
        // The infertile luteal phase only begins once the shift is *confirmed* — until then a
        // passed estimated window stays "fertile" (the safe reading, and the honest one).
        if case let .confirmed(_, confirmedOn) = ovulation, today > confirmedOn {
            return .luteal
        }
        if let fertileWindow, fertileWindow.contains(today) {
            return .fertile
        }
        if let fertileWindow, today > fertileWindow.upperBound, ovulation?.isConfirmed != true {
            return .fertile
        }
        return .follicular
    }

    private static func flags(
        dayNumber: Int,
        records: [CycleDayRecord],
        shift: ShiftResult?,
        calendar: Calendar
    ) -> [CycleFlag] {
        var flags: [CycleFlag] = []
        if case let .confirmed(estimated, _) = shift?.status,
           let shiftResult = shift,
           let lastValid = records.last(where: \.isValidTemperature),
           daysBetween(estimated, lastValid.date, calendar: calendar) >= 18,
           let temperature = lastValid.temperature,
           temperature > shiftResult.coverline {
            flags.append(.possiblePregnancy)
        }
        // Both banners say "still waiting for the shift", so a *confirmed* shift silences them:
        // the cycle has (re)started its luteal phase and the confirmation plus the period
        // countdown are the useful signal — postpartum return, PCOS and perimenopause routinely
        // run past day 60 before ovulating.
        if shift?.status.isConfirmed != true {
            if dayNumber > 60 {
                flags.append(.longCycle)
            } else if dayNumber >= 35 {
                flags.append(.noThermalShiftYet)
            }
        }
        return flags
    }

    /// The most recent unexcluded night whose raw temperature sits well above the recent
    /// baseline — likely fever/alcohol, so the UI can offer a one-tap exclusion. Skipped in
    /// the confirmed post-ovulatory phase, where a high plateau is expected and healthy.
    private static func disturbanceSuggestion(
        records: [CycleDayRecord],
        shift: ShiftResult?,
        config: CycleAnalyzerConfig
    ) -> Date? {
        guard let last = records.last(where: { $0.temperature != nil }), !last.isDisturbed else { return nil }
        if case .confirmed = shift?.status, last.date >= (shift?.firstHighDay ?? last.date) { return nil }
        let history = records
            .filter { $0.isValidTemperature && $0.date < last.date }
            .suffix(7)
            .compactMap(\.temperature)
        guard history.count >= 3, let temperature = last.temperature else { return nil }
        let baseline = CycleBBTService.median(history)
        return temperature > baseline + config.disturbanceExcess ? last.date : nil
    }

    // MARK: Helpers

    static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}
