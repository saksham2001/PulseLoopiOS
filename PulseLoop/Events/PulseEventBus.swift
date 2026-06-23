import Foundation
import SwiftData

enum PulseEvent: Sendable {
    case deviceStateChanged(state: RingConnectionState, address: String?)
    /// Emitted on connect once the active wearable's type + capabilities are known, so persistence
    /// can stamp the `Device` and the UI can capability-gate its surfaces.
    case deviceIdentified(deviceType: RingDeviceType, capabilities: Set<WearableCapability>)
    case batteryLevel(percent: Int)
    case rawPacket(direction: PacketDirection, data: Data, decoded: RingDecodedEvent)
    case derivedUpdate(kind: String, entityType: String, entityId: String, payloadJSON: String?)
    case activityUpdate(timestamp: Date, steps: Int, distanceMeters: Double, calories: Double)
    /// One intraday activity bucket (summed into its day, not ratcheted). Calories omitted.
    case activityBucket(timestamp: Date, steps: Int, distanceMeters: Double)
    /// Emitted when a fresh ring history sync begins, so persistence zeroes the days about to be
    /// re-summed from buckets — keeps re-syncs idempotent (cleared data can't come back inflated).
    case activitySyncReset(sinceDaysAgo: Int)
    case heartRateSample(bpm: Int, timestamp: Date)
    case heartRateComplete(timestamp: Date)
    case spo2Progress(percent: Int?, timestamp: Date)
    case spo2Result(value: Int, timestamp: Date)
    case spo2Complete(timestamp: Date)
    case sleepTimeline(timestamp: Date, stages: [SleepStage])
    case historyMeasurement(kind: MeasurementKind, value: Double, timestamp: Date)
    case stressSample(value: Int, timestamp: Date)
    case hrvSample(value: Int, timestamp: Date)
    case temperatureSample(celsius: Double, timestamp: Date)
    /// Friendly history-sync progress for the product UI (e.g. "Syncing sleep…"). Never protocol terms.
    case syncProgress(stage: String)
    case workoutStarted(UUID)
    case workoutPaused(UUID)
    case workoutResumed(UUID)
    case workoutFinished(UUID)
    case gpsPoint(
        sessionId: UUID,
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        horizontalAccuracy: Double?,
        speed: Double?,
        course: Double?,
        accepted: Bool,
        rejectionReason: String?,
        timestamp: Date
    )
    case coachTrace(String)
}

actor PulseEventBus {
    static let shared = PulseEventBus()
    
    private var continuations: [UUID: AsyncStream<PulseEvent>.Continuation] = [:]
    
    func publish(_ event: PulseEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
    
    func stream() -> AsyncStream<PulseEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.remove(id) }
            }
        }
    }
    
    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

@MainActor
final class EventPersistenceSubscriber {
    private let context: ModelContext
    private var task: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
    }
    
    func start() {
        guard task == nil else { return }
        task = Task {
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                await MainActor.run {
                    self.persist(event)
                }
            }
        }
    }
    
    func stop() {
        task?.cancel()
        task = nil
    }
    
    func persist(_ event: PulseEvent) {
        switch event {
        case let .deviceStateChanged(state, address):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.state = state
            device.bleAddressHint = address ?? device.bleAddressHint
            if state == .connected {
                device.lastConnectedAt = Date()
                device.lastSyncAt = Date()
            }
            context.insert(device)
        case let .deviceIdentified(deviceType, capabilities):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.deviceType = deviceType
            device.capabilities = capabilities
            context.insert(device)
        case let .batteryLevel(percent):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.batteryPercent = percent
            context.insert(device)
        case let .rawPacket(direction, data, decoded):
            // The raw byte trace is a developer diagnostic only — never stored in release builds, so
            // production never persists protocol hex/opcodes.
            #if DEBUG
            context.insert(
                RawPacketRow(
                    direction: direction,
                    commandId: Int(data.first ?? 0),
                    hexPayload: data.hexString,
                    decodedKind: decoded.kind,
                    decodedJSON: decoded.debugJSON,
                    confidence: decoded.confidence
                )
            )
            #endif
        case let .derivedUpdate(kind, entityType, entityId, payloadJSON):
            context.insert(DerivedUpdateRow(kind: kind, entityType: entityType, entityId: entityId, payloadJSON: payloadJSON))
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            // Single ratchet source of truth (monotonic max within a day), tagged as live.
            let row = ActivityService.applyActivityUpdate(
                ActivityDailyUpdate(
                    date: timestamp,
                    steps: steps,
                    calories: calories,
                    distanceMeters: distanceMeters,
                    source: "live",
                    syncedAt: Date()
                ),
                context: context
            )
            context.insert(DerivedUpdateRow(
                kind: "activity_update",
                entityType: "activity_daily",
                entityId: row.id.uuidString,
                payloadJSON: #"{"steps":\#(row.steps),"calories":\#(Int(row.calories)),"distance_m":\#(Int(row.distanceMeters))}"#
            ))
        case let .activityBucket(timestamp, steps, distanceMeters):
            // Per-quarter-hour ring history: upserted by timestamp + the day total recomputed as the
            // sum of distinct buckets, so re-syncs are idempotent (no drift). Calories omitted.
            ActivityService.applyActivityBucket(date: timestamp, steps: steps, distanceMeters: distanceMeters, context: context)
        case .activitySyncReset:
            // No longer needed — bucket upsert-by-timestamp makes re-syncs idempotent on its own.
            // Kept as a no-op so the (still-published) event doesn't fall through to `unknown`.
            break
        case let .heartRateSample(bpm, timestamp):
            persistMeasurement(kind: .heartRate, value: Double(bpm), timestamp: timestamp, source: .live, kindLabel: "hr_sample")
        case let .spo2Result(value, timestamp):
            persistMeasurement(kind: .spo2, value: Double(value), timestamp: timestamp, source: .live, kindLabel: "spo2_result")
        case let .historyMeasurement(kind, value, timestamp):
            persistMeasurement(kind: kind, value: value, timestamp: timestamp, source: .history, kindLabel: "history_measurement")
        case let .stressSample(value, timestamp):
            persistMeasurement(kind: .stress, value: Double(value), timestamp: timestamp, source: .colmi, kindLabel: "stress_sample")
        case let .hrvSample(value, timestamp):
            persistMeasurement(kind: .hrv, value: Double(value), timestamp: timestamp, source: .colmi, kindLabel: "hrv_sample")
        case let .temperatureSample(celsius, timestamp):
            persistMeasurement(kind: .temperature, value: celsius, timestamp: timestamp, source: .colmi, kindLabel: "temperature_sample")
        case let .sleepTimeline(timestamp, stages):
            persistSleepTimeline(start: timestamp, stages: stages)
        case let .gpsPoint(sessionId, latitude, longitude, altitude, horizontalAccuracy, speed, course, accepted, rejectionReason, timestamp):
            context.insert(ActivityGpsPoint(
                sessionId: sessionId,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: horizontalAccuracy,
                speed: speed,
                course: course,
                timestamp: timestamp,
                accepted: accepted,
                rejectionReason: rejectionReason
            ))
            if let session = ActivityRepository.sessions(context: context).first(where: { $0.id == sessionId }) {
                if accepted {
                    session.gpsPointCount += 1
                    session.lastGpsPointAt = timestamp
                } else {
                    session.rejectedGpsPointCount += 1
                }
            }
        case .heartRateComplete, .spo2Progress, .spo2Complete, .syncProgress, .workoutStarted, .workoutPaused, .workoutResumed, .workoutFinished, .coachTrace:
            break
        }
        try? context.save()
    }
    
    /// Persist one live/history measurement, record a derived-update audit row, and link it to
    /// an in-progress workout if one is recording. Mirrors `persistence._on_hr_sample`.
    private func persistMeasurement(kind: MeasurementKind, value: Double, timestamp: Date, source: MeasurementSource, kindLabel: String) {
        let row = Measurement(kind: kind, value: value, unit: kind.unit, timestamp: timestamp, source: source)
        context.insert(row)
        context.insert(DerivedUpdateRow(kind: kindLabel, entityType: "measurement", entityId: row.id.uuidString))
        _ = ActivityRecorderService.linkSample(
            kind: kind,
            value: value,
            timestamp: timestamp,
            measurementId: row.id,
            source: source,
            confidence: .known,
            context: context
        )
    }

    /// Upsert a sleep session by night, appending this packet's per-minute stage blocks and
    /// recomputing session bounds. The ring streams ~20 timeline packets (15 samples each) per
    /// night, so blocks must accumulate into one session rather than spawning a session per
    /// packet. Mirrors `persistence._on_sleep_timeline`.
    private func persistSleepTimeline(start: Date, stages: [SleepStage]) {
        let calendar = Calendar.current
        let dateKey = calendar.startOfDay(for: start)
        let allSessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let session = allSessions.first { calendar.isDate($0.date, inSameDayAs: dateKey) }
            ?? {
                let new = SleepSession(date: dateKey, startAt: start, endAt: start, totalMinutes: 0, syncedAt: Date())
                context.insert(new)
                return new
            }()

        func blocks(for sessionId: UUID) -> [SleepStageBlock] {
            ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []).filter { $0.sessionId == sessionId }
        }

        var existingStarts = Set(blocks(for: session.id).map { $0.startAt })
        var offset = 0
        while offset < stages.count {
            let stage = stages[offset]
            var duration = 1
            while offset + duration < stages.count, stages[offset + duration] == stage {
                duration += 1
            }
            let blockStart = calendar.date(byAdding: .minute, value: offset, to: start) ?? start
            if !existingStarts.contains(blockStart) {
                context.insert(SleepStageBlock(sessionId: session.id, startAt: blockStart, startMinute: 0, durationMinutes: duration, stage: stage))
                existingStarts.insert(blockStart)
            }
            offset += duration
        }

        let sorted = blocks(for: session.id).sorted { $0.startAt < $1.startAt }
        guard let first = sorted.first else { return }
        let sessionStart = first.startAt
        let sessionEnd = sorted
            .map { calendar.date(byAdding: .minute, value: $0.durationMinutes, to: $0.startAt) ?? $0.startAt }
            .max() ?? sessionStart
        for block in sorted {
            block.startMinute = max(0, Int(block.startAt.timeIntervalSince(sessionStart) / 60))
        }
        session.startAt = sessionStart
        session.endAt = sessionEnd
        session.totalMinutes = max(0, Int(sessionEnd.timeIntervalSince(sessionStart) / 60))
        session.syncedAt = Date()
        session.updatedAt = Date()
        context.insert(DerivedUpdateRow(kind: "sleep_timeline", entityType: "sleep_session", entityId: session.id.uuidString))
    }
}
