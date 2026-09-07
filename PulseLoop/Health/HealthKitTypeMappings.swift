import Foundation
import HealthKit

/// Pure, unit-testable translations between PulseLoop's domain model and HealthKit types.
///
/// Kept free of any `HKHealthStore` I/O so the mapping tables, plausibility guards, and the
/// deterministic sync-identifier builders can be exercised in isolation. `HealthSyncService`
/// (and its `+Workouts` extension) is the only caller.
enum HealthKitTypeMappings {

    // MARK: - Vitals → HKQuantityType

    /// How one `MeasurementKind` maps onto a HealthKit quantity type: the destination type, its unit,
    /// a value transform (ring units → HealthKit units), and a plausibility guard that rejects
    /// physiologically impossible samples before they reach Health.
    struct QuantityMapping {
        let type: HKQuantityType
        let unit: HKUnit
        let convert: (Double) -> Double
        let isPlausible: (Double) -> Bool
    }

    /// Ported from PR #16. Two kinds still map to `nil`, for two different reasons:
    ///
    /// - **Stress and fatigue have no HealthKit type at all.** Not a follow-up — there is nothing to
    ///   map them onto. `HKStateOfMind` (iOS 17) is a self-reported mood log, not a device-derived
    ///   score, and writing a ring's 0–100 wellness number into it would misrepresent both.
    /// - **Blood pressure is a correlation, not a quantity.** An unpaired systolic or diastolic
    ///   sample never surfaces as a reading in Health, so it needs `HKCorrelation` pairing and gets
    ///   its own export pass in `HealthSyncService` rather than a `QuantityMapping`.
    static func quantityMapping(for kind: MeasurementKind) -> QuantityMapping? {
        switch kind {
        case .heartRate:
            guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
            return QuantityMapping(type: type, unit: HKUnit.count().unitDivided(by: .minute()),
                                   convert: { $0 }, isPlausible: { $0 >= 20 && $0 <= 300 })
        case .spo2:
            guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return nil }
            // Ring stores SpO₂ as a percent (e.g. 96); HealthKit wants a 0…1 fraction.
            return QuantityMapping(type: type, unit: .percent(),
                                   convert: { $0 > 1 ? $0 / 100 : $0 }, isPlausible: { $0 >= 0.5 && $0 <= 1.0 })
        case .hrv:
            guard let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
            return QuantityMapping(type: type, unit: HKUnit.secondUnit(with: .milli),
                                   convert: { $0 }, isPlausible: { $0 > 0 && $0 < 1000 })
        case .temperature:
            // Apple's wrist-temperature type is read-only to third parties, so we write body temperature.
            guard let type = HKQuantityType.quantityType(forIdentifier: .bodyTemperature) else { return nil }
            return QuantityMapping(type: type, unit: .degreeCelsius(),
                                   convert: { $0 }, isPlausible: { $0 > 25 && $0 < 45 })
        case .respiratoryRate:
            guard let type = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) else { return nil }
            return QuantityMapping(type: type, unit: HKUnit.count().unitDivided(by: .minute()),
                                   convert: { $0 }, isPlausible: { $0 >= 4 && $0 <= 60 })
        case .vo2max:
            guard let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else { return nil }
            // mL/(kg·min) — HealthKit spells the same unit as a compound.
            let unit = HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
            return QuantityMapping(type: type, unit: unit,
                                   convert: { $0 }, isPlausible: { $0 >= 10 && $0 <= 90 })
        case .bloodSugar:
            guard let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return nil }
            // Stored canonically in mg/dL; HealthKit's mass/volume unit spells that as mg/dL too.
            let unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
            return QuantityMapping(type: type, unit: unit,
                                   convert: { $0 }, isPlausible: { $0 >= 40 && $0 <= 600 })
        case .stress, .fatigue:
            return nil   // No HealthKit type exists for either — see the note above.
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return nil   // Exported as an HKCorrelation instead; see `bloodPressureSyncID`.
        }
    }

    /// A paired blood-pressure reading, keyed by the instant both halves share so a re-export
    /// upserts rather than duplicating.
    static func bloodPressureSyncID(timestamp: Date) -> String {
        "pl-bp-\(Int(timestamp.timeIntervalSince1970 * 1000))"
    }

    /// Plausibility guards for the two halves of a blood-pressure reading, mirroring
    /// `RingEventBridge`'s persistence gates so a value that reached the store can still be rejected
    /// here if it is nonsense as a *pair* (systolic at or below diastolic).
    static func isPlausibleBloodPressure(systolic: Double, diastolic: Double) -> Bool {
        (60...250).contains(systolic) && (30...160).contains(diastolic) && systolic > diastolic
    }

    // MARK: - Workouts

    /// Maps a PulseLoop activity type onto the closest `HKWorkoutActivityType`.
    static func workoutActivityType(for type: String) -> HKWorkoutActivityType {
        switch ActivityMeta.meta(type).type {
        case "walk":   return .walking
        case "run":    return .running
        case "cycle":  return .cycling
        case "gym":    return .traditionalStrengthTraining
        case "squash": return .squash
        case "sport":  return .mixedCardio
        case "yoga":   return .yoga
        case "dance":  return .cardioDance
        case "hike":   return .hiking
        default:       return .other
        }
    }

    /// The distance quantity type appropriate for a workout — cycling distance for rides, else
    /// walking/running distance.
    static func distanceType(for type: String) -> HKQuantityType? {
        switch ActivityMeta.meta(type).type {
        case "cycle": return HKQuantityType.quantityType(forIdentifier: .distanceCycling)
        default:      return HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        }
    }

    // MARK: - Sleep

    /// Maps a ring sleep stage onto a HealthKit sleep-analysis category value. Light → `.asleepCore`
    /// (Apple's core-sleep bucket), unknown → `.asleepUnspecified`.
    static func sleepValue(_ stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .deep:    return .asleepDeep
        case .light:   return .asleepCore
        case .rem:     return .asleepREM
        case .awake:   return .awake
        case .unknown: return .asleepUnspecified
        }
    }

    // MARK: - Sync identifiers

    /// One vitals sample, keyed by kind + sample instant so re-exporting the same reading upserts.
    /// Uses millisecond precision: live HR bursts can emit two readings inside the same wall-clock
    /// second, and a whole-second identifier would collapse them onto one HealthKit sample.
    static func vitalsSyncID(kindRaw: String, timestamp: Date) -> String {
        "pl-m-\(kindRaw)-\(Int(timestamp.timeIntervalSince1970 * 1000))"
    }

    /// A daily-activity aggregate. `metric` is one of "steps" / "energy" / "dist"; `dayEpoch` is the
    /// unix start-of-day, so each day's total replaces the prior export rather than duplicating.
    static func activitySyncID(metric: String, dayEpoch: Int) -> String {
        "pl-act-\(metric)-\(dayEpoch)"
    }

    /// A single sleep-stage block (append-only with a stable id on main).
    static func sleepBlockSyncID(blockID: UUID) -> String {
        "pl-sleep-\(blockID.uuidString)"
    }

    /// A zero-block sleep session exported as one unspecified-asleep sample.
    static func sleepSessionSyncID(sessionID: UUID) -> String {
        "pl-sleepsession-\(sessionID.uuidString)"
    }

    /// A workout, keyed by session id so edits re-export and replace.
    static func workoutSyncID(sessionID: UUID) -> String {
        "pl-wk-\(sessionID.uuidString)"
    }

    /// One nutrient sample of a logged meal (`nutrient` e.g. "energy" / "protein"), keyed by
    /// entry id so an edited meal re-exports and replaces every nutrient sample.
    static func mealNutrientSyncID(entryID: UUID, nutrient: String) -> String {
        "pl-meal-\(entryID.uuidString)-\(nutrient)"
    }

    /// Prefix matching every nutrient sample of one meal — used for best-effort deletion.
    static func mealSyncIDPrefix(entryID: UUID) -> String {
        "pl-meal-\(entryID.uuidString)"
    }

    // MARK: - Sample metadata

    /// Builds the metadata dictionary every written sample carries: the deterministic sync identifier,
    /// its sync version (immutable data uses `1`; mutable data passes `Int(updatedAt)`), and — for sleep
    /// samples — the recording time zone so Health renders bedtimes in the user's local time.
    static func metadata(syncID: String, version: Int, timeZone: Bool = false) -> [String: Any] {
        var meta: [String: Any] = [
            HKMetadataKeySyncIdentifier: syncID,
            HKMetadataKeySyncVersion: NSNumber(value: version)
        ]
        if timeZone { meta[HKMetadataKeyTimeZone] = TimeZone.current.identifier }
        return meta
    }

    // MARK: - Device attribution

    /// An `HKDevice` describing the connected ring so Health attributes samples to it. Returns `nil`
    /// when no ring is paired (samples are then attributed to the app only).
    static func device(name: String?, model: String?, firmwareVersion: String?) -> HKDevice? {
        guard name != nil || model != nil || firmwareVersion != nil else { return nil }
        return HKDevice(
            name: name,
            manufacturer: nil,
            model: model,
            hardwareVersion: nil,
            firmwareVersion: firmwareVersion,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
    }
}
