import Foundation
import HealthKit
import SwiftData
import os

/// Exports everything the ring captures into Apple Health, one direction only (PulseLoop → Health):
///   • Vitals — heart rate, blood oxygen (SpO₂), HRV, skin temperature
///   • Daily activity — steps, active energy, walking/running distance
///   • Sleep — per-stage segments (deep / core / REM / awake)
///   • Workouts — type, energy, distance, and the recorded GPS route (see `+Workouts`)
///
/// The export is idempotent by construction: every sample carries an `HKMetadataKeySyncIdentifier`
/// so re-writing the same logical row **replaces** it (upsert) rather than duplicating — there is no
/// delete-then-rewrite pass. Progress is tracked as per-category watermark dates in
/// `AppleHealthPrefsStore` (no SwiftData schema change), so an interrupted backfill resumes.
///
/// Reads are limited to the user's Health *profile* (age/sex/height/weight) via `fetchUserProfileData`,
/// used only by the profile-import button. Authorization is requested exclusively from settings/profile
/// UI — never from an export path.
@MainActor
@Observable
final class HealthSyncService {
    static let shared = HealthSyncService()

    let store = HKHealthStore()
    let log = Logger(subsystem: "com.pulseloop", category: "HealthSync")

    /// True while an export run is in flight (drives the Settings button state).
    private(set) var isSyncing = false
    /// Human-readable result of the most recent export, shown under the action button.
    private(set) var lastResult: String?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var prefsStore: AppleHealthPrefsStore { .shared }

    private init() {}

    // MARK: - Authorization

    enum AuthState { case unavailable, notDetermined, denied, authorized }

    /// HealthKit never reveals *read* authorization (by design), so "connected" is judged purely on
    /// whether we can *share* (write) our types.
    var authState: AuthState {
        guard isAvailable else { return .unavailable }
        let statuses = shareTypes.map { store.authorizationStatus(for: $0) }
        if statuses.contains(.sharingAuthorized) { return .authorized }
        if statuses.allSatisfy({ $0 == .notDetermined }) { return .notDetermined }
        return .denied
    }

    /// Presents the system "Health Access" sheet. Called ONLY from settings/profile UI — never from an
    /// export path (re-prompting mid-sync is the anti-pattern this port removes).
    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthSyncError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    private var quantityWriteTypes: [HKQuantityType] {
        [
            .heartRate, .oxygenSaturation, .heartRateVariabilitySDNN, .bodyTemperature,
            .stepCount, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling
        ].compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    private var shareTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>(quantityWriteTypes)
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(sleep) }
        set.insert(HKObjectType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        return set
    }

    /// Read access covers the share set plus the profile characteristics the import button reads.
    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        shareTypes.forEach { set.insert($0) }
        set.formUnion(profileReadTypes)
        return set
    }

    // MARK: - Export entry points

    /// Incrementally exports everything newer than each category's watermark. Guards: master toggle on,
    /// HealthKit available, share access granted, and not running under XCTest. Each category pass runs
    /// in its own do/catch so one failing category never sinks the others.
    ///
    /// Returns `true` when the run executed, `false` when it short-circuited because another export is
    /// already in flight (or the guards failed) — the publisher uses this to re-arm so data that landed
    /// mid-run isn't stranded. When `resetWatermarksFirst` is set, the watermark reset happens **after**
    /// the `isSyncing` latch is taken (and before the state snapshot), so a concurrent in-flight export
    /// can neither clobber the reset nor let a full-history backfill be silently dropped.
    @discardableResult
    func exportIncremental(context: ModelContext, resetWatermarksFirst: Bool = false) async -> Bool {
        guard shouldExport(), !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }

        if resetWatermarksFirst { prefsStore.resetWatermarks(to: nil) }

        let now = Date()
        let device = ringDevice(context: context)
        var state = prefsStore.syncState
        var counts = SyncCounts()

        do { try await exportVitals(context: context, state: &state, counts: &counts, now: now, device: device) }
        catch { log.error("Vitals export failed: \(error.localizedDescription)") }
        do { try await exportActivity(context: context, state: &state, counts: &counts, now: now, device: device) }
        catch { log.error("Activity export failed: \(error.localizedDescription)") }
        do { try await exportSleep(context: context, state: &state, counts: &counts, now: now, device: device) }
        catch { log.error("Sleep export failed: \(error.localizedDescription)") }
        do { try await exportWorkouts(context: context, state: &state, counts: &counts, now: now, device: device) }
        catch { log.error("Workout export failed: \(error.localizedDescription)") }

        let summary = counts.summary
        state.lastSyncAt = now
        state.lastSyncSummary = summary
        prefsStore.syncState = state
        lastResult = summary
        log.info("Health export finished: \(summary, privacy: .public)")
        return true
    }

    /// Full-history backfill: clear every watermark, then run the incremental export from the start. The
    /// reset is deferred into `exportIncremental` so it happens atomically under the `isSyncing` lock.
    func exportHistory(context: ModelContext) async {
        await exportIncremental(context: context, resetWatermarksFirst: true)
    }

    /// Exports never run until the user has answered the first-enable backfill dialog: `backfillChoice`
    /// stays `.notAsked` in the window between master-enable and that choice, which would otherwise let a
    /// publisher-scheduled export write the full ring history against a user about to pick "new data only".
    private func shouldExport() -> Bool {
        guard prefsStore.prefs.masterEnabled, prefsStore.prefs.backfillChoice != .notAsked,
              isAvailable, authState == .authorized, !isRunningUnitTests else { return false }
        return true
    }

    /// True when running under the XCTest host. Every entry point that can reach `HKHealthStore`
    /// (export passes, deletion, removal) must check this: the test bundle isn't signed with the
    /// HealthKit entitlement, so any live HK call — even one as innocuous as `HKSource.default()` —
    /// throws `NSGenericException` ("unable to create default source from entitlements"). Deletion and
    /// removal run inside fire-and-forget `Task`s, so an unguarded throw there surfaces asynchronously
    /// against whatever unrelated test happens to be running at the time.
    private var isRunningUnitTests: Bool {
        #if DEBUG
        return NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }

    private var enabledVitalKinds: [MeasurementKind] {
        let prefs = prefsStore.prefs
        var kinds: [MeasurementKind] = []
        if prefs.syncHeartRate { kinds.append(.heartRate) }
        if prefs.syncSpO2 { kinds.append(.spo2) }
        if prefs.syncHRV { kinds.append(.hrv) }
        if prefs.syncTemperature { kinds.append(.temperature) }
        return kinds
    }

    private func ringDevice(context: ModelContext) -> HKDevice? {
        guard let device = DeviceRepository.current(context: context) else { return nil }
        return HealthKitTypeMappings.device(name: device.name, model: device.wearableModelID,
                                            firmwareVersion: device.firmwareVersion)
    }

    // MARK: - Vitals pass

    private func exportVitals(context: ModelContext, state: inout AppleHealthSyncState,
                              counts: inout SyncCounts, now: Date, device: HKDevice?) async throws {
        for kind in enabledVitalKinds {
            guard let mapping = HealthKitTypeMappings.quantityMapping(for: kind), canShare(mapping.type) else { continue }
            try await exportVitalKind(kind: kind, mapping: mapping, context: context,
                                      state: &state, counts: &counts, now: now, device: device)
        }
    }

    private func exportVitalKind(kind: MeasurementKind, mapping: HealthKitTypeMappings.QuantityMapping,
                                 context: ModelContext, state: inout AppleHealthSyncState,
                                 counts: inout SyncCounts, now: Date, device: HKDevice?) async throws {
        let raw = kind.rawValue
        let mockRaw = MeasurementSource.mock.rawValue
        let watermark = state.measurementWatermarks[raw] ?? .distantPast
        let descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw && $0.sourceRaw != mockRaw && $0.createdAt > watermark },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return }

        // Chunk of 1,000 per save; advance the watermark after each successful chunk so an interrupted
        // backfill resumes and re-runs stay harmless (upsert).
        for chunk in rows.chunked(into: 1000) {
            let samples = chunk.compactMap { vitalSample(row: $0, mapping: mapping, kindRaw: raw, now: now, device: device) }
            if !samples.isEmpty {
                try await save(samples)
                counts.vitals += samples.count
            }
            if let maxCreated = chunk.map(\.createdAt).max() {
                state.measurementWatermarks[raw] = maxCreated
                prefsStore.syncState = state
            }
        }
    }

    private func vitalSample(row: Measurement, mapping: HealthKitTypeMappings.QuantityMapping,
                             kindRaw: String, now: Date, device: HKDevice?) -> HKQuantitySample? {
        guard row.timestamp <= now else { return nil }   // never write a future-dated sample
        let value = mapping.convert(row.value)
        guard value.isFinite, mapping.isPlausible(value) else { return nil }
        let syncID = HealthKitTypeMappings.vitalsSyncID(kindRaw: kindRaw, timestamp: row.timestamp)
        return HKQuantitySample(
            type: mapping.type,
            quantity: HKQuantity(unit: mapping.unit, doubleValue: value),
            start: row.timestamp, end: row.timestamp,
            device: device,
            metadata: HealthKitTypeMappings.metadata(syncID: syncID, version: 1)
        )
    }

    // MARK: - Daily activity pass

    private func exportActivity(context: ModelContext, state: inout AppleHealthSyncState,
                                counts: inout SyncCounts, now: Date, device: HKDevice?) async throws {
        guard prefsStore.prefs.syncActivity else { return }
        let watermark = state.activityExportedThrough ?? .distantPast
        let mockRaw = MeasurementSource.mock.rawValue
        let descriptor = FetchDescriptor<ActivityDaily>(
            predicate: #Predicate { $0.updatedAt > watermark && $0.source != mockRaw },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return }

        let netting = workoutNetting(context: context)
        var samples: [HKQuantitySample] = []
        for row in rows {
            samples.append(contentsOf: activitySamples(row: row, netting: netting, now: now, device: device))
        }
        if !samples.isEmpty {
            try await save(samples)
            counts.dailyTotals += samples.count
        }
        if let maxUpdated = rows.map(\.updatedAt).max() {
            state.activityExportedThrough = maxUpdated
            prefsStore.syncState = state
        }
    }

    /// One day-spanning sample per enabled type. Native workout kcal/distance are netted out of the day
    /// total (only when workout export is on) so the Move ring doesn't double-count.
    private func activitySamples(row: ActivityDaily, netting: (kcal: [Date: Double], meters: [Date: Double]),
                                 now: Date, device: HKDevice?) -> [HKQuantitySample] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: row.date)
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let dayEnd = min(nextDay.addingTimeInterval(-1), now)   // clamp "today" so we never end in the future
        guard dayEnd > dayStart else { return [] }

        let dayEpoch = Int(dayStart.timeIntervalSince1970)
        let version = Int(row.updatedAt.timeIntervalSince1970)
        let netKcal = prefsStore.prefs.exportWorkouts ? (netting.kcal[dayStart] ?? 0) : 0
        let netMeters = prefsStore.prefs.exportWorkouts ? (netting.meters[dayStart] ?? 0) : 0

        var out: [HKQuantitySample] = []
        if let type = HKQuantityType.quantityType(forIdentifier: .stepCount), canShare(type), row.steps > 0 {
            out.append(quantitySample(type, unit: .count(), value: Double(row.steps), start: dayStart, end: dayEnd,
                                      syncID: HealthKitTypeMappings.activitySyncID(metric: "steps", dayEpoch: dayEpoch),
                                      version: version, device: device))
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), canShare(type) {
            let leftover = row.calories - netKcal
            if leftover > 0 {
                out.append(quantitySample(type, unit: .kilocalorie(), value: leftover, start: dayStart, end: dayEnd,
                                          syncID: HealthKitTypeMappings.activitySyncID(metric: "energy", dayEpoch: dayEpoch),
                                          version: version, device: device))
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning), canShare(type) {
            let leftover = row.distanceMeters - netMeters
            if leftover > 0 {
                out.append(quantitySample(type, unit: .meter(), value: leftover, start: dayStart, end: dayEnd,
                                          syncID: HealthKitTypeMappings.activitySyncID(metric: "dist", dayEpoch: dayEpoch),
                                          version: version, device: device))
            }
        }
        return out
    }

    /// Per-day finished-workout kcal/distance totals, used to net workouts out of the daily aggregate.
    ///
    /// Distance netting is deliberately narrow: only meters that were actually folded into the day's
    /// walking/running total may be subtracted from the `.distanceWalkingRunning` daily sample. That is
    /// exactly the set `creditDailyRollup` credits — GPS sessions only — and only those whose distance
    /// maps to walking/running (a cycling ride exports to `.distanceCycling`, a separate HealthKit type
    /// that never contributes to the walking+running total, so netting it would silently under-count the
    /// day's real walking distance).
    private func workoutNetting(context: ModelContext) -> (kcal: [Date: Double], meters: [Date: Double]) {
        var kcal: [Date: Double] = [:]
        var meters: [Date: Double] = [:]
        let cal = Calendar.current
        let walkRunID = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)?.identifier
        let sessions = ActivityRepository.sessions(context: context)
            .filter { $0.status == .finished && $0.endedAt != nil }
        for session in sessions {
            let day = cal.startOfDay(for: session.startedAt)
            if let k = session.calories, k > 0 { kcal[day, default: 0] += k }
            if session.useGps, let m = session.distanceMeters, m > 0,
               HealthKitTypeMappings.distanceType(for: session.type)?.identifier == walkRunID {
                meters[day, default: 0] += m
            }
        }
        return (kcal, meters)
    }

    private func quantitySample(_ type: HKQuantityType, unit: HKUnit, value: Double, start: Date, end: Date,
                                syncID: String, version: Int, device: HKDevice?) -> HKQuantitySample {
        HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start, end: end,
            device: device,
            metadata: HealthKitTypeMappings.metadata(syncID: syncID, version: version)
        )
    }

    // MARK: - Sleep pass

    private func exportSleep(context: ModelContext, state: inout AppleHealthSyncState,
                             counts: inout SyncCounts, now: Date, device: HKDevice?) async throws {
        // `SleepSession` carries no per-row source marker (unlike `Measurement`/`ActivityDaily`), so
        // seeded demo nights can't be filtered individually. When the store is in demo mode we skip the
        // whole sleep pass rather than write 30 fake nights into real Health — matching the mock
        // exclusion the vitals/activity passes apply per row.
        guard prefsStore.prefs.syncSleep,
              !MetricsRepository.hasMockMeasurement(context: context),
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              canShare(sleepType) else { return }
        let watermark = state.sleepExportedThrough ?? .distantPast
        let descriptor = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.updatedAt > watermark },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        let sessions = (try? context.fetch(descriptor)) ?? []
        guard !sessions.isEmpty else { return }

        var samples: [HKCategorySample] = []
        for session in sessions {
            samples.append(contentsOf: sleepSamples(session: session, type: sleepType, context: context, now: now, device: device))
        }
        if !samples.isEmpty {
            try await save(samples)
            counts.sleepSegments += samples.count
        }
        if let maxUpdated = sessions.map(\.updatedAt).max() {
            state.sleepExportedThrough = maxUpdated
            prefsStore.syncState = state
        }
    }

    /// Every stage block of a touched session (append-only, stable ids → pure upsert). A zero-block
    /// session exports as one `.asleepUnspecified` sample spanning its window.
    private func sleepSamples(session: SleepSession, type: HKCategoryType, context: ModelContext,
                              now: Date, device: HKDevice?) -> [HKCategorySample] {
        let blocks = SleepRepository.blocks(sessionId: session.id, context: context)
        if blocks.isEmpty {
            guard session.endAt > session.startAt, session.startAt <= now else { return [] }
            let syncID = HealthKitTypeMappings.sleepSessionSyncID(sessionID: session.id)
            return [HKCategorySample(
                type: type,
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: session.startAt, end: session.endAt,
                device: device,
                metadata: HealthKitTypeMappings.metadata(syncID: syncID, version: 1, timeZone: true)
            )]
        }
        var out: [HKCategorySample] = []
        for block in blocks {
            let end = block.startAt.addingTimeInterval(Double(block.durationMinutes) * 60)
            guard end > block.startAt, block.startAt <= now else { continue }
            let syncID = HealthKitTypeMappings.sleepBlockSyncID(blockID: block.id)
            out.append(HKCategorySample(
                type: type,
                value: HealthKitTypeMappings.sleepValue(block.stage).rawValue,
                start: block.startAt, end: end,
                device: device,
                metadata: HealthKitTypeMappings.metadata(syncID: syncID, version: 1, timeZone: true)
            ))
        }
        return out
    }

    // MARK: - Removal

    /// Removes every sample this app wrote to Apple Health (scoped to our own `HKSource`), then clears
    /// all watermarks and the last-sync stamp so the export state matches an empty Health store.
    func removeAllExportedData(context: ModelContext) async {
        guard isAvailable, !isRunningUnitTests, !isSyncing else { return }
        // Hold the same lock the export path takes so a publisher-scheduled export can't interleave this
        // removal (an in-flight export would otherwise re-persist its stale watermark snapshot and keep
        // writing the samples we just deleted).
        isSyncing = true
        defer { isSyncing = false }
        let sourcePredicate = HKQuery.predicateForObjects(from: HKSource.default())
        await withTaskGroup(of: Void.self) { group in
            for type in deletableTypes() where canShare(type) {
                group.addTask { await self.deleteOwnObjects(of: type, predicate: sourcePredicate) }
            }
        }
        prefsStore.resetWatermarks(to: nil)
        var state = prefsStore.syncState
        state.lastSyncAt = nil
        state.lastSyncSummary = nil
        prefsStore.syncState = state
        lastResult = nil
    }

    /// Fire-and-forget removal of a single exported workout (e.g. when its session is deleted locally).
    func deleteExportedWorkout(sessionId: UUID) {
        guard isAvailable, !isRunningUnitTests else { return }
        let syncID = HealthKitTypeMappings.workoutSyncID(sessionID: sessionId)
        Task { await self.deleteWorkout(syncID: syncID) }
    }

    private func deleteWorkout(syncID: String) async {
        let metaPredicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncID])
        let sourcePredicate = HKQuery.predicateForObjects(from: HKSource.default())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, metaPredicate])
        await deleteOwnObjects(of: HKObjectType.workoutType(), predicate: predicate)
    }

    /// Share types we can hand to `deleteObjects(of:)` — the concrete quantity/category/workout sample
    /// types (the workout-route series is removed with its parent workout).
    private func deletableTypes() -> [HKSampleType] {
        shareTypes.filter { $0 is HKQuantityType || $0 is HKCategoryType || $0 is HKWorkoutType }
    }

    private func deleteOwnObjects(of type: HKSampleType, predicate: NSPredicate) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                if let error {
                    self.log.error("deleteObjects failed for \(type.identifier): \(error.localizedDescription)")
                }
                cont.resume()
            }
        }
    }

    // MARK: - HealthKit plumbing

    func canShare(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    /// Saves a batch; on failure (e.g. one malformed sample) falls back to per-object saves so the rest
    /// still land. Rethrows when any object still fails to write, so the caller does **not** advance its
    /// watermark past rows that never reached Health — the next run re-attempts the whole chunk (upsert
    /// makes the retry harmless). A batch failure where every object then saves individually is treated
    /// as success.
    func save(_ objects: [HKObject]) async throws {
        guard !objects.isEmpty else { return }
        do {
            try await store.save(objects)
        } catch {
            log.error("Batch save failed, falling back to per-object: \(error.localizedDescription)")
            var firstFailure: Error?
            for object in objects {
                do {
                    try await store.save([object])
                } catch {
                    log.error("Failed to save object: \(error.localizedDescription)")
                    if firstFailure == nil { firstFailure = error }
                }
            }
            if let firstFailure { throw firstFailure }
        }
    }

    // MARK: - Result accounting

    struct SyncCounts {
        var vitals = 0
        var sleepSegments = 0
        var dailyTotals = 0
        var workouts = 0

        var summary: String {
            var parts: [String] = []
            if vitals > 0 { parts.append("\(vitals) vitals") }
            if sleepSegments > 0 { parts.append("\(sleepSegments) sleep segment\(sleepSegments == 1 ? "" : "s")") }
            if dailyTotals > 0 { parts.append("\(dailyTotals) daily total\(dailyTotals == 1 ? "" : "s")") }
            if workouts > 0 { parts.append("\(workouts) workout\(workouts == 1 ? "" : "s")") }
            guard !parts.isEmpty else { return "Nothing new to sync." }
            return "Synced " + parts.joined(separator: ", ") + " to Apple Health."
        }
    }
}

// MARK: - Profile import (read side)

/// Read side of the integration: request read-only access to (and fetch) the four Health *profile*
/// characteristics used by the profile-import button. Kept in its own extension so the export-focused
/// class body stays lean.
extension HealthSyncService {

    struct HealthProfileData {
        let age: Int?
        let sex: String?
        let heightCm: Double?
        let weightKg: Double?
    }

    /// Read-only authorization for the profile-import button: requests **read** access to the four
    /// profile characteristics and nothing to share. Kept separate from `requestAuthorization()` so the
    /// read-only "Import from Apple Health" action never presents a write-access prompt for ring data.
    func requestProfileReadAuthorization() async throws {
        guard isAvailable else { throw HealthSyncError.unavailable }
        try await store.requestAuthorization(toShare: [], read: profileReadTypes)
    }

    /// The four profile characteristics the profile-import button reads — and nothing else.
    var profileReadTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { set.insert(dob) }
        if let sex = HKObjectType.characteristicType(forIdentifier: .biologicalSex) { set.insert(sex) }
        if let height = HKQuantityType.quantityType(forIdentifier: .height) { set.insert(height) }
        if let weight = HKQuantityType.quantityType(forIdentifier: .bodyMass) { set.insert(weight) }
        return set
    }

    func fetchUserProfileData() async -> HealthProfileData {
        let age = readAge()
        let sex = readBiologicalSex()
        let heightCm = await latestQuantity(.height, unit: HKUnit.meterUnit(with: .centi))
        let weightKg = await latestQuantity(.bodyMass, unit: HKUnit.gramUnit(with: .kilo))
        return HealthProfileData(age: age, sex: sex, heightCm: heightCm, weightKg: weightKg)
    }

    private func readAge() -> Int? {
        guard let dob = try? store.dateOfBirthComponents(),
              let birthDate = Calendar.current.date(from: dob) else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
    }

    private func readBiologicalSex() -> String? {
        guard let wrapper = try? store.biologicalSex() else { return nil }
        switch wrapper.biologicalSex {
        case .female: return "female"
        case .male:   return "male"
        case .other:  return "other"
        default:      return nil
        }
    }

    /// Newest value of a characteristic-adjacent quantity type (height / body mass).
    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }
}

enum HealthSyncError: Error {
    case unavailable
}

private extension Array {
    /// Splits into consecutive sub-arrays of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
