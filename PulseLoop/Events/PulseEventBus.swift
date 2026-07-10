import Foundation
import SwiftData

enum PulseEvent: Sendable {
    case deviceStateChanged(state: RingConnectionState, address: String?)
    /// Emitted on connect once the active wearable's type + capabilities are known, so persistence
    /// can stamp the `Device` and the UI can capability-gate its surfaces.
    case deviceIdentified(
        deviceType: RingDeviceType,
        wearableModelID: String?,
        advertisedName: String?,
        capabilities: Set<WearableCapability>
    )
    case deviceForgotten
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
    // Extra metrics from the jring/56ff 0x24 combined-sensor packet.
    case bloodPressureSample(systolic: Int, diastolic: Int, timestamp: Date)
    case fatigueSample(value: Int, timestamp: Date)
    case bloodSugarSample(mgdl: Double, timestamp: Date)
    /// Firmware version string parsed from the ring's status/firmware payload; persisted on the Device.
    case firmwareVersion(String)
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

    #if DEBUG
    /// Rolling cap for the DEBUG-only raw-packet trace, and how often we prune (every Nth insert,
    /// so we don't pay a fetch on every packet during a sync burst).
    private let rawPacketCap = 2_000
    private let rawPacketPruneInterval = 200
    private var rawPacketInsertsSincePrune = 0
    #endif

    /// Coalesced-save state. During a sync the ring streams hundreds of events; saving per event
    /// woke every `@Query` hundreds of times (the re-render storm). Instead we insert/mutate without
    /// saving, then flush (one `save()` + one "data changed" signal) after the stream briefly idles
    /// or a hard cap of pending writes is reached.
    private var pendingWrites = 0
    private var flushTask: Task<Void, Never>?
    /// Idle window after the last event before we flush a batch.
    private let flushDebounceNanos: UInt64 = 300_000_000   // 0.3s
    /// Hard ceiling so a long continuous stream still flushes periodically (never unbounded latency).
    private let flushMaxPending = 100

    /// Identity of a history sample within one sync run — see `isDuplicateHistory`.
    private struct HistoryKey: Hashable {
        let kind: String
        let epoch: Int
    }
    /// History samples already seen this sync. Cleared when a sync completes, so it can't grow
    /// unbounded across a long-lived session.
    private var seenHistoryKeys: Set<HistoryKey> = []

    /// Battery-history throttle. Battery events arrive on connect and roughly hourly from the watchdog,
    /// sometimes repeating the same percent; we only persist a `BatterySample` when the value changes or
    /// a 30-min floor has elapsed, keeping the history table tiny. State is in-memory, so the first
    /// reading after a (re)launch always records — which is what we want for a per-session data point.
    private var lastBatteryPercent: Int?
    private var lastBatteryLogAt: Date?
    private let batteryMinInterval: TimeInterval = 30 * 60   // 30 min

    init(context: ModelContext) {
        self.context = context
    }

    // Explicit deinit: cancels the outstanding event/flush tasks and (crucially) gives this
    // @MainActor class a non-isolated deinit. Without one, the compiler synthesizes a main-actor
    // -isolated deinit that hops through `swift_task_deinitOnExecutorMainActorBackDeploy` on dealloc;
    // that back-deploy shim double-frees on iOS < 26.5 (the CI runner's runtime), aborting the test
    // process with SIGABRT when a unit test creates and drops a subscriber. See the CI notes in ci.yml.
    deinit {
        task?.cancel()
        flushTask?.cancel()
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
        flushTask?.cancel()
        flushNow()
        task?.cancel()
        task = nil
    }

    /// Persist any pending batched writes immediately. Call on app background/suspend so a sync that
    /// is mid-batch isn't lost.
    func flush() {
        flushNow()
    }

    func persist(_ event: PulseEvent) {
        applyPersist(event)
        scheduleFlush()
    }

    /// Debounced batch flush: reset the idle timer each event; flush immediately if too many writes
    /// have piled up. Coalesces a sync burst into a handful of saves + change signals.
    private func scheduleFlush() {
        pendingWrites += 1
        if pendingWrites >= flushMaxPending {
            flushNow()
            return
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            let nanos = self?.flushDebounceNanos ?? 300_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.flushNow()
        }
    }

    /// Persist the accumulated batch and notify observers exactly once.
    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard pendingWrites > 0 else { return }
        pendingWrites = 0
        try? context.save()
        // One coalesced signal per batch; stores recompute once instead of per event.
        PulseDataChange.shared.notify()
    }

    // This is an exhaustive event router; each enum case is independent rather than branching logic.
    // swiftlint:disable:next cyclomatic_complexity
    private func applyPersist(_ event: PulseEvent) {
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
        case let .deviceIdentified(deviceType, wearableModelID, advertisedName, capabilities):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.deviceType = deviceType
            device.wearableModelID = wearableModelID
            if let advertisedName { device.advertisedName = advertisedName }
            device.capabilities = capabilities
            context.insert(device)
        case .deviceForgotten:
            guard let device = MetricsService.fetchDevices(context).first else { break }
            device.wearableModelID = nil
            device.advertisedName = nil
            context.insert(device)
        case let .batteryLevel(percent):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.batteryPercent = percent
            context.insert(device)
            recordBatterySample(percent)
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
            // Keep the debug trace a rolling window so it can't grow without bound. Prune only
            // every Nth insert to avoid a fetch on every packet during a sync burst.
            rawPacketInsertsSincePrune += 1
            if rawPacketInsertsSincePrune >= rawPacketPruneInterval {
                rawPacketInsertsSincePrune = 0
                DebugRepository.pruneRawPackets(maxRows: rawPacketCap, context: context)
            }
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
        case let .bloodPressureSample(systolic, diastolic, timestamp):
            // BP is two metrics in one packet — store as two rows so each trends independently.
            persistMeasurement(kind: .bloodPressureSystolic, value: Double(systolic), timestamp: timestamp, source: .live, kindLabel: "bp_systolic_sample")
            persistMeasurement(kind: .bloodPressureDiastolic, value: Double(diastolic), timestamp: timestamp, source: .live, kindLabel: "bp_diastolic_sample")
        case let .fatigueSample(value, timestamp):
            persistMeasurement(kind: .fatigue, value: Double(value), timestamp: timestamp, source: .live, kindLabel: "fatigue_sample")
        case let .bloodSugarSample(mgdl, timestamp):
            persistMeasurement(kind: .bloodSugar, value: mgdl, timestamp: timestamp, source: .live, kindLabel: "blood_sugar_sample")
        case let .firmwareVersion(version):
            persistFirmwareVersion(version)
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
        case let .syncProgress(stage):
            // Stamp the *completion* of a full history sync so the coach freshness gate can tell a
            // finished sync from a bare CONNECT (`lastSyncAt`, re-stamped every connect).
            if stage == "done" {
                if let device = DeviceRepository.current(context: context) {
                    device.lastFullSyncAt = Date()
                }
                // The rows are committed by now; the next sync re-checks against the database.
                seenHistoryKeys.removeAll(keepingCapacity: true)
            }
        case .heartRateComplete, .spo2Progress, .spo2Complete, .workoutStarted, .workoutPaused, .workoutResumed, .workoutFinished, .coachTrace:
            break
        }
        // NB: no per-event save here — `scheduleFlush()` (called by `persist`) batches the save.
    }
    
    /// Persist one live/history measurement, record a derived-update audit row, and link it to
    /// an in-progress workout if one is recording. Mirrors `persistence._on_hr_sample`.
    ///
    /// History rows are **upserted** on `(kind, timestamp)`: a ring replays the same log every time we
    /// re-request a day, and the epochs it stamps are deterministic, so an exact-timestamp match is a
    /// valid identity. Live samples keep append semantics (two readings a second apart are two events).
    private func persistMeasurement(kind: MeasurementKind, value: Double, timestamp: Date, source: MeasurementSource, kindLabel: String) {
        if source == .history, isDuplicateHistory(kind: kind, value: value, timestamp: timestamp) { return }
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

    /// True when this history sample is already stored (updating the existing row's value in place).
    /// Two tiers: an in-process key set keeps the hot sync path off the database entirely, and a single
    /// indexed fetch catches re-syncs across launches. `context.insert` is not visible to `fetch` until
    /// the batched save lands, which is exactly why the in-memory tier is needed.
    private func isDuplicateHistory(kind: MeasurementKind, value: Double, timestamp: Date) -> Bool {
        let key = HistoryKey(kind: kind.rawValue, epoch: Int(timestamp.timeIntervalSince1970))
        if seenHistoryKeys.contains(key) { return true }
        seenHistoryKeys.insert(key)

        let kindRaw = kind.rawValue
        let sourceRaw = MeasurementSource.history.rawValue
        var descriptor = FetchDescriptor<Measurement>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.timestamp == timestamp && $0.sourceRaw == sourceRaw
        })
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else { return false }
        // Same slot, possibly refined value (the ring can revise an averaged block). Update in place;
        // no new audit/link row, because nothing new happened.
        existing.value = value
        return true
    }

    /// Append a battery reading to the drainage history, throttled to on-change or a 30-min floor so
    /// the table stays tiny. Rides the same coalesced flush as every other persist (no extra `save()`).
    private func recordBatterySample(_ percent: Int) {
        guard (0...100).contains(percent) else { return }   // guard the Device()-fallback default / garbage
        let now = Date()
        let changed = percent != lastBatteryPercent
        let floorElapsed = lastBatteryLogAt.map { now.timeIntervalSince($0) >= batteryMinInterval } ?? true
        guard changed || floorElapsed else { return }
        context.insert(BatterySample(percent: percent, timestamp: now))
        lastBatteryPercent = percent
        lastBatteryLogAt = now
    }

    /// Record the ring's firmware version on the current Device row (idempotent — no-op if unchanged).
    private func persistFirmwareVersion(_ version: String) {
        guard let device = DeviceRepository.current(context: context), device.firmwareVersion != version else { return }
        device.firmwareVersion = version
    }

    /// Upsert a sleep session by night, appending this packet's per-minute stage blocks and
    /// recomputing session bounds. The ring streams ~20 timeline packets (15 samples each) per
    /// night, so blocks must accumulate into one session rather than spawning a session per
    /// packet. Mirrors `persistence._on_sleep_timeline`.
    private func persistSleepTimeline(start: Date, stages: [SleepStage]) {
        let calendar = Calendar.current

        // Group packets by the waking-day boundary (sleep from 7 PM rolls to the next morning) so a
        // night that starts before midnight lands under the morning of waking. See
        // `Calendar.wakingDay(forSleepStart:)`.
        let dateKey = calendar.wakingDay(forSleepStart: start)

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
