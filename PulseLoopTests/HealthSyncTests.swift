import XCTest
import HealthKit
import SwiftData
@testable import PulseLoop

/// Pure-logic coverage for the Apple Health export path: unit conversion / plausibility guards and
/// type maps in `HealthKitTypeMappings`, `AppleHealthPrefsStore` defaults / tolerant decode /
/// watermark-reset semantics, and the advanced-calories gate that HealthKit export inherits from
/// `WorkoutPrefsStore`. Deliberately excludes anything that instantiates `HKHealthStore` or calls
/// `requestAuthorization` — those aren't testable in CI.
@MainActor
final class HealthSyncTests: XCTestCase {

    // MARK: - HealthKitTypeMappings: unit conversion

    func testSpO2ConvertsPercentToFraction() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .spo2))
        // Ring stores SpO2 as a percent (e.g. 96) — convert to HealthKit's 0...1 fraction.
        XCTAssertEqual(mapping.convert(96), 0.96, accuracy: 0.0001)
        // A value already in fraction form (<=1) passes through unchanged.
        XCTAssertEqual(mapping.convert(0.96), 0.96, accuracy: 0.0001)
    }

    func testHeartRateAndHRVConvertPassThrough() throws {
        let hr = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .heartRate))
        XCTAssertEqual(hr.convert(72), 72)
        let hrv = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .hrv))
        XCTAssertEqual(hrv.convert(45), 45)
    }

    // MARK: - HealthKitTypeMappings: plausibility bounds

    func testHeartRatePlausibilityBounds() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .heartRate))
        XCTAssertTrue(mapping.isPlausible(20), "lower bound is inclusive")
        XCTAssertTrue(mapping.isPlausible(300), "upper bound is inclusive")
        XCTAssertTrue(mapping.isPlausible(72))
        XCTAssertFalse(mapping.isPlausible(19))
        XCTAssertFalse(mapping.isPlausible(301))
        XCTAssertFalse(mapping.isPlausible(0))
    }

    func testSpO2PlausibilityBounds() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .spo2))
        let accepted = mapping.convert(96)
        XCTAssertTrue(mapping.isPlausible(accepted))
        XCTAssertTrue(mapping.isPlausible(0.5), "lower bound is inclusive")
        XCTAssertTrue(mapping.isPlausible(1.0), "upper bound is inclusive")
        XCTAssertFalse(mapping.isPlausible(mapping.convert(40)), "40% SpO2 is implausible")
        XCTAssertFalse(mapping.isPlausible(1.2), "over 100% is impossible")
    }

    func testHRVPlausibilityBounds() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .hrv))
        XCTAssertTrue(mapping.isPlausible(45))
        XCTAssertFalse(mapping.isPlausible(0), "must be strictly positive")
        XCTAssertFalse(mapping.isPlausible(1000), "upper bound is exclusive")
        XCTAssertFalse(mapping.isPlausible(-5))
    }

    func testTemperaturePlausibilityBounds() throws {
        let mapping = try XCTUnwrap(HealthKitTypeMappings.quantityMapping(for: .temperature))
        XCTAssertTrue(mapping.isPlausible(37))
        XCTAssertFalse(mapping.isPlausible(25), "lower bound is exclusive")
        XCTAssertFalse(mapping.isPlausible(45), "upper bound is exclusive")
        XCTAssertFalse(mapping.isPlausible(15), "far below body temperature")
    }

    func testUnsupportedKindsMapToNil() {
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .stress), "no native HealthKit equivalent")
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .fatigue), "no native HealthKit equivalent")
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .bloodPressureSystolic), "needs HKCorrelation pairing")
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .bloodPressureDiastolic), "needs HKCorrelation pairing")
        XCTAssertNil(HealthKitTypeMappings.quantityMapping(for: .bloodSugar), "needs its own share type")
    }

    // MARK: - HealthKitTypeMappings: sleep-stage map

    func testSleepStageMap() {
        XCTAssertEqual(HealthKitTypeMappings.sleepValue(.light), .asleepCore, "light maps to Apple's core-sleep bucket")
        XCTAssertEqual(HealthKitTypeMappings.sleepValue(.deep), .asleepDeep)
        XCTAssertEqual(HealthKitTypeMappings.sleepValue(.rem), .asleepREM)
        XCTAssertEqual(HealthKitTypeMappings.sleepValue(.awake), .awake)
        XCTAssertEqual(HealthKitTypeMappings.sleepValue(.unknown), .asleepUnspecified)
    }

    // MARK: - HealthKitTypeMappings: workout-type map round-trip against ActivityMeta canonical types

    func testWorkoutActivityTypeCoversEveryCanonicalType() {
        let expected: [String: HKWorkoutActivityType] = [
            "walk": .walking,
            "run": .running,
            "cycle": .cycling,
            "gym": .traditionalStrengthTraining,
            "squash": .squash,
            "sport": .mixedCardio,
            "yoga": .yoga,
            "dance": .cardioDance,
            "hike": .hiking,
            "other": .other
        ]
        // Every canonical ActivityMeta type has an explicit, correct HealthKit mapping.
        for type in ActivityMeta.order {
            XCTAssertEqual(HealthKitTypeMappings.workoutActivityType(for: type), expected[type], "mismatch for \(type)")
        }
    }

    func testWorkoutActivityTypeResolvesLegacyAliases() {
        // "outdoor_run" and "ride" are legacy aliases (ActivityMeta.aliases) for "run" / "cycle".
        XCTAssertEqual(HealthKitTypeMappings.workoutActivityType(for: "outdoor_run"), .running)
        XCTAssertEqual(HealthKitTypeMappings.workoutActivityType(for: "ride"), .cycling)
        XCTAssertEqual(HealthKitTypeMappings.workoutActivityType(for: "strength"), .traditionalStrengthTraining)
    }

    func testWorkoutActivityTypeUnknownFallsBackToOther() {
        XCTAssertEqual(HealthKitTypeMappings.workoutActivityType(for: "some_unrecognized_activity"), .other)
    }

    func testDistanceTypePicksCyclingOnlyForCycle() throws {
        let cycleType = try XCTUnwrap(HealthKitTypeMappings.distanceType(for: "cycle"))
        XCTAssertEqual(cycleType, HKQuantityType.quantityType(forIdentifier: .distanceCycling))

        let runType = try XCTUnwrap(HealthKitTypeMappings.distanceType(for: "run"))
        XCTAssertEqual(runType, HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning))

        let walkType = try XCTUnwrap(HealthKitTypeMappings.distanceType(for: "walk"))
        XCTAssertEqual(walkType, HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning))
    }

    // MARK: - HealthKitTypeMappings: sync-identifier builder determinism

    func testVitalsSyncIDIsDeterministicPerKindAndInstant() {
        let ts = Date(timeIntervalSince1970: 1_750_000_000)
        let idA = HealthKitTypeMappings.vitalsSyncID(kindRaw: "hr", timestamp: ts)
        let idB = HealthKitTypeMappings.vitalsSyncID(kindRaw: "hr", timestamp: ts)
        XCTAssertEqual(idA, idB, "same kind + instant always produces the same id (upsert)")

        let differentKind = HealthKitTypeMappings.vitalsSyncID(kindRaw: "spo2", timestamp: ts)
        XCTAssertNotEqual(idA, differentKind)

        let differentTime = HealthKitTypeMappings.vitalsSyncID(kindRaw: "hr", timestamp: ts.addingTimeInterval(1))
        XCTAssertNotEqual(idA, differentTime)
    }

    func testActivitySyncIDIsDeterministicPerMetricAndDay() {
        let dayEpoch = Int(Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970)
        XCTAssertEqual(
            HealthKitTypeMappings.activitySyncID(metric: "steps", dayEpoch: dayEpoch),
            HealthKitTypeMappings.activitySyncID(metric: "steps", dayEpoch: dayEpoch)
        )
        XCTAssertNotEqual(
            HealthKitTypeMappings.activitySyncID(metric: "steps", dayEpoch: dayEpoch),
            HealthKitTypeMappings.activitySyncID(metric: "energy", dayEpoch: dayEpoch)
        )
        XCTAssertNotEqual(
            HealthKitTypeMappings.activitySyncID(metric: "steps", dayEpoch: dayEpoch),
            HealthKitTypeMappings.activitySyncID(metric: "steps", dayEpoch: dayEpoch + 86400)
        )
    }

    func testSleepAndWorkoutSyncIDsAreDeterministicPerID() {
        let blockID = UUID()
        XCTAssertEqual(HealthKitTypeMappings.sleepBlockSyncID(blockID: blockID), HealthKitTypeMappings.sleepBlockSyncID(blockID: blockID))
        XCTAssertNotEqual(HealthKitTypeMappings.sleepBlockSyncID(blockID: blockID), HealthKitTypeMappings.sleepBlockSyncID(blockID: UUID()))

        let sessionID = UUID()
        XCTAssertEqual(HealthKitTypeMappings.sleepSessionSyncID(sessionID: sessionID), HealthKitTypeMappings.sleepSessionSyncID(sessionID: sessionID))
        XCTAssertEqual(HealthKitTypeMappings.workoutSyncID(sessionID: sessionID), HealthKitTypeMappings.workoutSyncID(sessionID: sessionID))
        XCTAssertNotEqual(HealthKitTypeMappings.workoutSyncID(sessionID: sessionID), HealthKitTypeMappings.sleepSessionSyncID(sessionID: sessionID),
                          "different builders must not collide even given the same UUID")
    }

    func testMetadataCarriesSyncIdentifierVersionAndOptionalTimeZone() {
        let meta = HealthKitTypeMappings.metadata(syncID: "pl-m-hr-123", version: 7)
        XCTAssertEqual(meta[HKMetadataKeySyncIdentifier] as? String, "pl-m-hr-123")
        XCTAssertEqual(meta[HKMetadataKeySyncVersion] as? NSNumber, NSNumber(value: 7))
        XCTAssertNil(meta[HKMetadataKeyTimeZone], "time zone is opt-in")

        let sleepMeta = HealthKitTypeMappings.metadata(syncID: "pl-sleep-x", version: 1, timeZone: true)
        XCTAssertEqual(sleepMeta[HKMetadataKeyTimeZone] as? String, TimeZone.current.identifier)
    }

    func testDeviceFactoryReturnsNilWhenNothingIsKnown() {
        XCTAssertNil(HealthKitTypeMappings.device(name: nil, model: nil, firmwareVersion: nil))
        let device = HealthKitTypeMappings.device(name: "PulseLoop Ring", model: "R02", firmwareVersion: "1.2.3")
        XCTAssertEqual(device?.name, "PulseLoop Ring")
        XCTAssertEqual(device?.model, "R02")
        XCTAssertEqual(device?.firmwareVersion, "1.2.3")
    }

    // MARK: - AppleHealthPrefsStore: defaults

    func testAppleHealthPrefsDefaults() {
        let store = AppleHealthPrefsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertFalse(store.prefs.masterEnabled, "privacy-first: no writes until the user opts in")
        XCTAssertTrue(store.prefs.syncHeartRate)
        XCTAssertTrue(store.prefs.syncSpO2)
        XCTAssertTrue(store.prefs.syncHRV)
        XCTAssertTrue(store.prefs.syncTemperature)
        XCTAssertTrue(store.prefs.syncSleep)
        XCTAssertTrue(store.prefs.syncActivity)
        XCTAssertTrue(store.prefs.exportWorkouts)
        XCTAssertEqual(store.prefs.backfillChoice, .notAsked)
        XCTAssertTrue(store.syncState.measurementWatermarks.isEmpty)
        XCTAssertNil(store.syncState.activityExportedThrough)
        XCTAssertNil(store.syncState.sleepExportedThrough)
        XCTAssertNil(store.syncState.workoutsExportedThrough)
        XCTAssertNil(store.syncState.lastSyncAt)
    }

    // MARK: - AppleHealthPrefsStore: tolerant decode

    func testAppleHealthPrefsTolerantDecodeFillsMissingKeysWithDefaults() throws {
        // Simulate an older stored blob that predates `exportWorkouts` and `backfillChoice`, but has
        // a non-default `masterEnabled`. Decoding must keep the stored value and fill in the rest
        // from defaults rather than resetting the whole blob.
        let json = """
        {"masterEnabled": true, "syncHeartRate": false}
        """
        let decoded = try JSONDecoder().decode(AppleHealthPrefs.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.masterEnabled, "present key is honored")
        XCTAssertFalse(decoded.syncHeartRate, "present key is honored")
        XCTAssertTrue(decoded.syncSpO2, "missing key falls back to default, not false")
        XCTAssertTrue(decoded.syncHRV)
        XCTAssertTrue(decoded.syncTemperature)
        XCTAssertTrue(decoded.syncSleep)
        XCTAssertTrue(decoded.syncActivity)
        XCTAssertTrue(decoded.exportWorkouts)
        XCTAssertEqual(decoded.backfillChoice, .notAsked)
    }

    func testAppleHealthPrefsTolerantDecodeFromEmptyBlob() throws {
        let decoded = try JSONDecoder().decode(AppleHealthPrefs.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppleHealthPrefs.default)
    }

    func testAppleHealthSyncStateTolerantDecodeFillsMissingKeys() throws {
        let json = """
        {"measurementWatermarks": {"hr": 758000000}}
        """
        let decoded = try JSONDecoder().decode(AppleHealthSyncState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.measurementWatermarks["hr"], Date(timeIntervalSinceReferenceDate: 758000000))
        XCTAssertNil(decoded.activityExportedThrough, "missing key falls back to default (nil)")
        XCTAssertNil(decoded.sleepExportedThrough)
        XCTAssertNil(decoded.workoutsExportedThrough)
        XCTAssertNil(decoded.lastSyncAt)
        XCTAssertNil(decoded.lastSyncSummary)
    }

    /// End-to-end through the store: a hand-written partial blob written directly into a suite's
    /// `UserDefaults` (mimicking an older build's persisted data) must load with the stored value
    /// honored and every other field defaulted — never silently reset to `.default` wholesale.
    func testAppleHealthPrefsStoreLoadsPartialBlobTolerantly() throws {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        let partial = """
        {"masterEnabled": true, "syncSpO2": false}
        """
        suite.set(Data(partial.utf8), forKey: "pulseloop.applehealth.prefs.v1")

        let store = AppleHealthPrefsStore(defaults: suite)
        XCTAssertTrue(store.prefs.masterEnabled)
        XCTAssertFalse(store.prefs.syncSpO2)
        XCTAssertTrue(store.prefs.syncHeartRate, "untouched key defaults, not reset to false")
        XCTAssertTrue(store.prefs.exportWorkouts)
    }

    // MARK: - AppleHealthPrefsStore: watermark reset semantics

    func testResetWatermarksToNilClearsEverything() {
        let store = AppleHealthPrefsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.resetWatermarks(to: Date())   // seed some state first
        store.resetWatermarks(to: nil)
        XCTAssertTrue(store.syncState.measurementWatermarks.isEmpty, "nil = full-history backfill")
        XCTAssertNil(store.syncState.activityExportedThrough)
        XCTAssertNil(store.syncState.sleepExportedThrough)
        XCTAssertNil(store.syncState.workoutsExportedThrough)
    }

    func testResetWatermarksToDateStampsEveryKindAndCategory() {
        let store = AppleHealthPrefsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let now = Date()
        store.resetWatermarks(to: now)

        for kind in MeasurementKind.allCases {
            XCTAssertEqual(store.syncState.measurementWatermarks[kind.rawValue], now, "\(kind) watermark stamped")
        }
        XCTAssertEqual(store.syncState.activityExportedThrough, now)
        XCTAssertEqual(store.syncState.sleepExportedThrough, now)
        XCTAssertEqual(store.syncState.workoutsExportedThrough, now)
    }

    // MARK: - AppleHealthPrefsStore: prefs/state persist under separate keys

    func testPrefsAndSyncStatePersistUnderSeparateKeys() {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppleHealthPrefsStore(defaults: suite)

        var prefs = store.prefs
        prefs.masterEnabled = true
        store.prefs = prefs
        XCTAssertNotNil(suite.data(forKey: "pulseloop.applehealth.prefs.v1"), "prefs write lands under the prefs key")
        XCTAssertNil(suite.data(forKey: "pulseloop.applehealth.state.v1"), "prefs write must not touch the state key")

        store.resetWatermarks(to: Date())
        XCTAssertNotNil(suite.data(forKey: "pulseloop.applehealth.state.v1"), "watermark write lands under the state key")

        // Reloading from the same suite independently rehydrates both blobs.
        let reloaded = AppleHealthPrefsStore(defaults: suite)
        XCTAssertTrue(reloaded.prefs.masterEnabled, "prefs survive a fresh store instance over the same suite")
        XCTAssertFalse(reloaded.syncState.measurementWatermarks.isEmpty, "watermarks survive a fresh store instance over the same suite")
    }

    // MARK: - Advanced-calories gate

    /// `ActivityService.recomputeSummary` guards the calorie model on `WorkoutPrefsStore.shared`.
    /// `useAdvancedCalories == false` must fall back to the legacy flat 8 kcal/min estimate
    /// regardless of activity type; `true` routes through `WorkoutMetricsEngine` (MET fallback here,
    /// since no HR samples / profile are present to trigger the Keytel path).
    func testAdvancedCaloriesGateTogglesEstimator() throws {
        let originalSettings = WorkoutPrefsStore.shared.settings
        addTeardownBlock { WorkoutPrefsStore.shared.settings = originalSettings }

        let context = try TestSupport.makeContext()

        WorkoutPrefsStore.shared.settings.useAdvancedCalories = false
        let flatSession = ActivityRecorderService.start(type: "gym", useGps: false, notes: nil, context: context)
        let flatSummary = ActivityService.finishSummary(for: flatSession, endedAt: flatSession.startedAt.addingTimeInterval(30 * 60), context: context)
        // Legacy flat estimate: 8 kcal/min * 30 min = 240.
        XCTAssertEqual(try XCTUnwrap(flatSummary.calories), 240, accuracy: 0.5)

        WorkoutPrefsStore.shared.settings.useAdvancedCalories = true
        let advancedSession = ActivityRecorderService.start(type: "gym", useGps: false, notes: nil, context: context)
        let advancedSummary = ActivityService.finishSummary(for: advancedSession, endedAt: advancedSession.startedAt.addingTimeInterval(30 * 60), context: context)
        // No HR samples/profile → MET fallback: 5.0 MET (gym) * 70 kg default * 0.5 h = 175.
        XCTAssertEqual(try XCTUnwrap(advancedSummary.calories), 175, accuracy: 0.5)

        XCTAssertNotEqual(flatSummary.calories, advancedSummary.calories, "the gate must actually change which estimator runs")
    }

    func testAdvancedCaloriesGateOffIsFlatRegardlessOfActivityType() throws {
        let originalSettings = WorkoutPrefsStore.shared.settings
        addTeardownBlock { WorkoutPrefsStore.shared.settings = originalSettings }
        WorkoutPrefsStore.shared.settings.useAdvancedCalories = false

        let context = try TestSupport.makeContext()
        // Squash has a very different MET (12.0) than gym (5.0) — with the gate off both must still
        // land on the same flat-rate formula.
        let squash = ActivityRecorderService.start(type: "squash", useGps: false, notes: nil, context: context)
        let squashSummary = ActivityService.finishSummary(for: squash, endedAt: squash.startedAt.addingTimeInterval(10 * 60), context: context)
        XCTAssertEqual(try XCTUnwrap(squashSummary.calories), 80, accuracy: 0.5, "flat 8 kcal/min * 10 min, independent of activity type")
    }
}
