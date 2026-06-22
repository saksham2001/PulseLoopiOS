import Foundation
import HealthKit
import CoreLocation
import SwiftData
import os

/// Mirrors everything the ring captures into Apple Health and requests read/write
/// access for those types:
///   • Vitals — heart rate, blood oxygen (SpO₂), HRV, skin temperature
///   • Daily activity — steps, active energy, walking/running distance
///   • Workouts — type, energy, distance, and the recorded GPS route
///   • Sleep — per-stage segments (deep / core / REM / awake)
///
/// The export is idempotent: every sync first deletes the objects this app wrote
/// previously, then writes the current state, so pressing "Sync" repeatedly never
/// duplicates data. Stress has no native HealthKit equivalent and is skipped.
@MainActor
@Observable
final class HealthSyncService {
    static let shared = HealthSyncService()

    private let store = HKHealthStore()
    private let log = Logger(subsystem: "com.pulseloop", category: "HealthSync")
    private var pendingSyncTask: Task<Void, Never>?

    /// True while a sync is running (drives the Settings button state).
    var isSyncing = false
    /// Human-readable result of the most recent sync, shown under the button.
    var lastResult: String?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private init() {}

    // MARK: - Authorization state

    enum AuthState { case unavailable, notDetermined, denied, authorized }

    /// HealthKit never reveals *read* authorization (for privacy), so "connected"
    /// is judged purely on whether we can *share* (write) our types.
    var authState: AuthState {
        guard isAvailable else { return .unavailable }
        let statuses = shareTypes.map { store.authorizationStatus(for: $0) }
        if statuses.contains(.sharingAuthorized) { return .authorized }
        if statuses.allSatisfy({ $0 == .notDetermined }) { return .notDetermined }
        return .denied
    }

    /// Presents the system "Health Access" sheet (a no-op if already answered).
    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthSyncError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    // MARK: - Type catalogue

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

    /// Read access mirrors write access — the app asks for everything it captures.
    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        shareTypes.forEach { set.insert($0) }
        return set
    }

    // MARK: - Sync

    /// Exports all captured data to Apple Health. Returns a short status string and
    /// also publishes it via `lastResult`.
    @discardableResult
    func syncAll(context: ModelContext, forceAll: Bool = false) async -> String {
        guard isAvailable else {
            let msg = "Apple Health isn't available on this device."
            lastResult = msg
            return msg
        }
        isSyncing = true
        defer { isSyncing = false }

        if forceAll {
            resetSyncStatus(context: context)
        }

        // Make sure we have permission (no-op once the user has answered the prompt).
        do {
            try await requestAuthorization()
        } catch {
            let msg = "Couldn't get Apple Health permission."
            lastResult = msg
            return msg
        }
        guard authState == .authorized else {
            let msg = "Apple Health access is off — enable it in Settings."
            lastResult = msg
            return msg
        }

        // Workouts are needed both to build HKWorkouts and to net them out of the
        // daily totals (so active energy isn't counted twice in the Move ring).
        let finishedSessions = ActivityRepository.sessions(context: context)
            .filter { $0.status == .finished && $0.endedAt != nil }

        // Phase 1 — incremental sync of unsynced state.
        var counts = SyncCounts()
        do {
            try await syncMeasurements(context: context, counts: &counts)
            try await syncDailyActivity(sessions: finishedSessions, context: context, counts: &counts)
            try await syncSleep(context: context, counts: &counts)
            
            let unsyncedSessions = ActivityRepository.unsyncedSessions(context: context)
                .filter { $0.status == .finished && $0.endedAt != nil }
            try await syncWorkouts(sessions: unsyncedSessions, context: context, counts: &counts)
        } catch {
            log.error("Health sync failed: \(error.localizedDescription)")
            let msg = "Synced with errors: \(error.localizedDescription)"
            lastResult = msg
            return msg
        }

        let msg = counts.summary
        lastResult = msg
        return msg
    }

    /// Schedules a debounced sync of all data to Apple Health.
    /// If another sync is requested before the debounce delay expires, the previous request is cancelled.
    func triggerAutomaticSync(context: ModelContext, delaySeconds: TimeInterval = 15) {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #endif
        
        guard authState == .authorized else { return }
        
        pendingSyncTask?.cancel()
        pendingSyncTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                _ = await syncAll(context: context)
            } catch {
                // Cancelled
            }
        }
    }

    // MARK: - Vitals (heart rate, SpO₂, HRV, temperature)

    private func syncMeasurements(context: ModelContext, counts: inout SyncCounts) async throws {
        // 1. Deduplicate local SwiftData measurements first to resolve any existing duplicate rows.
        let allMeasurements = MetricsRepository.measurements(context: context)
        var grouped: [String: [Measurement]] = [:]
        for m in allMeasurements {
            let key = "\(m.kindRaw)-\(m.timestamp.timeIntervalSince1970)"
            grouped[key, default: []].append(m)
        }
        
        var uuidsToDeleteFromHealth: [String] = []
        var localDeletedCount = 0
        
        for (_, list) in grouped where list.count > 1 {
            // Keep one: prefer one that is already synced, or just the first one
            let sorted = list.sorted { (m1, m2) -> Bool in
                if m1.syncedAt != nil && m2.syncedAt == nil { return true }
                if m1.syncedAt == nil && m2.syncedAt != nil { return false }
                return m1.id.uuidString < m2.id.uuidString
            }
            let toKeep = sorted[0]
            let toDelete = sorted.suffix(from: 1)
            
            for m in toDelete {
                uuidsToDeleteFromHealth.append(m.id.uuidString)
                context.delete(m)
                localDeletedCount += 1
            }
        }
        
        if localDeletedCount > 0 {
            try? context.save()
            log.info("Deduplicated \(localDeletedCount) duplicate measurements locally.")
        }
        
        if !uuidsToDeleteFromHealth.isEmpty {
            await deleteByExternalUUIDs(uuidsToDeleteFromHealth)
            log.info("Requested deletion of \(uuidsToDeleteFromHealth.count) duplicate measurements from Apple Health.")
        }

        // Skip seeded/demo rows so we never push synthetic data into Health.
        let measurements = MetricsRepository.unsyncedMeasurements(context: context)
            .filter { $0.sourceRaw != MeasurementSource.mock.rawValue }
        guard !measurements.isEmpty else { return }

        // Delete from Health first before writing to avoid any chance of duplication
        let externalUUIDs = measurements.map { $0.id.uuidString }
        await deleteByExternalUUIDs(externalUUIDs)

        var byType: [HKQuantityType: [HKQuantitySample]] = [:]
        for m in measurements {
            guard let mapping = Self.quantityMapping(for: m.kind), canShare(mapping.type) else { continue }
            let value = mapping.convert(m.value)
            guard value.isFinite, mapping.isPlausible(value) else { continue }
            let sample = HKQuantitySample(
                type: mapping.type,
                quantity: HKQuantity(unit: mapping.unit, doubleValue: value),
                start: m.timestamp,
                end: m.timestamp,
                metadata: [HKMetadataKeyExternalUUID: m.id.uuidString]
            )
            byType[mapping.type, default: []].append(sample)
        }

        for samples in byType.values {
            try await save(samples)
            counts.measurements += samples.count
        }
        
        for m in measurements {
            if let mapping = Self.quantityMapping(for: m.kind) {
                if canShare(mapping.type) {
                    m.syncedAt = Date()
                }
            } else {
                m.syncedAt = Date()
            }
        }
        try? context.save()
    }


    // MARK: - Daily activity (steps, active energy, distance)

    private func syncDailyActivity(sessions: [ActivitySession], context: ModelContext, counts: inout SyncCounts) async throws {
        let rows = MetricsRepository.unsyncedActivityRows(context: context).filter { $0.source != "mock" }
        guard !rows.isEmpty else { return }
        let cal = Calendar.current

        // Per-day workout totals so the daily aggregate only carries the *non-workout*
        // remainder; workouts add their own samples below. Sum = the captured day total.
        var workoutKcalByDay: [Date: Double] = [:]
        var workoutMetersByDay: [Date: Double] = [:]
        for s in sessions {
            let day = cal.startOfDay(for: s.startedAt)
            if let k = s.calories, k > 0 { workoutKcalByDay[day, default: 0] += k }
            if let m = s.distanceMeters, m > 0 { workoutMetersByDay[day, default: 0] += m }
        }

        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        let distType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)

        var steps: [HKQuantitySample] = []
        var energy: [HKQuantitySample] = []
        var distance: [HKQuantitySample] = []

        for row in rows {
            let dayStart = cal.startOfDay(for: row.date)
            guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            // Clamp "today" to now so we never write a sample ending in the future.
            let dayEnd = min(nextDay.addingTimeInterval(-1), Date())
            guard dayEnd > dayStart else { continue }

            if let stepType, canShare(stepType), row.steps > 0 {
                steps.append(HKQuantitySample(
                    type: stepType,
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(row.steps)),
                    start: dayStart, end: dayEnd,
                    metadata: [HKMetadataKeyExternalUUID: "steps-\(row.id.uuidString)"]))
            }
            if let energyType, canShare(energyType) {
                let leftover = row.calories - (workoutKcalByDay[dayStart] ?? 0)
                if leftover > 0 {
                    energy.append(HKQuantitySample(
                        type: energyType,
                        quantity: HKQuantity(unit: .kilocalorie(), doubleValue: leftover),
                        start: dayStart, end: dayEnd,
                        metadata: [HKMetadataKeyExternalUUID: "energy-\(row.id.uuidString)"]))
                }
            }
            if let distType, canShare(distType) {
                let leftover = row.distanceMeters - (workoutMetersByDay[dayStart] ?? 0)
                if leftover > 0 {
                    distance.append(HKQuantitySample(
                        type: distType,
                        quantity: HKQuantity(unit: .meter(), doubleValue: leftover),
                        start: dayStart, end: dayEnd,
                        metadata: [HKMetadataKeyExternalUUID: "distance-\(row.id.uuidString)"]))
                }
            }
        }

        let externalUUIDs = rows.flatMap { ["steps-\($0.id.uuidString)", "energy-\($0.id.uuidString)", "distance-\($0.id.uuidString)"] }
        await deleteByExternalUUIDs(externalUUIDs)

        for samples in [steps, energy, distance] where !samples.isEmpty {
            try await save(samples)
            counts.dailyMetrics += samples.count
        }
        
        let stepAuthorized = stepType.map { canShare($0) } ?? true
        let energyAuthorized = energyType.map { canShare($0) } ?? true
        let distAuthorized = distType.map { canShare($0) } ?? true
        
        if stepAuthorized && energyAuthorized && distAuthorized {
            for row in rows {
                row.syncedAt = Date()
            }
            try? context.save()
        }
    }

    // MARK: - Sleep

    private func syncSleep(context: ModelContext, counts: inout SyncCounts) async throws {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis), canShare(sleepType) else { return }
        let sessions = SleepRepository.unsyncedSessions(context: context)
        guard !sessions.isEmpty else { return }

        var samples: [HKCategorySample] = []
        for session in sessions {
            let blocks = SleepRepository.blocks(sessionId: session.id, context: context)
            if blocks.isEmpty {
                guard session.endAt > session.startAt else { continue }
                samples.append(HKCategorySample(
                    type: sleepType,
                    value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    start: session.startAt, end: session.endAt,
                    metadata: [HKMetadataKeyExternalUUID: "sleep-\(session.id.uuidString)"]))
                continue
            }
            for block in blocks {
                let end = block.startAt.addingTimeInterval(Double(block.durationMinutes) * 60)
                guard end > block.startAt else { continue }
                samples.append(HKCategorySample(
                    type: sleepType,
                    value: Self.sleepValue(block.stage).rawValue,
                    start: block.startAt, end: end,
                    metadata: [HKMetadataKeyExternalUUID: "sleepblock-\(block.id.uuidString)"]))
            }
        }
        let externalUUIDs = sessions.map { "sleep-\($0.id.uuidString)" } + sessions.flatMap { session in
            SleepRepository.blocks(sessionId: session.id, context: context).map { "sleepblock-\($0.id.uuidString)" }
        }
        await deleteByExternalUUIDs(externalUUIDs)

        guard !samples.isEmpty else { return }
        try await save(samples)
        counts.sleep = samples.count
        
        for session in sessions {
            session.syncedAt = Date()
        }
        try? context.save()
    }

    // MARK: - Workouts (+ HR association by time + GPS route)

    private func syncWorkouts(sessions: [ActivitySession], context: ModelContext, counts: inout SyncCounts) async throws {
        guard canShare(HKObjectType.workoutType()), !sessions.isEmpty else { return }
        
        let uuids = sessions.map { $0.id.uuidString }
        await deleteByExternalUUIDs(uuids)
        
        var saved = 0
        for session in sessions {
            guard let end = session.endedAt, end > session.startedAt else { continue }
            do {
                try await buildWorkout(session: session, end: end, context: context)
                session.syncedAt = Date()
                saved += 1
            } catch {
                log.error("Workout \(session.id.uuidString) sync failed: \(error.localizedDescription)")
            }
        }
        counts.workouts = saved
        try? context.save()
    }

    private func buildWorkout(session: ActivitySession, end: Date, context: ModelContext) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = Self.workoutActivityType(for: session.type)
        config.locationType = session.useGps ? .outdoor : .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: session.startedAt)

        var samples: [HKSample] = []
        if let kcal = session.calories, kcal > 0,
           let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), canShare(energyType) {
            samples.append(HKQuantitySample(
                type: energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                start: session.startedAt, end: end))
        }
        if let meters = session.distanceMeters, meters > 0,
           let distType = Self.distanceType(for: session.type), canShare(distType) {
            samples.append(HKQuantitySample(
                type: distType,
                quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                start: session.startedAt, end: end))
        }
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }
        try await builder.addMetadata([HKMetadataKeyExternalUUID: session.id.uuidString])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return }

        // Attach the recorded GPS route, if any accepted fixes exist.
        let points = ActivityRepository.gpsPoints(sessionId: session.id, context: context)
            .filter { $0.accepted }
            .sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 2, canShare(HKSeriesType.workoutRoute()) else { return }
        let locations = points.map { p in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                altitude: p.altitude ?? 0,
                horizontalAccuracy: p.horizontalAccuracy ?? 5,
                verticalAccuracy: p.altitude != nil ? 5 : -1,
                course: p.course ?? -1,
                speed: p.speed ?? -1,
                timestamp: p.timestamp)
        }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(locations)
        try await routeBuilder.finishRoute(with: workout, metadata: nil)
    }

    // MARK: - HealthKit plumbing

    private func canShare(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    private func save(_ objects: [HKObject]) async throws {
        guard !objects.isEmpty else { return }
        do {
            try await store.save(objects)
        } catch {
            log.error("Batch save failed, falling back to per-object. Error: \(error.localizedDescription)")
            // A single duplicate (same external UUID) fails the whole batch; fall
            // back to per-object saves so the rest still land.
            for object in objects {
                do {
                    try await store.save([object])
                } catch {
                    log.error("Failed to save object \(object): \(error.localizedDescription)")
                }
            }
        }
    }

    private func deleteByExternalUUIDs(_ uuids: [String]) async {
        guard !uuids.isEmpty else { return }
        let metaPredicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: uuids)
        let sourcePredicate = HKQuery.predicateForObjects(from: HKSource.default())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, metaPredicate])
        let allTypes = shareTypes.filter { $0 is HKQuantityType || $0 is HKCategoryType || $0 is HKWorkoutType }
        
        await withTaskGroup(of: Void.self) { group in
            for type in allTypes where canShare(type) {
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        self.store.deleteObjects(of: type, predicate: predicate) { success, count, error in
                            if let error {
                                self.log.error("deleteObjects failed for \(type.identifier): \(error.localizedDescription)")
                            }
                            cont.resume()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Mappings

    private struct QuantityMapping {
        let type: HKQuantityType
        let unit: HKUnit
        let convert: (Double) -> Double
        let isPlausible: (Double) -> Bool
    }

    private static func quantityMapping(for kind: MeasurementKind) -> QuantityMapping? {
        switch kind {
        case .heartRate:
            guard let t = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
            return QuantityMapping(type: t, unit: HKUnit.count().unitDivided(by: .minute()),
                                   convert: { $0 }, isPlausible: { $0 >= 20 && $0 <= 300 })
        case .spo2:
            guard let t = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return nil }
            // Ring stores SpO₂ as a percent (e.g. 96); HealthKit wants a 0…1 fraction.
            return QuantityMapping(type: t, unit: .percent(),
                                   convert: { $0 > 1 ? $0 / 100 : $0 }, isPlausible: { $0 >= 0.5 && $0 <= 1.0 })
        case .hrv:
            guard let t = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
            return QuantityMapping(type: t, unit: HKUnit.secondUnit(with: .milli),
                                   convert: { $0 }, isPlausible: { $0 > 0 && $0 < 1000 })
        case .temperature:
            guard let t = HKQuantityType.quantityType(forIdentifier: .bodyTemperature) else { return nil }
            return QuantityMapping(type: t, unit: .degreeCelsius(),
                                   convert: { $0 }, isPlausible: { $0 > 25 && $0 < 45 })
        case .stress:
            return nil   // No native HealthKit equivalent.
        }
    }

    private static func workoutActivityType(for type: String) -> HKWorkoutActivityType {
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

    private static func distanceType(for type: String) -> HKQuantityType? {
        switch ActivityMeta.meta(type).type {
        case "cycle": return HKQuantityType.quantityType(forIdentifier: .distanceCycling)
        default:      return HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        }
    }

    private static func sleepValue(_ stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .deep:    return .asleepDeep
        case .light:   return .asleepCore
        case .rem:     return .asleepREM
        case .awake:   return .awake
        case .unknown: return .asleepUnspecified
        }
    }

    // MARK: - Result accounting

    private struct SyncCounts {
        var measurements = 0
        var dailyMetrics = 0
        var sleep = 0
        var workouts = 0

        var summary: String {
            var parts: [String] = []
            if workouts > 0 { parts.append("\(workouts) workout\(workouts == 1 ? "" : "s")") }
            if measurements > 0 { parts.append("\(measurements) vitals") }
            if sleep > 0 { parts.append("\(sleep) sleep segment\(sleep == 1 ? "" : "s")") }
            if dailyMetrics > 0 { parts.append("\(dailyMetrics) daily total\(dailyMetrics == 1 ? "" : "s")") }
            guard !parts.isEmpty else { return "Nothing to sync yet." }
            return "Synced " + parts.joined(separator: ", ") + " to Apple Health."
        }
    }

    private func resetSyncStatus(context: ModelContext) {
        log.info("Resetting Apple Health sync status for all local records to force full re-sync.")
        let measurements = (try? context.fetch(FetchDescriptor<Measurement>())) ?? []
        for m in measurements {
            m.syncedAt = nil
        }
        let activities = (try? context.fetch(FetchDescriptor<ActivityDaily>())) ?? []
        for a in activities {
            a.syncedAt = nil
        }
        let sleep = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        for s in sleep {
            s.syncedAt = nil
        }
        let workouts = (try? context.fetch(FetchDescriptor<ActivitySession>())) ?? []
        for w in workouts {
            w.syncedAt = nil
        }
        try? context.save()
    }
}

enum HealthSyncError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health isn't available on this device."
        }
    }
}
