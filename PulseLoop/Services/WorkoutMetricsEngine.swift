import Foundation

/// Plain profile values the calorie model needs, kept SwiftData-free so the engine stays pure.
struct MetricsProfileValues: Sendable, Equatable {
    var sex: String?
    var age: Int?
    var weightKg: Double?

    init(sex: String? = nil, age: Int? = nil, weightKg: Double? = nil) {
        self.sex = sex
        self.age = age
        self.weightKg = weightKg
    }

    init(profile: UserProfile?) {
        self.init(sex: profile?.sex, age: profile?.age, weightKg: profile?.weightKg)
    }
}

/// Activity-specific workout metrics. Calories use the Keytel et al. (2005) HR model when the ring
/// gave us dense-enough HR and the profile is complete — this is where the workout HR stream earns
/// its keep — otherwise a per-type MET estimate (speed-tiered for run/cycle) replaces the old flat
/// 8 kcal/min for everything.
enum WorkoutMetricsEngine {
    /// Fallback body weight when no profile exists.
    static let defaultWeightKg = 70.0
    /// Minimum fraction of workout minutes with an HR sample before the HR model is trusted.
    static let keytelCoverageThreshold = 0.6

    static func calories(
        type: String,
        durationSeconds: Int,
        distanceMeters: Double?,
        hrSamples: [(timestamp: Date, bpm: Double)],
        profile: MetricsProfileValues
    ) -> Double {
        let minutes = Double(durationSeconds) / 60
        guard minutes > 0 else { return 0 }
        if let hrBased = keytelCalories(minutes: minutes, hrSamples: hrSamples, profile: profile) {
            return hrBased
        }
        let speed = distanceMeters.flatMap { durationSeconds > 0 ? $0 / Double(durationSeconds) : nil }
        let met = metValue(for: type, averageSpeedMps: speed)
        return met * (profile.weightKg ?? defaultWeightKg) * (minutes / 60)
    }

    /// MET by canonical activity type (2011 Compendium ballparks), speed-tiered where average
    /// speed meaningfully changes intensity.
    static func metValue(for type: String, averageSpeedMps: Double?) -> Double {
        switch ActivityMeta.meta(type).type {
        case "walk": return 3.5
        case "run":
            guard let v = averageSpeedMps, v > 0 else { return 9.8 }
            if v < 2.2 { return 8.3 }    // ≲ 8 km/h jog
            if v < 2.7 { return 9.8 }    // ~9.7 km/h
            if v < 3.2 { return 11.0 }   // ~11.3 km/h
            return 12.3
        case "cycle":
            guard let v = averageSpeedMps, v > 0 else { return 6.8 }
            if v < 4.2 { return 5.8 }    // < 15 km/h
            if v < 5.5 { return 6.8 }    // 15–20 km/h
            if v < 6.9 { return 8.0 }    // 20–25 km/h
            return 10.0
        case "gym": return 5.0
        case "squash": return 12.0
        case "sport": return 7.0
        case "yoga": return 2.5
        case "dance": return 5.5
        case "hike": return 6.0
        default: return 4.0
        }
    }

    // MARK: - Keytel HR model

    /// Sum of per-minute Keytel rates, with uncovered minutes credited at the covered minutes' mean
    /// rate. Returns nil when the profile is incomplete or HR coverage is below the threshold.
    private static func keytelCalories(
        minutes: Double,
        hrSamples: [(timestamp: Date, bpm: Double)],
        profile: MetricsProfileValues
    ) -> Double? {
        guard let sex = profile.sex?.lowercased(), sex == "male" || sex == "female",
              let age = profile.age, let weight = profile.weightKg, !hrSamples.isEmpty
        else { return nil }
        let byMinute = Dictionary(grouping: hrSamples.filter { $0.bpm > 0 }) {
            Int($0.timestamp.timeIntervalSince1970) / 60
        }
        guard Double(byMinute.count) / minutes >= keytelCoverageThreshold else { return nil }
        let rates = byMinute.values.map { bucket -> Double in
            let meanHR = bucket.reduce(0) { $0 + $1.bpm } / Double(bucket.count)
            return keytelRate(hr: meanHR, male: sex == "male", age: Double(age), weightKg: weight)
        }
        let meanRate = rates.reduce(0, +) / Double(rates.count)
        return max(0, meanRate * minutes)
    }

    /// kcal/min for a given heart rate (Keytel et al. 2005, without VO2max), clamped ≥ 0.
    private static func keytelRate(hr: Double, male: Bool, age: Double, weightKg: Double) -> Double {
        let kj = male
            ? -55.0969 + 0.6309 * hr + 0.1988 * weightKg + 0.2017 * age
            : -20.4022 + 0.4472 * hr - 0.1263 * weightKg + 0.0740 * age
        return max(0, kj / 4.184)
    }
}

/// Which stats a workout of a given type surfaces, live and in the summary — pace for foot
/// activities, speed for cycling, neither for court/studio workouts.
struct ActivityMetricSet: Equatable {
    let showsDistance: Bool
    let showsPace: Bool
    let showsSpeed: Bool
    let showsElevation: Bool
    let showsSplits: Bool

    static func set(for type: String) -> ActivityMetricSet {
        switch ActivityMeta.meta(type).type {
        case "walk":
            return ActivityMetricSet(showsDistance: true, showsPace: true, showsSpeed: false, showsElevation: false, showsSplits: true)
        case "run", "hike":
            return ActivityMetricSet(showsDistance: true, showsPace: true, showsSpeed: false, showsElevation: true, showsSplits: true)
        case "cycle":
            return ActivityMetricSet(showsDistance: true, showsPace: false, showsSpeed: true, showsElevation: true, showsSplits: true)
        case "sport":
            return ActivityMetricSet(showsDistance: true, showsPace: false, showsSpeed: false, showsElevation: false, showsSplits: false)
        default:
            return ActivityMetricSet(showsDistance: false, showsPace: false, showsSpeed: false, showsElevation: false, showsSplits: false)
        }
    }
}
