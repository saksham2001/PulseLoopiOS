import Foundation
import SwiftData

@MainActor
enum ActivityRecorderService {
    static func start(type: String, useGps: Bool, notes: String?, context: ModelContext) -> ActivitySession {
        let session = ActivitySession(type: type, status: .recording, notes: notes, useGps: useGps)
        context.insert(session)
        context.insert(ActivityEvent(sessionId: session.id, kind: "created"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "started"))
        try? context.save()
        return session
    }
    
    static func pause(_ session: ActivitySession, context: ModelContext) {
        guard session.status == .recording else { return }
        session.status = .paused
        context.insert(ActivityEvent(sessionId: session.id, kind: "paused"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_stopped"))
        try? context.save()
    }
    
    static func resume(_ session: ActivitySession, context: ModelContext) {
        guard session.status == .paused else { return }
        if let lastPause = ActivityRepository.events(sessionId: session.id, context: context).last(where: { $0.kind == "paused" }) {
            session.totalPauseSeconds += max(0, Date().timeIntervalSince(lastPause.timestamp))
        }
        session.status = .recording
        context.insert(ActivityEvent(sessionId: session.id, kind: "resumed"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_started"))
        try? context.save()
    }
    
    static func finish(_ session: ActivitySession, context: ModelContext) {
        _ = ActivityService.finishSummary(for: session, context: context)
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_stopped"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "finished"))
        try? context.save()
        PulseDataChange.shared.notify()
    }
    
    static func cancel(_ session: ActivitySession, context: ModelContext) {
        session.status = .cancelled
        session.endedAt = Date()
        session.updatedAt = Date()
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_stopped"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "cancelled"))
        try? context.save()
    }
    
    /// Permanently deletes a workout and all of its child rows (samples, GPS points, events, sensor
    /// poll events — all raw-UUID FKs, so no SwiftData cascade) and reverses its contribution to the
    /// day's activity rollup so the totals stay honest.
    @MainActor
    static func delete(_ session: ActivitySession, context: ModelContext) {
        ActivityService.reverseDailyRollup(for: session, context: context)

        // Capture before the row is gone; the day's calorie estimate recomputes without it below.
        let affectedStart = session.startedAt
        let affectedEnd = session.endedAt

        let id = session.id
        ActivityRepository.samples(sessionId: id, context: context).forEach(context.delete)
        ActivityRepository.gpsPoints(sessionId: id, context: context).forEach(context.delete)
        ActivityRepository.events(sessionId: id, context: context).forEach(context.delete)
        let polls = ((try? context.fetch(FetchDescriptor<ActivitySensorPollEvent>())) ?? []).filter { $0.sessionId == id }
        polls.forEach(context.delete)
        context.delete(session)
        try? context.save()
        DailyCalorieEstimator.recompute(day: affectedStart, context: context)
        if let affectedEnd, !Calendar.current.isDate(affectedEnd, inSameDayAs: affectedStart) {
            DailyCalorieEstimator.recompute(day: affectedEnd, context: context)
        }
        try? context.save()
        HealthSyncService.shared.deleteExportedWorkout(sessionId: id)
        PulseDataChange.shared.notify()
    }

    static func recoverStaleSession(context: ModelContext) -> [ActivitySession] {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -6, to: Date()) ?? Date()
        return ActivityRepository.sessions(context: context)
            .filter { ($0.status == .recording || $0.status == .paused) && $0.startedAt < cutoff }
    }
    
    /// How long after a session finishes that ring-log samples may still attach to it. Covers the
    /// post-workout backfill sync (and a reconnect shortly after finishing).
    static let backfillLinkWindowSeconds: TimeInterval = 15 * 60
    /// A coarse history sample this close to an existing live sample of the same kind is noise from
    /// the ring's 5-min log overlapping the stream — skip it (half the 5-min log interval).
    static let historyDedupeSeconds: TimeInterval = 150

    @discardableResult
    static func linkSample(
        kind: MeasurementKind,
        value: Double,
        timestamp: Date,
        measurementId: UUID?,
        source: MeasurementSource,
        confidence: DecodeConfidence,
        context: ModelContext
    ) -> ActivitySample? {
        let sessions = ActivityRepository.sessions(context: context)
        let active = sessions.first { session in
            (session.status == .recording || session.status == .paused) && timestamp >= session.startedAt && timestamp <= Date()
        }
        // Ring-log backfill: history samples arrive *after* finish (post-workout sync / reconnect),
        // so also match a just-finished session whose window contains the sample.
        let target = active ?? sessions.first { session in
            guard session.status == .finished, let ended = session.endedAt else { return false }
            return Date().timeIntervalSince(ended) < backfillLinkWindowSeconds
                && timestamp >= session.startedAt && timestamp <= ended
        }
        guard let target else { return nil }
        let existing = ActivityRepository.samples(sessionId: target.id, context: context)
        if let measurementId, existing.contains(where: { $0.measurementId == measurementId }) {
            return nil
        }
        // Gap-fill rule: ring-log samples only fill stretches the live stream missed.
        if source == .history, existing.contains(where: {
            $0.kind == kind.rawValue
                && $0.source != MeasurementSource.history.rawValue
                && abs($0.timestamp.timeIntervalSince(timestamp)) <= historyDedupeSeconds
        }) {
            return nil
        }
        let sample = ActivitySample(
            sessionId: target.id,
            measurementId: measurementId,
            kind: kind.rawValue,
            value: value,
            unit: kind == .heartRate ? "bpm" : "%",
            timestamp: timestamp,
            source: source.rawValue,
            confidence: confidence
        )
        context.insert(sample)
        context.insert(ActivityEvent(sessionId: target.id, kind: "sensor_sample_linked", timestamp: timestamp))
        return sample
    }
}
