import Foundation
import SwiftData

enum DeviceRepository {
    @MainActor
    static func devices(context: ModelContext) -> [Device] {
        (try? context.fetch(FetchDescriptor<Device>())) ?? []
    }
    
    @MainActor
    static func current(context: ModelContext) -> Device? {
        devices(context: context).first
    }
}

enum MetricsRepository {
    @MainActor
    static func activityRows(context: ModelContext) -> [ActivityDaily] {
        let descriptor = FetchDescriptor<ActivityDaily>(sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func unsyncedActivityRows(context: ModelContext) -> [ActivityDaily] {
        let descriptor = FetchDescriptor<ActivityDaily>(predicate: #Predicate { $0.syncedAt == nil }, sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func activityRows(descending context: ModelContext) -> [ActivityDaily] {
        let descriptor = FetchDescriptor<ActivityDaily>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func latestActivity(context: ModelContext) -> ActivityDaily? {
        activityRows(descending: context).first
    }
    
    @MainActor
    static func activity(on date: Date, context: ModelContext) -> ActivityDaily? {
        let start = Calendar.current.startOfDay(for: date)
        return activityRows(context: context).first { Calendar.current.isDate($0.date, inSameDayAs: start) }
    }
    
    @MainActor
    static func measurements(kind: MeasurementKind? = nil, context: ModelContext) -> [Measurement] {
        let descriptor = FetchDescriptor<Measurement>(sortBy: [SortDescriptor(\.timestamp)])
        let rows = (try? context.fetch(descriptor)) ?? []
        guard let kind else { return rows }
        return rows.filter { $0.kind == kind }
    }
    
    @MainActor
    static func unsyncedMeasurements(kind: MeasurementKind? = nil, context: ModelContext) -> [Measurement] {
        let descriptor = FetchDescriptor<Measurement>(predicate: #Predicate { $0.syncedAt == nil }, sortBy: [SortDescriptor(\.timestamp)])
        let rows = (try? context.fetch(descriptor)) ?? []
        guard let kind else { return rows }
        return rows.filter { $0.kind == kind }
    }
    
    @MainActor
    static func latestMeasurement(kind: MeasurementKind, context: ModelContext) -> Measurement? {
        measurements(kind: kind, context: context).last
    }
    
    @MainActor
    static func goals(context: ModelContext) -> UserGoal? {
        (try? context.fetch(FetchDescriptor<UserGoal>()))?.first
    }
}

enum MeasurementRepository {
    @discardableResult
    @MainActor
    static func insertMeasurement(
        kind: MeasurementKind,
        value: Double,
        unit: String,
        timestamp: Date = Date(),
        source: MeasurementSource = .ring,
        confidence: DecodeConfidence = .known,
        activitySessionId: UUID? = nil,
        rawPacketId: UUID? = nil,
        context: ModelContext
    ) -> Measurement {
        let row = Measurement(
            kind: kind,
            value: value,
            unit: unit,
            timestamp: timestamp,
            source: source,
            confidence: confidence,
            activitySessionId: activitySessionId,
            rawPacketId: rawPacketId
        )
        context.insert(row)
        return row
    }
    
    @MainActor
    static func range(metric: MetricKey, range: MetricRange, context: ModelContext) -> [MetricSample] {
        MetricsService.metricRange(metric: metric, range: range, context: context)
    }
}

enum SleepRepository {
    @MainActor
    static func sessions(context: ModelContext) -> [SleepSession] {
        let descriptor = FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func unsyncedSessions(context: ModelContext) -> [SleepSession] {
        let descriptor = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.syncedAt == nil }, sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func latestSession(context: ModelContext) -> SleepSession? {
        let descriptor = FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.startAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.first
    }
    
    @MainActor
    static func blocks(sessionId: UUID, context: ModelContext) -> [SleepStageBlock] {
        let descriptor = FetchDescriptor<SleepStageBlock>(sortBy: [SortDescriptor(\.startMinute)])
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.sessionId == sessionId }
    }
}

enum ActivityRepository {
    @MainActor
    static func sessions(context: ModelContext) -> [ActivitySession] {
        let descriptor = FetchDescriptor<ActivitySession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func unsyncedSessions(context: ModelContext) -> [ActivitySession] {
        let descriptor = FetchDescriptor<ActivitySession>(predicate: #Predicate { $0.syncedAt == nil }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func samples(sessionId: UUID, context: ModelContext) -> [ActivitySample] {
        let descriptor = FetchDescriptor<ActivitySample>(sortBy: [SortDescriptor(\.timestamp)])
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.sessionId == sessionId }
    }
    
    @MainActor
    static func gpsPoints(sessionId: UUID, context: ModelContext) -> [ActivityGpsPoint] {
        let descriptor = FetchDescriptor<ActivityGpsPoint>(sortBy: [SortDescriptor(\.timestamp)])
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.sessionId == sessionId }
    }
    
    @MainActor
    static func events(sessionId: UUID, context: ModelContext) -> [ActivityEvent] {
        let descriptor = FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.timestamp)])
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.sessionId == sessionId }
    }
}

enum ProfileRepository {
    @MainActor
    static func profile(context: ModelContext) -> UserProfile? {
        (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
    }

    @MainActor
    static func goal(context: ModelContext) -> UserGoal? {
        MetricsRepository.goals(context: context)
    }
}

/// Per-device measurement configuration (HR interval + all-day vital toggles), keyed by `Device.id`.
enum MeasurementConfigRepository {
    @MainActor
    static func config(deviceId: UUID, context: ModelContext) -> DeviceMeasurementConfig? {
        (try? context.fetch(FetchDescriptor<DeviceMeasurementConfig>(
            predicate: #Predicate { $0.deviceId == deviceId }
        )))?.first
    }

    /// Fetch the device's config, inserting (and persisting) a default one if none exists yet.
    @MainActor
    static func configOrDefault(deviceId: UUID, context: ModelContext) -> DeviceMeasurementConfig {
        if let existing = config(deviceId: deviceId, context: context) { return existing }
        let fresh = DeviceMeasurementConfig(deviceId: deviceId)
        context.insert(fresh)
        try? context.save()
        return fresh
    }

    @MainActor
    static func save(_ config: DeviceMeasurementConfig, context: ModelContext) {
        config.updatedAt = Date()
        try? context.save()
    }
}

enum CoachRepository {
    @MainActor
    static func messages(context: ModelContext) -> [CoachMessage] {
        let descriptor = FetchDescriptor<CoachMessage>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }
}

struct DebugPacketFilter {
    var direction: PacketDirection? = nil
    var commandId: Int? = nil
    var confidence: DecodeConfidence? = nil
}

enum DebugRepository {
    @discardableResult
    @MainActor
    static func insertRawPacket(
        timestamp: Date = Date(),
        direction: PacketDirection,
        commandId: Int,
        hexPayload: String,
        decodedKind: String? = nil,
        decodedJSON: String? = nil,
        confidence: DecodeConfidence = .unknown,
        context: ModelContext
    ) -> RawPacketRow {
        let row = RawPacketRow(
            timestamp: timestamp,
            direction: direction,
            commandId: commandId,
            hexPayload: hexPayload,
            decodedKind: decodedKind,
            decodedJSON: decodedJSON,
            confidence: confidence
        )
        context.insert(row)
        return row
    }
    
    @MainActor
    static func queryPackets(filter: DebugPacketFilter, context: ModelContext) -> [RawPacketRow] {
        let descriptor = FetchDescriptor<RawPacketRow>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.filter { row in
            if let direction = filter.direction, row.direction != direction { return false }
            if let commandId = filter.commandId, row.commandId != commandId { return false }
            if let confidence = filter.confidence, row.confidence != confidence { return false }
            return true
        }
    }
    
    @MainActor
    static func queryPackets(context: ModelContext) -> [RawPacketRow] {
        queryPackets(filter: DebugPacketFilter(), context: context)
    }
}
