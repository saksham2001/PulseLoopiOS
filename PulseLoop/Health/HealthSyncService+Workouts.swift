import Foundation
import HealthKit
import CoreLocation
import SwiftData
import os

/// Workout export: finished `ActivitySession`s become `HKWorkout`s with energy/distance samples, a
/// deterministic sync identifier (so edits replace rather than duplicate), and the recorded GPS route.
/// Gated on the `exportWorkouts` preference.
extension HealthSyncService {

    func exportWorkouts(context: ModelContext, state: inout AppleHealthSyncState,
                        counts: inout SyncCounts, now: Date, device: HKDevice?) async throws {
        // `ActivitySession` carries no per-row source marker, so seeded demo workouts (with synthetic GPS
        // routes) can't be filtered individually — skip the whole pass in demo mode, mirroring the vitals
        // pass's per-row mock exclusion.
        guard AppleHealthPrefsStore.shared.prefs.exportWorkouts,
              !MetricsRepository.hasMockMeasurement(context: context),
              canShare(HKObjectType.workoutType()) else { return }
        let watermark = state.workoutsExportedThrough ?? .distantPast
        let finishedRaw = ActivitySessionStatus.finished.rawValue
        let descriptor = FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.statusRaw == finishedRaw && $0.endedAt != nil && $0.updatedAt > watermark },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        let sessions = (try? context.fetch(descriptor)) ?? []
        guard !sessions.isEmpty else { return }

        // Sessions are processed in ascending `updatedAt` order against a single scalar watermark, so the
        // watermark may only advance over a contiguous run of fully-handled sessions. A future-dated or
        // transiently-failing session therefore *stops* the pass (rather than being skipped) so a later
        // success can't leapfrog the watermark past it — it is retried on the next run.
        for session in sessions {
            guard let end = session.endedAt, end > session.startedAt else {
                // Zero/negative duration will never become exportable — let the watermark move past it.
                advanceWorkoutWatermark(to: session.updatedAt, state: &state)
                continue
            }
            guard end <= now else { break }   // future-dated (clock skew): retry once its end passes
            do {
                try await buildWorkout(session: session, end: end, context: context, device: device)
                counts.workouts += 1
            } catch {
                log.error("Workout \(session.id.uuidString) export failed: \(error.localizedDescription)")
                break
            }
            advanceWorkoutWatermark(to: session.updatedAt, state: &state)
        }
    }

    private func advanceWorkoutWatermark(to date: Date, state: inout AppleHealthSyncState) {
        state.workoutsExportedThrough = date
        AppleHealthPrefsStore.shared.syncState = state
    }

    private func buildWorkout(session: ActivitySession, end: Date, context: ModelContext, device: HKDevice?) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = HealthKitTypeMappings.workoutActivityType(for: session.type)
        config.locationType = session.useGps ? .outdoor : .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: device ?? .local())
        try await builder.beginCollection(at: session.startedAt)

        let samples = workoutChildSamples(session: session, end: end, device: device)
        if !samples.isEmpty { try await builder.addSamples(samples) }

        let syncID = HealthKitTypeMappings.workoutSyncID(sessionID: session.id)
        let version = Int(session.updatedAt.timeIntervalSince1970)
        try await builder.addMetadata(HealthKitTypeMappings.metadata(syncID: syncID, version: version))
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return }

        try await attachRoute(to: workout, session: session, context: context, device: device)
    }

    private func workoutChildSamples(session: ActivitySession, end: Date, device: HKDevice?) -> [HKSample] {
        var samples: [HKSample] = []
        if let kcal = session.calories, kcal > 0,
           let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), canShare(energyType) {
            samples.append(HKQuantitySample(
                type: energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                start: session.startedAt, end: end, device: device, metadata: nil))
        }
        if let meters = session.distanceMeters, meters > 0,
           let distType = HealthKitTypeMappings.distanceType(for: session.type), canShare(distType) {
            samples.append(HKQuantitySample(
                type: distType,
                quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                start: session.startedAt, end: end, device: device, metadata: nil))
        }
        return samples
    }

    /// Attaches the recorded GPS route when at least two accepted fixes exist.
    private func attachRoute(to workout: HKWorkout, session: ActivitySession,
                             context: ModelContext, device: HKDevice?) async throws {
        let points = ActivityRepository.gpsPoints(sessionId: session.id, context: context)
            .filter { $0.accepted }
            .sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 2, canShare(HKSeriesType.workoutRoute()) else { return }
        let locations = points.map { location(from: $0) }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: device)
        try await routeBuilder.insertRouteData(locations)
        try await routeBuilder.finishRoute(with: workout, metadata: nil)
    }

    private func location(from point: ActivityGpsPoint) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            altitude: point.altitude ?? 0,
            horizontalAccuracy: point.horizontalAccuracy ?? 5,
            verticalAccuracy: point.altitude != nil ? 5 : -1,
            course: point.course ?? -1,
            speed: point.speed ?? -1,
            timestamp: point.timestamp)
    }
}
