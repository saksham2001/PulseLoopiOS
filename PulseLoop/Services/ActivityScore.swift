import Foundation

/// One scored signal within a day's activity score, in the same shape the sleep score uses.
struct ActivityContributor: Equatable {
    enum Kind: String, CaseIterable {
        case steps
        case activeMinutes
        case energy
        case regularity

        var title: String {
            switch self {
            case .steps: return "Steps"
            case .activeMinutes: return "Active minutes"
            case .energy: return "Active energy"
            case .regularity: return "Movement through the day"
            }
        }

        var maxPoints: Double {
            switch self {
            case .steps: return 35
            case .activeMinutes: return 30
            case .energy: return 20
            case .regularity: return 15
            }
        }
    }

    let kind: Kind
    let earned: Double
    let maxPoints: Double
    let detail: String
}

enum ActivityBand: String, CaseIterable {
    case restful = "Restful"
    case light = "Light"
    case active = "Active"
    case veryActive = "Very active"

    init(score: Int) {
        switch score {
        case 85...: self = .veryActive
        case 70..<85: self = .active
        case 45..<70: self = .light
        default: self = .restful
        }
    }
}

struct ActivityScoreResult: Equatable {
    let score: Int
    let band: ActivityBand
    let contributors: [ActivityContributor]
    /// Fraction of the full 100-point picture this rested on.
    let coverage: Double
    let algorithmVersion: Int
}

/// Everything the score reads about one day. A plain struct so the maths stays pure and testable —
/// `ActivityScoreService` does the fetching.
struct ActivityScoreInputs: Equatable {
    let steps: Int?
    let activeMinutes: Int?
    let activeEnergyKcal: Double?
    /// Hours between `regularityWindow` that contained at least `regularityStepFloor` steps, and how
    /// many hours were observable at all. nil when the ring reports no intraday buckets.
    let activeHours: Int?
    let observableHours: Int?

    let stepsGoal: Int
    let activeMinutesGoal: Int
    let energyGoal: Int
}

/// A daily movement score, 0–100 — PulseLoop's equivalent of Oura's Activity Score or Ultrahuman's
/// Movement Index.
///
/// Every contributor is measured **against the user's own goals**, not a population target, because
/// the goals already exist and are already editable. A score built on a fixed 10,000 steps would be
/// telling a marathoner and a recovering patient the same thing.
///
/// Missing signals leave the denominator rather than scoring zero — the rule the sleep score and
/// readiness both follow, and what lets one number mean the same thing on a ring that reports
/// intraday buckets and one that doesn't.
enum ActivityScore {
    static let algorithmVersion = 1

    /// A score is only produced when at least this many points were available.
    static let minAvailablePoints: Double = 50

    /// Steps within an hour that count it as an "active" hour. Matches the widely-used 250-per-hour
    /// convention (Apple's stand-hour analogue) rather than inventing a threshold.
    static let regularityStepFloor = 250

    /// The window regularity is judged over: 08:00–22:00 local. Hours outside it are not counted
    /// against you, since nobody should be scored for not walking at 4 a.m.
    static let regularityWindow = 8..<22

    /// Goal progress → points.
    ///
    /// Full marks at goal, 65 % at 60 % of goal, linear to zero below that. **Exceeding a goal is
    /// never penalised**: overreaching is what training load is for, and a movement score that
    /// docked you for a long hike would be actively misleading.
    static func goalScore(actual: Double, goal: Double, points: Double) -> Double {
        guard goal > 0, actual.isFinite, actual >= 0 else { return 0 }
        let fraction = actual / goal
        if fraction >= 1 { return points }
        if fraction >= 0.6 {
            return points * (0.65 + 0.35 * ((fraction - 0.6) / 0.4))
        }
        return points * 0.65 * (fraction / 0.6)
    }

    static func calculate(_ input: ActivityScoreInputs) -> ActivityScoreResult {
        var contributors: [ActivityContributor] = []

        if let steps = input.steps {
            contributors.append(ActivityContributor(
                kind: .steps,
                earned: goalScore(actual: Double(steps), goal: Double(input.stepsGoal),
                                  points: ActivityContributor.Kind.steps.maxPoints),
                maxPoints: ActivityContributor.Kind.steps.maxPoints,
                detail: "\(steps) of \(input.stepsGoal)"
            ))
        }

        if let active = input.activeMinutes {
            contributors.append(ActivityContributor(
                kind: .activeMinutes,
                earned: goalScore(actual: Double(active), goal: Double(input.activeMinutesGoal),
                                  points: ActivityContributor.Kind.activeMinutes.maxPoints),
                maxPoints: ActivityContributor.Kind.activeMinutes.maxPoints,
                detail: "\(active) of \(input.activeMinutesGoal) min"
            ))
        }

        // Ring-reported calories are unverified on the history path, so `ActivityDaily.calories` is
        // nil for ring-history days — which correctly drops this contributor rather than scoring a
        // number the app doesn't stand behind.
        if let energy = input.activeEnergyKcal {
            contributors.append(ActivityContributor(
                kind: .energy,
                earned: goalScore(actual: energy, goal: Double(input.energyGoal),
                                  points: ActivityContributor.Kind.energy.maxPoints),
                maxPoints: ActivityContributor.Kind.energy.maxPoints,
                detail: "\(Int(energy.rounded())) of \(input.energyGoal) kcal"
            ))
        }

        // Regularity: a day that hits its step goal in one gym session and then sits for twelve
        // hours is a different day from one that moves throughout, and only this contributor can
        // tell them apart.
        if let activeHours = input.activeHours, let observable = input.observableHours, observable > 0 {
            contributors.append(ActivityContributor(
                kind: .regularity,
                earned: goalScore(actual: Double(activeHours), goal: Double(observable),
                                  points: ActivityContributor.Kind.regularity.maxPoints),
                maxPoints: ActivityContributor.Kind.regularity.maxPoints,
                detail: "\(activeHours) of \(observable) hours with movement"
            ))
        }

        let available = contributors.reduce(0) { $0 + $1.maxPoints }
        let earned = contributors.reduce(0) { $0 + $1.earned }
        let score = available >= minAvailablePoints
            ? Int(min(100, max(0, (earned / available * 100).rounded())))
            : 0

        return ActivityScoreResult(
            score: score,
            band: ActivityBand(score: score),
            contributors: contributors,
            coverage: available / 100,
            algorithmVersion: algorithmVersion
        )
    }
}
