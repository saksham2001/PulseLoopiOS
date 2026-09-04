import Foundation

/// Status copy shared by the Vitals card and the detail header. Pure so the priority order
/// (period > pregnancy hint > confirmation > rise > countdown > phase) is unit-testable.
enum CycleCopy {
    /// The single most useful line for "where am I?" — countdown first, jargon last.
    static func headline(
        _ analysis: CycleAnalysis,
        hormonal: Bool,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: today)
        if analysis.phase == .menstruation {
            return "Period — day \(analysis.dayNumber)"
        }
        if analysis.flags.contains(.possiblePregnancy) {
            return "High temps for 18+ days"
        }
        if hormonal {
            return "Cycle day \(analysis.dayNumber)"
        }
        if analysis.flags.contains(.longCycle) {
            return "Long cycle — waiting for data"
        }
        if case let .confirmed(_, confirmedOn) = analysis.ovulation,
           CycleAnalyzer.daysBetween(confirmedOn, today, calendar: calendar) <= 3 {
            return "Ovulation likely confirmed"
        }
        if let prediction = analysis.nextPeriod {
            let delta = CycleAnalyzer.daysBetween(today, prediction.expected, calendar: calendar)
            switch delta {
            case 2...: return "Period in ~\(delta) days"
            case 1: return "Period likely tomorrow"
            case 0: return "Period due today"
            default: return "Period \(-delta) day\(delta == -1 ? "" : "s") late"
            }
        }
        if case .probable = analysis.ovulation {
            return "Temperature rising"
        }
        if let window = analysis.fertileWindow, window.contains(today) {
            return "Fertile window"
        }
        if analysis.completedCycles.isEmpty {
            return "Learning your cycle"
        }
        return "Cycle day \(analysis.dayNumber)"
    }

    /// "Day 14 · Luteal" — the second line under the headline.
    static func subtitle(_ analysis: CycleAnalysis, hormonal: Bool) -> String {
        hormonal ? "Day \(analysis.dayNumber) · analysis paused" : "Day \(analysis.dayNumber) · \(analysis.phase.label)"
    }

    /// Whether to surface the one-tap "My period started" button: around the predicted date
    /// (J-3 … onward), late without a prediction, or whenever nothing is known yet.
    static func shouldOfferPeriodStart(
        _ analysis: CycleAnalysis?,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let analysis else { return true }
        let today = calendar.startOfDay(for: today)
        if analysis.phase == .menstruation { return false }
        if let prediction = analysis.nextPeriod {
            return CycleAnalyzer.daysBetween(prediction.expected, today, calendar: calendar) >= -3
        }
        return analysis.dayNumber >= 21
    }

    /// Longer explanations for the flag banners on the detail screen.
    static func flagMessage(_ flag: CycleFlag) -> String {
        switch flag {
        case .possiblePregnancy:
            return "Your temperature has stayed high for 18+ days after ovulation with no period logged. "
                + "A pregnancy test may be worth considering."
        case .noThermalShiftYet:
            return "No temperature shift detected this cycle so far. Cycles without a clear shift happen "
                + "and are usually nothing to worry about."
        case .longCycle:
            return "This cycle is running unusually long. Period estimates are on hold until a temperature "
                + "shift is confirmed or a new period is logged."
        }
    }
}
