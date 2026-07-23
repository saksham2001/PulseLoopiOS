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

    /// Stale-state guard: a persisted "connected"/"connecting" must not survive a process restart —
    /// the live BLE link is gone, so the UI would otherwise show a false "Connected" until a real
    /// connection re-confirms it. Reset such rows on launch. (Android stale-state-guard parity.)
    @MainActor
    static func resetStaleConnectionState(context: ModelContext) {
        for device in devices(context: context) where device.state == .connected || device.state == .connecting {
            device.state = .disconnected
        }
        try? context.save()
    }
}

enum MetricsRepository {
    @MainActor
    static func activityRows(context: ModelContext) -> [ActivityDaily] {
        let descriptor = FetchDescriptor<ActivityDaily>(sortBy: [SortDescriptor(\.date)])
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
    static func latestMeasurement(kind: MeasurementKind, context: ModelContext) -> Measurement? {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Measurements of one kind within `[start, end]`, newest-first, capped at `limit`. Database
    /// predicate + sort + limit — no full-table scan. Used for the 24h Today/Vitals windows.
    @MainActor
    static func measurements(kind: MeasurementKind, start: Date, end: Date, limit: Int = 500, context: ModelContext) -> [Measurement] {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw && $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Battery-history readings within `[start, end]`, oldest-first for a left-to-right chart axis,
    /// capped at `limit`. Database predicate + sort + limit against the `timestamp` index — no
    /// full-table scan. Feeds the Wearable screen's drainage chart.
    @MainActor
    static func batterySamples(start: Date, end: Date, limit: Int = 1000, context: ModelContext) -> [BatterySample] {
        var descriptor = FetchDescriptor<BatterySample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All measurements of one kind, newest-first (demo mode keeps full history, no time window).
    @MainActor
    static func measurementsAll(kind: MeasurementKind, context: ModelContext) -> [Measurement] {
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Oldest measurement timestamp across all kinds (for the calibration "Day X of N" counter).
    /// `fetchLimit: 1` ascending — one row, not the whole table.
    @MainActor
    static func oldestMeasurementTimestamp(context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<Measurement>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.timestamp
    }

    /// Whether any mock measurement exists (demo-mode detection). `fetchLimit: 1` predicated probe.
    @MainActor
    static func hasMockMeasurement(context: ModelContext) -> Bool {
        let mockRaw = MeasurementSource.mock.rawValue
        var descriptor = FetchDescriptor<Measurement>(predicate: #Predicate { $0.sourceRaw == mockRaw })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }

    /// Whether any mock measurement of a specific kind exists. `fetchLimit: 1` predicated probe —
    /// matches the old per-kind `rows.contains { sourceRaw == mock }` demo detection in rangeSamples.
    @MainActor
    static func hasMockMeasurement(kind: MeasurementKind, context: ModelContext) -> Bool {
        let mockRaw = MeasurementSource.mock.rawValue
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<Measurement>(predicate: #Predicate { $0.sourceRaw == mockRaw && $0.kindRaw == raw })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
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
    static func latestSession(context: ModelContext) -> SleepSession? {
        let descriptor = FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.startAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.first
    }
    
    @MainActor
    static func blocks(sessionId: UUID, context: ModelContext) -> [SleepStageBlock] {
        let descriptor = FetchDescriptor<SleepStageBlock>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.startMinute)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}

enum ActivityRepository {
    @MainActor
    static func sessions(context: ModelContext) -> [ActivitySession] {
        let descriptor = FetchDescriptor<ActivitySession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @MainActor
    static func samples(sessionId: UUID, context: ModelContext) -> [ActivitySample] {
        let descriptor = FetchDescriptor<ActivitySample>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func gpsPoints(sessionId: UUID, context: ModelContext) -> [ActivityGpsPoint] {
        let descriptor = FetchDescriptor<ActivityGpsPoint>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func events(sessionId: UUID, context: ModelContext) -> [ActivityEvent] {
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Newest sample of a kind (optionally restricted to one source) for a session — a
    /// predicate + `fetchLimit 1` probe, so hot paths (live tiles, stream-health checks) never
    /// pay for the whole table.
    @MainActor
    static func latestSample(sessionId: UUID, kind: String, source: String? = nil, context: ModelContext) -> ActivitySample? {
        var descriptor: FetchDescriptor<ActivitySample>
        if let source {
            descriptor = FetchDescriptor<ActivitySample>(
                predicate: #Predicate { $0.sessionId == sessionId && $0.kind == kind && $0.source == source },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<ActivitySample>(
                predicate: #Predicate { $0.sessionId == sessionId && $0.kind == kind },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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

/// Summed nutrition for one day. Optional nutrients are nil when *no* entry that day reported
/// them (unknown ≠ 0); otherwise the sum over the entries that did.
struct NutritionDayTotals: Equatable {
    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var fiberG: Double? = nil
    var sugarG: Double? = nil
    var sodiumMg: Double? = nil
    var entryCount: Int = 0
}

enum NutritionRepository {
    /// LRU cap for the Open Food Facts product cache.
    nonisolated static let maxCachedProducts = 500

    @MainActor
    static func entries(on date: Date, context: ModelContext) -> [MealEntry] {
        let day = Calendar.current.startOfDay(for: date)
        let descriptor = FetchDescriptor<MealEntry>(
            predicate: #Predicate { $0.date == day },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Entries whose day-bucket falls in `[start, end)` (both are normalized to startOfDay).
    @MainActor
    static func entries(from start: Date, to end: Date, context: ModelContext) -> [MealEntry] {
        let lower = Calendar.current.startOfDay(for: start)
        let upper = Calendar.current.startOfDay(for: end)
        let descriptor = FetchDescriptor<MealEntry>(
            predicate: #Predicate { $0.date >= lower && $0.date < upper },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func entry(id: UUID, context: ModelContext) -> MealEntry? {
        var descriptor = FetchDescriptor<MealEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Whether any meal has ever been logged (drives the first-run explainer card). Probe, not a scan.
    @MainActor
    static func hasAnyEntry(context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<MealEntry>()
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }

    /// Most recent `updatedAt` across all meal entries — a cheap change stamp for rebuild
    /// signatures (insert, edit, and re-dated entries all bump it). `fetchLimit 1` probe.
    @MainActor
    static func latestEntryUpdate(context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<MealEntry>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.updatedAt
    }

    /// Summed totals for a day, computed at read time (≤ ~a dozen rows — matches the app's
    /// lazy "today is recomputed at read time" convention; no stored daily row to keep in sync).
    @MainActor
    static func dayTotals(on date: Date, context: ModelContext) -> NutritionDayTotals {
        totals(of: entries(on: date, context: context))
    }

    static func totals(of entries: [MealEntry]) -> NutritionDayTotals {
        var result = NutritionDayTotals()
        for entry in entries {
            result.calories += entry.calories
            result.proteinG += entry.proteinG
            result.carbsG += entry.carbsG
            result.fatG += entry.fatG
            if let fiber = entry.fiberG { result.fiberG = (result.fiberG ?? 0) + fiber }
            if let sugar = entry.sugarG { result.sugarG = (result.sugarG ?? 0) + sugar }
            if let sodium = entry.sodiumMg { result.sodiumMg = (result.sodiumMg ?? 0) + sodium }
            result.entryCount += 1
        }
        return result
    }

    @MainActor
    static func insert(_ entry: MealEntry, context: ModelContext) {
        context.insert(entry)
        try? context.save()
        PulseDataChange.shared.notify()
    }

    /// Save after in-place edits to `entry` (the caller mutated the row already).
    @MainActor
    static func update(_ entry: MealEntry, context: ModelContext) {
        entry.updatedAt = Date()
        try? context.save()
        PulseDataChange.shared.notify()
    }

    @MainActor
    static func delete(id: UUID, context: ModelContext) {
        guard let row = entry(id: id, context: context) else { return }
        context.delete(row)
        try? context.save()
        // Best-effort removal of the exported dietary samples (no-op when export is off —
        // orphaned samples in that case are a documented limitation).
        if AppleHealthPrefsStore.shared.prefs.masterEnabled && AppleHealthPrefsStore.shared.prefs.syncNutrition {
            HealthSyncService.shared.deleteExportedMeal(entryId: id)
        }
        PulseDataChange.shared.notify()
    }

    // MARK: Open Food Facts product cache

    @MainActor
    static func cachedProduct(code: String, context: ModelContext) -> CachedFoodProduct? {
        var descriptor = FetchDescriptor<CachedFoodProduct>(predicate: #Predicate { $0.code == code })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Most recently used cached products for the quick-log "recent foods" list.
    @MainActor
    static func recentProducts(limit: Int = 12, context: ModelContext) -> [CachedFoodProduct] {
        var descriptor = FetchDescriptor<CachedFoodProduct>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Mark a cached product as used (bumps the frequency/recency signals). Does not save —
    /// callers batch the save with the meal insert.
    @MainActor
    static func touchProduct(_ product: CachedFoodProduct) {
        product.useCount += 1
        product.lastUsedAt = Date()
    }

    /// Insert or refresh a fetched product in the cache (keyed on its OFF code), keeping the
    /// LRU bounded. Saves — cache freshness shouldn't depend on a later meal insert.
    @discardableResult
    @MainActor
    static func upsertCachedProduct(_ product: FoodProduct, context: ModelContext) -> CachedFoodProduct {
        if let existing = cachedProduct(code: product.code, context: context) {
            existing.name = product.name
            existing.brand = product.brand
            existing.energyKcal100g = product.energyKcal100g
            existing.protein100g = product.protein100g
            existing.carbs100g = product.carbs100g
            existing.fat100g = product.fat100g
            existing.fiber100g = product.fiber100g
            existing.sugars100g = product.sugars100g
            existing.saturatedFat100g = product.saturatedFat100g
            existing.sodiumMg100g = product.sodiumMg100g
            existing.servingSizeText = product.servingSizeText
            existing.servingQuantityG = product.servingQuantityG
            existing.fetchedAt = Date()
            try? context.save()
            return existing
        }
        let fresh = product.asCachedProduct()
        context.insert(fresh)
        try? context.save()
        pruneProductCache(context: context)
        return fresh
    }

    /// Keep the product cache a bounded LRU: drop least-recently-used rows beyond the cap.
    @MainActor
    static func pruneProductCache(maxRows: Int = maxCachedProducts, context: ModelContext) {
        var descriptor = FetchDescriptor<CachedFoodProduct>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        descriptor.fetchOffset = maxRows
        let stale = (try? context.fetch(descriptor)) ?? []
        guard !stale.isEmpty else { return }
        for row in stale { context.delete(row) }
        try? context.save()
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

    /// Cap the raw-packet debug table to its most recent `maxRows` rows, deleting older ones.
    /// `RawPacketRow` is a DEBUG-only byte trace that otherwise grows without bound (one row per
    /// BLE packet); this keeps it a rolling window so it can't bloat the store or slow the Debug
    /// feed. Does NOT save — the caller batches the save with its own writes.
    @MainActor
    static func pruneRawPackets(maxRows: Int, context: ModelContext) {
        var descriptor = FetchDescriptor<RawPacketRow>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchOffset = maxRows          // skip the rows we want to keep…
        let stale = (try? context.fetch(descriptor)) ?? []   // …delete everything older
        guard !stale.isEmpty else { return }
        for row in stale { context.delete(row) }
    }
}
