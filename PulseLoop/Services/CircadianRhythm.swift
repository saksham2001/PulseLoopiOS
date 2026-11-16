import CoreGraphics
import Foundation
import SwiftData

// Circadian rhythm: where the anchors of a person's day (wake, meals, workouts, bedtime) usually
// fall, and how far the selected period drifted from that. Everything in `CircadianEngine` is a
// pure function over plain value inputs so each rule is unit-testable without SwiftData;
// `CircadianService` is the thin layer that gathers those inputs from the store.

// MARK: - Clock math

/// Time-of-day arithmetic on a 24-hour circle (minutes since local midnight, `0..<1440`).
enum CircadianMath {
    static let minutesPerDay: Double = 1440

    /// Wrap any minute value onto `0..<1440`.
    static func normalize(_ minutes: Double) -> Double {
        let r = minutes.truncatingRemainder(dividingBy: minutesPerDay)
        return r < 0 ? r + minutesPerDay : r
    }

    /// Mean time of day on the circle, so 11:30 PM and 12:30 AM average to midnight rather than
    /// noon. Nil when there are no samples or they cancel out (no meaningful centre).
    static func circularMean(_ minutes: [Double]) -> Double? {
        guard !minutes.isEmpty else { return nil }
        var x = 0.0, y = 0.0
        for m in minutes {
            let angle = m / minutesPerDay * 2 * .pi
            x += cos(angle)
            y += sin(angle)
        }
        guard hypot(x, y) / Double(minutes.count) > 1e-6 else { return nil }
        return normalize(atan2(y, x) / (2 * .pi) * minutesPerDay)
    }

    /// Shortest signed distance from `reference` to `value`, in `(-720, 720]`.
    /// Positive = later than the reference.
    static func signedDelta(_ value: Double, from reference: Double) -> Double {
        var d = normalize(value - reference)
        if d > minutesPerDay / 2 { d -= minutesPerDay }
        return d
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
    }
}

// MARK: - Vocabulary

/// A recurring point in the day that can have a "usual" time. Declared in day order.
enum CircadianAnchorKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case wake, breakfast, lunch, dinner, bed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wake: return "Wake"
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .bed: return "Bed"
        }
    }

    var symbol: String {
        switch self {
        case .wake: return "sun.max.fill"
        case .bed: return "moon.fill"
        case .breakfast, .lunch, .dinner: return "fork.knife"
        }
    }

    var isMeal: Bool { self == .breakfast || self == .lunch || self == .dinner }

    static let meals: [CircadianAnchorKind] = [.breakfast, .lunch, .dinner]

    /// Snacks have no rhythm worth tracking, so they map to nil.
    init?(mealType: MealType) {
        switch mealType {
        case .breakfast: self = .breakfast
        case .lunch: self = .lunch
        case .dinner: self = .dinner
        case .snack: return nil
        }
    }
}

/// Workouts get one of two icons: weights for strength, a runner for everything else.
enum CircadianWorkoutCategory: String, Codable, Equatable {
    case cardio, strength

    var symbol: String { self == .strength ? "dumbbell.fill" : "figure.run" }
    var label: String { self == .strength ? "Strength" : "Cardio" }

    static func from(type: String) -> CircadianWorkoutCategory {
        ActivityMeta.meta(type).type == "gym" ? .strength : .cardio
    }
}

enum CircadianScope: String, Equatable {
    case day, week, month, year

    init(_ range: SleepRangeKey) {
        switch range {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        case .year: self = .year
        }
    }
}

/// The days being looked at, as inclusive start-of-day bounds.
struct CircadianPeriod: Equatable {
    let scope: CircadianScope
    let start: Date
    let end: Date
}

// MARK: - Engine inputs

struct CircadianSleepSample: Equatable {
    /// Waking day the session belongs to.
    let day: Date
    let start: Date
    let end: Date
    let minutes: Int
}

struct CircadianMealSample: Equatable {
    let day: Date
    let time: Date
    let kind: CircadianAnchorKind
}

struct CircadianWorkoutSample: Equatable {
    let start: Date
    let durationMinutes: Double
    let category: CircadianWorkoutCategory
    let label: String
}

// MARK: - Engine output

struct CircadianAnchor: Identifiable, Equatable {
    let kind: CircadianAnchorKind
    /// Average time over the baseline; nil until there is enough history.
    let usualMinutes: Double?
    /// The selected day's time, or the selected period's average.
    let periodMinutes: Double?

    var id: String { kind.rawValue }

    /// Positive = later than usual. Nil unless both sides are known.
    var deltaMinutes: Double? {
        guard let usualMinutes, let periodMinutes else { return nil }
        return CircadianMath.signedDelta(periodMinutes, from: usualMinutes)
    }

    /// Where the anchor sits on the dial: its usual time, falling back to the period's own time.
    var displayMinutes: Double { usualMinutes ?? periodMinutes ?? 0 }
}

struct CircadianWorkout: Identifiable, Equatable {
    let id: Int
    let startMinutes: Double
    let durationMinutes: Double
    let category: CircadianWorkoutCategory
    let label: String
    /// True for an aggregate range, where the span is the period's typical workout time.
    let isTypical: Bool
}

struct CircadianSnapshot: Equatable {
    let scope: CircadianScope
    let anchors: [CircadianAnchor]
    let workouts: [CircadianWorkout]
    let headline: String
    let subline: String
    /// Not enough nights yet to know the person's usual wake and bedtime.
    let isLearning: Bool

    /// Nothing worth drawing — the tile hides.
    var isEmpty: Bool { anchors.isEmpty && workouts.isEmpty }

    func anchor(_ kind: CircadianAnchorKind) -> CircadianAnchor? { anchors.first { $0.kind == kind } }

    /// The sleep window to shade: usual bed → usual wake, or the period's own when no usual exists.
    var sleepWindow: (bed: Double, wake: Double)? {
        guard let bed = anchor(.bed), let wake = anchor(.wake) else { return nil }
        if let b = bed.usualMinutes, let w = wake.usualMinutes { return (b, w) }
        if let b = bed.periodMinutes, let w = wake.periodMinutes { return (b, w) }
        return nil
    }

    var hasDrift: Bool { anchors.contains { $0.deltaMinutes != nil } }
}

// MARK: - Engine

enum CircadianEngine {
    /// "Usual" is the average over this many days before the period being viewed.
    static let baselineDays = 30
    /// Fewer samples than this is not a habit yet — one or two nights must not define "usual".
    static let minBaselineSamples = 5
    /// A day's longest session only counts as the night if it is at least this long, so a lone
    /// nap on a night the ring missed never becomes that day's wake and bedtime.
    static let minNightMinutes = 180
    /// Drift smaller than this reads as "on rhythm".
    static let driftThreshold: Double = 30
    /// Smart mode: an event is a habit when it happened on 4 of the last 7 days (new habits show
    /// up within a week) or 10 of the last 28 (a missed week does not drop an established one).
    static let recentWindow = (days: 7, hits: 4)
    static let longWindow = (days: 28, hits: 10)
    static let minWorkoutMinutes: Double = 5

    static func snapshot(
        period: CircadianPeriod,
        sleep: [CircadianSleepSample],
        meals: [CircadianMealSample],
        workouts: [CircadianWorkoutSample],
        prefs: CircadianPrefs,
        nutritionEnabled: Bool,
        calendar: Calendar = .current
    ) -> CircadianSnapshot {
        let periodStart = calendar.startOfDay(for: period.start)
        let periodEnd = calendar.startOfDay(for: period.end)
        let baselineStart = calendar.date(byAdding: .day, value: -baselineDays, to: periodStart) ?? periodStart
        let inBaseline: (Date) -> Bool = { $0 >= baselineStart && $0 < periodStart }
        let inPeriod: (Date) -> Bool = { $0 >= periodStart && $0 <= periodEnd }
        // An average over a range needs at least two days; a single day is its own value.
        let minPeriodSamples = period.scope == .day ? 1 : 2

        func anchor(_ kind: CircadianAnchorKind, _ byDay: [Date: Double]) -> CircadianAnchor? {
            let baseline = byDay.filter { inBaseline($0.key) }.map(\.value)
            let current = byDay.filter { inPeriod($0.key) }.map(\.value)
            let usual = baseline.count >= minBaselineSamples ? CircadianMath.circularMean(baseline) : nil
            let now = current.count >= minPeriodSamples ? CircadianMath.circularMean(current) : nil
            guard usual != nil || now != nil else { return nil }
            return CircadianAnchor(kind: kind, usualMinutes: usual, periodMinutes: now)
        }

        // Sleep: one night per waking day, taken from that day's longest session so naps never
        // move the anchors.
        var nights: [Date: CircadianSleepSample] = [:]
        for sample in sleep where sample.minutes >= minNightMinutes {
            let day = calendar.startOfDay(for: sample.day)
            if let existing = nights[day], existing.minutes >= sample.minutes { continue }
            nights[day] = sample
        }
        let wakeByDay = nights.mapValues { CircadianMath.minuteOfDay($0.end, calendar: calendar) }
        let bedByDay = nights.mapValues { CircadianMath.minuteOfDay($0.start, calendar: calendar) }
        let baselineNights = nights.keys.filter(inBaseline).count

        var anchors: [CircadianAnchor] = []
        if let wake = anchor(.wake, wakeByDay) { anchors.append(wake) }
        if let bed = anchor(.bed, bedByDay) { anchors.append(bed) }

        // Meals: the first entry of each type per day.
        if nutritionEnabled && prefs.showMeals {
            for kind in CircadianAnchorKind.meals {
                var byDay: [Date: Double] = [:]
                var firstTime: [Date: Date] = [:]
                for meal in meals where meal.kind == kind {
                    let day = calendar.startOfDay(for: meal.day)
                    if let existing = firstTime[day], existing <= meal.time { continue }
                    firstTime[day] = meal.time
                    byDay[day] = CircadianMath.minuteOfDay(meal.time, calendar: calendar)
                }
                let included = prefs.mealSelection == .manual
                    ? prefs.includesMeal(kind)
                    : isRegular(days: Set(byDay.keys), endingOn: periodEnd, calendar: calendar)
                if included, let meal = anchor(kind, byDay) { anchors.append(meal) }
            }
        }
        anchors.sort { order($0.kind) < order($1.kind) }

        // Workouts: shown at the time they happened, never scored against a usual time.
        var spans: [CircadianWorkout] = []
        if prefs.showWorkouts {
            let usable = workouts.filter { $0.durationMinutes >= minWorkoutMinutes }
            let workoutDays = Set(usable.map { calendar.startOfDay(for: $0.start) })
            let included = prefs.workoutSelection == .manual
                || isRegular(days: workoutDays, endingOn: periodEnd, calendar: calendar)
            let current = usable
                .filter { inPeriod(calendar.startOfDay(for: $0.start)) }
                .sorted { $0.start < $1.start }
            if included {
                if period.scope == .day {
                    spans = current.enumerated().map { index, w in
                        CircadianWorkout(
                            id: index,
                            startMinutes: CircadianMath.minuteOfDay(w.start, calendar: calendar),
                            durationMinutes: w.durationMinutes, category: w.category, label: w.label, isTypical: false)
                    }
                } else if current.count >= 2,
                          let start = CircadianMath.circularMean(current.map { CircadianMath.minuteOfDay($0.start, calendar: calendar) }) {
                    let strength = current.filter { $0.category == .strength }.count
                    let category: CircadianWorkoutCategory = strength * 2 > current.count ? .strength : .cardio
                    let duration = current.map(\.durationMinutes).reduce(0, +) / Double(current.count)
                    spans = [CircadianWorkout(
                        id: 0, startMinutes: start, durationMinutes: duration,
                        category: category, label: "Workout", isTypical: true)]
                }
            }
        }

        // Learning = too few nights to say what "usual" is. A single day needs them before it; a
        // range that itself holds enough nights is past learning even with nothing earlier to
        // compare against (it shows its own typical times instead).
        let hasSleepUsual = anchors.contains { !$0.kind.isMeal && $0.usualMinutes != nil }
        let periodNights = nights.keys.filter(inPeriod).count
        let knownNights = period.scope == .day ? baselineNights : max(baselineNights, periodNights)
        let isLearning = !hasSleepUsual && knownNights < minBaselineSamples
        let copy = summary(
            scope: period.scope, anchors: anchors, isLearning: isLearning,
            nightsNeeded: max(1, minBaselineSamples - knownNights))
        return CircadianSnapshot(
            scope: period.scope, anchors: anchors, workouts: spans,
            headline: copy.headline, subline: copy.subline, isLearning: isLearning)
    }

    /// Whether an event is a habit as of `end`, tolerant of gaps (see `recentWindow`/`longWindow`).
    static func isRegular(days: Set<Date>, endingOn end: Date, calendar: Calendar = .current) -> Bool {
        let endDay = calendar.startOfDay(for: end)
        func hits(_ window: Int) -> Int {
            guard let from = calendar.date(byAdding: .day, value: -(window - 1), to: endDay) else { return 0 }
            return days.filter { $0 >= from && $0 <= endDay }.count
        }
        return hits(recentWindow.days) >= recentWindow.hits || hits(longWindow.days) >= longWindow.hits
    }

    private static func order(_ kind: CircadianAnchorKind) -> Int {
        CircadianAnchorKind.allCases.firstIndex(of: kind) ?? 0
    }

    /// The one-line read of the dial plus its supporting line. Both are drawn inside the dial, so
    /// each stays short enough for one line there.
    static func summary(
        scope: CircadianScope, anchors: [CircadianAnchor], isLearning: Bool, nightsNeeded: Int
    ) -> (headline: String, subline: String) {
        let deltas: [(kind: CircadianAnchorKind, delta: Double)] = anchors.compactMap { a in
            a.deltaMinutes.map { (a.kind, $0) }
        }
        guard !deltas.isEmpty else {
            if isLearning {
                return ("Learning your rhythm", "Needs \(nightsNeeded) more night\(nightsNeeded == 1 ? "" : "s")")
            }
            if scope != .day, anchors.contains(where: { $0.periodMinutes != nil }) {
                return ("Your typical day", scope == .year ? "Past year's average" : "No earlier baseline yet")
            }
            if anchors.contains(where: { $0.usualMinutes != nil }) {
                return ("Your usual day", "Nothing recorded yet")
            }
            return ("Your day", "")
        }

        let off = deltas.filter { abs($0.delta) >= driftThreshold }
        let within = deltas.count - off.count
        let threshold = Int(driftThreshold)
        let tally = "\(within) of \(deltas.count) within \(threshold) min"
        if off.isEmpty {
            return ("On rhythm", deltas.count == 1 ? "Within \(threshold) min of usual" : "All \(deltas.count) within \(threshold) min")
        }

        // Everything moved the same way: the whole day (or period) shifted.
        let mean = deltas.map(\.delta).reduce(0, +) / Double(deltas.count)
        let allLater = deltas.allSatisfy { $0.delta > -10 }
        let allEarlier = deltas.allSatisfy { $0.delta < 10 }
        if deltas.count >= 2, abs(mean) >= driftThreshold, allLater || allEarlier {
            let later = mean > 0
            let head = scope == .day ? (later ? "Running late" : "Running early") : (later ? "Shifted later" : "Shifted earlier")
            return (head, "About \(CircadianFormat.duration(abs(mean))) \(later ? "later" : "earlier")")
        }

        let sleepOff = off.filter { !$0.kind.isMeal }
        let mealsOff = off.filter { $0.kind.isMeal }
        let hasMeals = deltas.contains { $0.kind.isMeal }
        let hasSleep = deltas.contains { !$0.kind.isMeal }

        if sleepOff.isEmpty {
            let head: String
            switch direction(mealsOff.map(\.delta)) {
            case .later: head = "Meals ran late"
            case .earlier: head = "Meals ran early"
            case .mixed: head = "Meals off schedule"
            }
            return (head, hasSleep ? "Sleep held steady" : tally)
        }
        if mealsOff.isEmpty {
            let head: String
            if sleepOff.count == 1, let only = sleepOff.first {
                let late = only.delta > 0
                head = only.kind == .bed
                    ? (late ? "Bedtime ran late" : "Bedtime ran early")
                    : (late ? "Wake-up ran late" : "Wake-up ran early")
            } else {
                switch direction(sleepOff.map(\.delta)) {
                case .later: head = "Sleep shifted later"
                case .earlier: head = "Sleep shifted earlier"
                case .mixed: head = "Sleep off schedule"
                }
            }
            return (head, hasMeals ? "Meals held steady" : tally)
        }
        return ("Off rhythm", tally)
    }

    private enum Direction { case later, earlier, mixed }

    private static func direction(_ deltas: [Double]) -> Direction {
        if deltas.allSatisfy({ $0 > 0 }) { return .later }
        if deltas.allSatisfy({ $0 < 0 }) { return .earlier }
        return .mixed
    }
}

// MARK: - Formatting

enum CircadianFormat {
    /// "22m", "1h", "1h 5m".
    static func duration(_ minutes: Double) -> String {
        let total = Int(abs(minutes).rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "+50m" / "−22m" — the compact label drawn next to a drift bar.
    static func signed(_ delta: Double) -> String {
        let rounded = delta.rounded()
        if rounded == 0 { return "0m" }
        return (rounded > 0 ? "+" : "\u{2212}") + duration(rounded)
    }

    /// "50m later" / "22m earlier" / "On time".
    static func words(_ delta: Double) -> String {
        let rounded = delta.rounded()
        if rounded == 0 { return "On time" }
        return "\(duration(rounded)) \(rounded > 0 ? "later" : "earlier")"
    }

    /// Spoken form for VoiceOver: "50 minutes later than usual".
    static func spoken(_ delta: Double) -> String {
        let total = Int(abs(delta).rounded())
        if total == 0 { return "on time" }
        let h = total / 60, m = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        return "\(parts.joined(separator: " ")) \(delta > 0 ? "later" : "earlier") than usual"
    }

    /// Minute-of-day → "7:03 AM", matching `SleepFormat.clockTime`.
    static func clock(_ minutes: Double) -> String {
        let total = Int(CircadianMath.normalize(minutes).rounded()) % 1440
        let h24 = total / 60, m = total % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12):\(String(format: "%02d", m)) \(h24 < 12 ? "AM" : "PM")"
    }
}

// MARK: - Coach hand-off

extension CircadianSnapshot {
    /// Up to three questions to open a coach chat with, led by whatever stands out in the dial.
    var coachPrompts: [String] {
        if isLearning || !hasDrift {
            return [
                "What is a circadian rhythm and why does it matter?",
                "How do I build a steady sleep schedule?",
                "How does meal timing affect my sleep?"
            ]
        }
        var prompts: [String] = []
        let off = anchors.filter { abs($0.deltaMinutes ?? 0) >= CircadianEngine.driftThreshold }
        if let bed = off.first(where: { $0.kind == .bed }), let delta = bed.deltaMinutes {
            prompts.append(delta > 0 ? "How can I get to bed earlier?" : "Is going to bed earlier than usual a problem?")
        }
        if let wake = off.first(where: { $0.kind == .wake }), let delta = wake.deltaMinutes {
            prompts.append(delta > 0 ? "How do I get back to my usual wake time?" : "Why am I waking earlier than usual?")
        }
        if let meal = off.first(where: { $0.kind.isMeal }), let delta = meal.deltaMinutes {
            prompts.append(delta > 0
                ? "How does eating later than usual affect my sleep?"
                : "Does eating earlier than usual change my sleep?")
        }
        if off.isEmpty { prompts.append("What helps me stay on rhythm?") }
        prompts.append("How consistent has my daily rhythm been lately?")
        prompts.append("What should I adjust tomorrow to stay on rhythm?")
        return Array(prompts.prefix(3))
    }

    /// The dial's facts as one line for the coach. Sent with the question but not shown in the
    /// chat bubble — the coach's own tools do not expose bedtimes or wake times.
    var coachContext: String {
        let scopeText: String
        switch scope {
        case .day: scopeText = "the selected day"
        case .week: scopeText = "the past week's average"
        case .month: scopeText = "the past month's average"
        case .year: scopeText = "the past year's average"
        }
        var facts: [String] = anchors.map { a in
            var text = a.kind.label.lowercased()
            if let now = a.periodMinutes { text += " \(CircadianFormat.clock(now))" } else { text += " not recorded" }
            if let usual = a.usualMinutes { text += " (usual \(CircadianFormat.clock(usual))" } else { text += " (no usual yet" }
            if let delta = a.deltaMinutes { text += ", \(CircadianFormat.words(delta).lowercased())" }
            return text + ")"
        }
        facts += workouts.map { w in
            let name = w.isTypical ? "typical workout" : w.label.lowercased()
            return "\(name) at \(CircadianFormat.clock(w.startMinutes)) for \(CircadianFormat.duration(w.durationMinutes))"
        }
        return "Circadian rhythm from the Sleep tab, for \(scopeText): \(facts.joined(separator: "; ")). "
            + "\"Usual\" is the average over the \(CircadianEngine.baselineDays) days before."
    }
}

// MARK: - Dial geometry

/// Maps time of day onto the dial. Kept free of SwiftUI so the mapping can be unit-tested.
struct CircadianDialGeometry: Equatable {
    enum Shape: Equatable {
        /// 24 hours across the top half-circle, starting at the app's 4 AM day boundary.
        case semicircle
        /// 24 hours around the whole circle: noon at the top, midnight at the bottom.
        case full
    }

    let shape: Shape

    /// Where the semicircle's day begins — the same 4 AM flip `SleepService.dayReferenceNight` uses.
    static let dayStartMinutes: Double = 240

    /// Radians of arc per minute of time.
    var sweepPerMinute: Double {
        (shape == .semicircle ? Double.pi : 2 * Double.pi) / CircadianMath.minutesPerDay
    }

    /// Angle in screen space (0 = right, growing clockwise because y points down).
    func screenAngle(_ minutes: Double) -> Double {
        switch shape {
        case .semicircle:
            return Double.pi + CircadianMath.normalize(minutes - Self.dayStartMinutes) * sweepPerMinute
        case .full:
            return -Double.pi / 2 + (minutes - 720) * sweepPerMinute
        }
    }

    func point(_ minutes: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = screenAngle(minutes)
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    /// Arc pieces covering `start` → `end` going forward in time. The semicircle splits a span
    /// that crosses its 4 AM seam (overnight sleep) into a right-hand and a left-hand piece.
    func arcs(from start: Double, to end: Double) -> [(startAngle: Double, sweep: Double)] {
        let length = CircadianMath.normalize(end - start)
        guard length > 0 else { return [] }
        switch shape {
        case .full:
            return [(screenAngle(start), length * sweepPerMinute)]
        case .semicircle:
            let offset = CircadianMath.normalize(start - Self.dayStartMinutes)
            let toSeam = CircadianMath.minutesPerDay - offset
            if length <= toSeam { return [(screenAngle(start), length * sweepPerMinute)] }
            return [
                (screenAngle(start), toSeam * sweepPerMinute),
                (Double.pi, (length - toSeam) * sweepPerMinute)
            ]
        }
    }

    /// Nudge markers that would overlap apart, each by half the shortfall, so two events close in
    /// time (wake and breakfast) stay individually readable. Order is preserved.
    static func spread(_ minutes: [Double], minGap: Double) -> [Double] {
        guard minutes.count > 1, minGap > 0 else { return minutes }
        var linear = minutes.map { CircadianMath.normalize($0 - dayStartMinutes) }
        let order = linear.indices.sorted { linear[$0] < linear[$1] }
        for _ in 0..<12 {
            var moved = false
            for i in 1..<order.count {
                let a = order[i - 1], b = order[i]
                let gap = linear[b] - linear[a]
                if gap < minGap - 0.01 {
                    let push = (minGap - gap) / 2
                    linear[a] -= push
                    linear[b] += push
                    moved = true
                }
            }
            // Keep everything on the dial; the next pass re-opens any gap this closes.
            if let first = order.first, linear[first] < 0 { linear[first] = 0 }
            if let last = order.last, linear[last] > CircadianMath.minutesPerDay - 1 {
                linear[last] = CircadianMath.minutesPerDay - 1
            }
            if !moved { break }
        }
        return linear.map { CircadianMath.normalize($0 + dayStartMinutes) }
    }

    /// Greedy label de-collision: keep each rect, in priority order, unless it hits one already kept.
    static func keepLabels(_ rects: [CGRect]) -> [Bool] {
        var kept: [CGRect] = []
        return rects.map { rect in
            if kept.contains(where: { $0.intersects(rect) }) { return false }
            kept.append(rect)
            return true
        }
    }
}

// MARK: - Store access

@MainActor
enum CircadianService {
    /// The period the Sleep page is showing: the selected day, or the range the page's summary covers.
    static func period(range: SleepRangeKey, day: Date, summary: SleepRangeSummary, calendar: Calendar = .current) -> CircadianPeriod {
        if range == .day {
            let start = calendar.startOfDay(for: day)
            return CircadianPeriod(scope: .day, start: start, end: start)
        }
        return CircadianPeriod(
            scope: CircadianScope(range),
            start: calendar.startOfDay(for: summary.start), end: calendar.startOfDay(for: summary.end))
    }

    static func snapshot(
        period: CircadianPeriod,
        context: ModelContext,
        prefs: CircadianPrefs? = nil,
        nutritionEnabled: Bool? = nil,
        calendar: Calendar = .current
    ) -> CircadianSnapshot {
        // Nil means "the user's current settings" (resolved here, on the main actor).
        let prefs = prefs ?? CircadianPrefsStore.shared.prefs
        let nutritionEnabled = nutritionEnabled ?? NutritionPrefsStore.shared.prefs.masterEnabled
        // Everything the engine can use: the baseline before the period through the period's last day.
        let from = calendar.date(byAdding: .day, value: -(CircadianEngine.baselineDays + 1), to: period.start) ?? period.start
        let until = calendar.date(byAdding: .day, value: 1, to: period.end) ?? period.end

        let sleep = SleepRepository.sessions(context: context)
            .filter { $0.totalMinutes > 0 && $0.date >= from && $0.date < until }
            .map { CircadianSleepSample(day: $0.date, start: $0.startAt, end: $0.endAt, minutes: $0.totalMinutes) }

        let meals: [CircadianMealSample] = nutritionEnabled && prefs.showMeals
            ? NutritionRepository.entries(from: from, to: until, context: context).compactMap { entry in
                CircadianAnchorKind(mealType: entry.mealType).map {
                    CircadianMealSample(day: entry.date, time: entry.timestamp, kind: $0)
                }
            }
            : []

        let workouts: [CircadianWorkoutSample] = prefs.showWorkouts
            ? ActivityRepository.sessions(context: context).compactMap { session in
                guard session.status == .finished, let ended = session.endedAt,
                      session.startedAt >= from, session.startedAt < until else { return nil }
                let seconds = ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds
                return CircadianWorkoutSample(
                    start: session.startedAt, durationMinutes: max(0, seconds / 60),
                    category: .from(type: session.type), label: ActivityMeta.label(session.type))
            }
            : []

        return CircadianEngine.snapshot(
            period: period, sleep: sleep, meals: meals, workouts: workouts,
            prefs: prefs, nutritionEnabled: nutritionEnabled, calendar: calendar)
    }
}
