import Foundation

/// How long the ring has left, from its own battery history (Android issue #65).
///
/// A least-squares fit — but over the **current discharge run only**, not the whole window. A 7-day
/// window almost always contains a charge, and a line through "40 % falling, then 100 %, then falling
/// again" has a slope that is an artefact of when the user plugged in: it can come out flat or positive,
/// and either way describes nothing. The run since the last charge is the only stretch whose slope is a
/// drain rate.
///
/// Deliberately conservative about saying anything at all. A number on screen is read as a promise, and
/// battery life is something people plan a trip around, so the estimate is withheld unless the fit has
/// enough samples, enough elapsed time and enough of a fall to mean something.
enum BatteryProjection {
    /// One battery reading.
    struct Sample: Equatable {
        let timestamp: Date
        let percent: Double
    }

    struct Estimate: Equatable {
        /// How fast it is falling now (positive = draining).
        let percentPerHour: Double
        /// Time until empty at that rate, from the last reading.
        let hoursRemaining: Double

        /// "2d 6h" / "18h" / "45m" — the shape a runtime is actually read in.
        var label: String {
            let totalMinutes = max(0, Int(hoursRemaining * 60))
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            let minutes = totalMinutes % 60
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h" }
            return "\(minutes)m"
        }
    }

    /// A rise of this many points or more is a charge — the boundary of the current discharge run. Ring
    /// battery reporting is coarse (whole percent; some firmware reports in 5 % steps), so a 1–2 point
    /// wobble at a plateau is normal and must not split a run.
    static let chargeRisePoints = 3.0

    /// Below these the fit is describing noise rather than a trend.
    static let minSamples = 4
    static let minSpanHours = 1.5
    static let minFallPoints = 2.0

    /// Below this the slope is reporting granularity, not a discharge rate. The gates above are all about
    /// the run's *shape* and none bounds how slow it may be: 5 %-step firmware read over a week clears
    /// every one with 80 → 75 — 0.03 %/h, "about 104d left". 0.2 %/h is ~21 days from full, past anything
    /// a ring claims, so a real slow drain still gets an answer.
    static let minDrainPercentPerHour = 0.2

    /// The samples since the ring was last charged, oldest first. The whole list when no charge is
    /// visible — the common case for a 24 h window, and why 24 h usually has an estimate while 7 d may not.
    static func currentDischargeRun(_ samples: [Sample]) -> [Sample] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 2 else { return ordered }
        var runStart = 0
        for i in 1..<ordered.count where ordered[i].percent - ordered[i - 1].percent >= chargeRisePoints {
            runStart = i
        }
        return Array(ordered[runStart...])
    }

    /// The remaining runtime, or nil when the data can't support one — "not enough data yet" is honest,
    /// and a wrong runtime is worse than none.
    static func estimate(_ samples: [Sample]) -> Estimate? {
        let run = currentDischargeRun(samples)
        guard run.count >= minSamples, let first = run.first, let last = run.last else { return nil }
        let spanHours = last.timestamp.timeIntervalSince(first.timestamp) / 3600
        guard spanHours >= minSpanHours, first.percent - last.percent >= minFallPoints else { return nil }

        // Least squares against hours since the run's start, so the slope is directly %/hour.
        let xs = run.map { $0.timestamp.timeIntervalSince(first.timestamp) / 3600 }
        let ys = run.map(\.percent)
        let n = Double(run.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - meanX) * (y - meanY)
            sxx += (x - meanX) * (x - meanX)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        guard slope < 0 else { return nil }   // flat or rising: no depletion to project

        let drain = -slope
        guard drain >= minDrainPercentPerHour, last.percent > 0 else { return nil }
        return Estimate(percentPerHour: drain, hoursRemaining: last.percent / drain)
    }

    /// Gridline instants across `start...end` for the chart behind the line: local midnights when the
    /// window spans more than two days, otherwise every `hourStep` hours on the hour (00/06/12/18). A grid
    /// at arbitrary offsets answers neither "which day" nor "which hour". Every mark lies in `(start, end]`.
    static func gridlines(start: Date, end: Date, calendar: Calendar = .current, hourStep: Int = 6) -> [Date] {
        guard end > start else { return [] }
        var marks: [Date] = []
        if end.timeIntervalSince(start) > 48 * 3600 {
            var day = calendar.startOfDay(for: start)
            while let next = calendar.date(byAdding: .day, value: 1, to: day), next <= end {
                marks.append(next)
                day = next
            }
        } else {
            guard var mark = calendar.dateInterval(of: .hour, for: start)?.start else { return [] }
            while calendar.component(.hour, from: mark) % hourStep != 0 || mark <= start {
                guard let next = calendar.date(byAdding: .hour, value: 1, to: mark) else { return marks }
                mark = next
            }
            while mark <= end {
                marks.append(mark)
                guard let next = calendar.date(byAdding: .hour, value: hourStep, to: mark) else { break }
                mark = next
            }
        }
        return marks
    }
}
