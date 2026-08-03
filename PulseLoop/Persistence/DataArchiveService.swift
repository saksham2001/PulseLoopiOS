import Foundation
import SwiftData

/// Errors surfaced to the Backup UI. `Sendable` + `nonisolated` so they can cross the detached
/// encode/decode task boundary.
nonisolated enum DataArchiveError: LocalizedError, Sendable {
    case unsupportedVersion(found: Int, supported: Int)
    case invalidFile(details: String?)
    case duplicateKeys(entity: String)
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(found, supported):
            return "This file was exported by a newer version of PulseLoop (format \(found); this app reads up to \(supported)). Update the app and try again."
        case .invalidFile:
            return "This file isn't a PulseLoop export, or it's damaged."
        case let .duplicateKeys(entity):
            return "This file contains duplicate \(entity) entries and can't be imported."
        case .operationInProgress:
            return "Another export or import is already running. Wait for it to finish and try again."
        }
    }
}

/// Full-app export/import: everything in SwiftData plus the settings blobs and coach attachments,
/// as one plain JSON file (see `PulseArchive`). Privacy-first — nothing leaves the device unless
/// the user shares the file themselves. Keychain API keys are deliberately excluded.
///
/// Concurrency: SwiftData stays on the main actor (the whole app runs on `container.mainContext`),
/// but the work is chunked with `Task.yield()` so the UI never freezes, and the expensive JSON
/// encode/decode runs off-main via `Task.detached`.
@MainActor
enum DataArchiveService {
    /// UserDefaults blobs included in the archive. Deliberately excluded: Apple Health watermarks
    /// (device-local — reset after import instead), Keychain API keys (secrets), remembered-ring
    /// BLE identity and widget snapshots (device-local/derived).
    static let settingsKeys: [String] = [
        "pulseloop.metricprefs.v1",
        "pulseloop.workoutprefs.v1",
        "pulseloop.calibration.v1",
        "pulseloop.coach.settings.v1",
        "pulseloop.applehealth.prefs.v1",
        ReadinessPrefsStore.prefsKey
    ]

    /// Rows processed between `Task.yield()`s while mapping models to DTOs during export.
    private static let chunkSize = 2000

    /// Re-entrancy guard. The Privacy screen can be left mid-run (the nav pop gesture bypasses
    /// SwiftUI `.disabled`) and re-entered with fresh view state, so the service — not the view —
    /// must refuse a second concurrent run: two interleaved imports would cross their
    /// autosave save/restore defers and break the single-transaction guarantee.
    private static var isBusy = false

    private static func beginExclusiveOperation() throws {
        guard !isBusy else { throw DataArchiveError.operationInProgress }
        isBusy = true
    }

    // MARK: - Export

    /// Snapshots the entire store into archive JSON. Safe to call from the UI; yields regularly.
    static func exportArchive(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        attachmentsDirectory: URL? = nil
    ) async throws -> Data {
        try beginExclusiveOperation()
        defer { isBusy = false }
        let archive = try await buildArchive(
            context: context,
            defaults: defaults,
            attachmentsDirectory: attachmentsDirectory ?? Self.defaultAttachmentsDirectory()
        )
        // Encoding tens of thousands of rows is the single most expensive CPU step — run it off-main.
        return try await Task.detached(priority: .userInitiated) {
            try ArchiveCoding.makeEncoder().encode(archive)
        }.value
    }

    /// Exports to a shareable temp file (`pulseloop-export-<date>.json`) for the share sheet.
    static func exportFile(context: ModelContext) async throws -> URL {
        let data = try await exportArchive(context: context)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulseloop-export-\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func buildArchive(
        context: ModelContext,
        defaults: UserDefaults,
        attachmentsDirectory: URL
    ) async throws -> PulseArchive {
        let devices = try await collect(Device.self, context) { ArchiveDevice($0) }
        let activityDailies = try await collect(ActivityDaily.self, context) { ArchiveActivityDaily($0) }
        let measurements = try await collect(PulseLoop.Measurement.self, context) { ArchiveMeasurement($0) }
        let batterySamples = try await collect(BatterySample.self, context) { ArchiveBatterySample($0) }
        let sleepSessions = try await collect(SleepSession.self, context) { ArchiveSleepSession($0) }
        let sleepStageBlocks = try await collect(SleepStageBlock.self, context) { ArchiveSleepStageBlock($0) }
        let readinessDailies = try await collect(ReadinessDaily.self, context) { ArchiveReadinessDaily($0) }
        let rawPackets = try await collect(RawPacketRow.self, context) { ArchiveRawPacket($0) }
        let derivedUpdates = try await collect(DerivedUpdateRow.self, context) { ArchiveDerivedUpdate($0) }
        let userProfiles = try await collect(UserProfile.self, context) { ArchiveUserProfile($0) }
        let userGoals = try await collect(UserGoal.self, context) { ArchiveUserGoal($0) }
        let deviceMeasurementConfigs = try await collect(DeviceMeasurementConfig.self, context) { ArchiveDeviceMeasurementConfig($0) }
        let activitySessions = try await collect(ActivitySession.self, context) { ArchiveActivitySession($0) }
        let activitySamples = try await collect(ActivitySample.self, context) { ArchiveActivitySample($0) }
        let activityBucketSamples = try await collect(ActivityBucketSample.self, context) { ArchiveActivityBucketSample($0) }
        let activityGpsPoints = try await collect(ActivityGpsPoint.self, context) { ArchiveActivityGpsPoint($0) }
        let activityEvents = try await collect(ActivityEvent.self, context) { ArchiveActivityEvent($0) }
        let activitySensorPollEvents = try await collect(ActivitySensorPollEvent.self, context) { ArchiveActivitySensorPollEvent($0) }
        let coachConversations = try await collect(CoachConversation.self, context) { ArchiveCoachConversation($0) }
        let coachMessages = try await collect(CoachMessage.self, context) { ArchiveCoachMessage($0) }
        let coachMemories = try await collect(CoachMemory.self, context) { ArchiveCoachMemory($0) }
        let coachToolCalls = try await collect(CoachToolCall.self, context) { ArchiveCoachToolCall($0) }
        let coachNotificationRecords = try await collect(CoachNotificationRecord.self, context) { ArchiveCoachNotificationRecord($0) }
        let coachSummaries = try await collect(CoachSummary.self, context) { ArchiveCoachSummary($0) }
        let wearableLogs = try await collect(WearableLog.self, context) { ArchiveWearableLog($0) }

        var settings: [String: String] = [:]
        for key in settingsKeys {
            if let data = defaults.data(forKey: key), let blob = String(data: data, encoding: .utf8) {
                settings[key] = blob
            }
        }

        let counts: [String: Int] = [
            "devices": devices.count,
            "activityDailies": activityDailies.count,
            "measurements": measurements.count,
            "batterySamples": batterySamples.count,
            "sleepSessions": sleepSessions.count,
            "sleepStageBlocks": sleepStageBlocks.count,
            "readinessDailies": readinessDailies.count,
            "rawPackets": rawPackets.count,
            "derivedUpdates": derivedUpdates.count,
            "userProfiles": userProfiles.count,
            "userGoals": userGoals.count,
            "deviceMeasurementConfigs": deviceMeasurementConfigs.count,
            "activitySessions": activitySessions.count,
            "activitySamples": activitySamples.count,
            "activityBucketSamples": activityBucketSamples.count,
            "activityGpsPoints": activityGpsPoints.count,
            "activityEvents": activityEvents.count,
            "activitySensorPollEvents": activitySensorPollEvents.count,
            "coachConversations": coachConversations.count,
            "coachMessages": coachMessages.count,
            "coachMemories": coachMemories.count,
            "coachToolCalls": coachToolCalls.count,
            "coachNotificationRecords": coachNotificationRecords.count,
            "coachSummaries": coachSummaries.count,
            "wearableLogs": wearableLogs.count
        ]

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        return PulseArchive(
            formatVersion: PulseArchive.currentFormatVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            counts: counts,
            devices: devices,
            activityDailies: activityDailies,
            measurements: measurements,
            batterySamples: batterySamples,
            sleepSessions: sleepSessions,
            sleepStageBlocks: sleepStageBlocks,
            readinessDailies: readinessDailies,
            rawPackets: rawPackets,
            derivedUpdates: derivedUpdates,
            userProfiles: userProfiles,
            userGoals: userGoals,
            deviceMeasurementConfigs: deviceMeasurementConfigs,
            activitySessions: activitySessions,
            activitySamples: activitySamples,
            activityBucketSamples: activityBucketSamples,
            activityGpsPoints: activityGpsPoints,
            activityEvents: activityEvents,
            activitySensorPollEvents: activitySensorPollEvents,
            coachConversations: coachConversations,
            coachMessages: coachMessages,
            coachMemories: coachMemories,
            coachToolCalls: coachToolCalls,
            coachNotificationRecords: coachNotificationRecords,
            coachSummaries: coachSummaries,
            wearableLogs: wearableLogs,
            settings: settings,
            attachments: collectAttachments(from: attachmentsDirectory)
        )
    }

    /// Fetches every row of one model and maps it to its DTO, yielding between chunks so the main
    /// thread stays responsive during large exports.
    private static func collect<T: PersistentModel, D>(
        _ type: T.Type,
        _ context: ModelContext,
        map: (T) -> D
    ) async throws -> [D] {
        let rows = try context.fetch(FetchDescriptor<T>())
        var out: [D] = []
        out.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            out.append(map(row))
            if index.isMultiple(of: chunkSize) { await Task.yield() }
        }
        return out
    }

    private static func collectAttachments(from directory: URL) -> [ArchiveAttachment] {
        // Skip hidden files (.DS_Store & co.) — the import validator rejects dot-file names, so
        // exporting one would make the whole archive un-importable.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ArchiveAttachment(file: url.lastPathComponent, base64: data.base64EncodedString())
        }
    }

    // MARK: - Import

    /// Replaces ALL app data with the archive's contents. Fully validates before touching anything;
    /// wipe + inserts commit in a single save, with rollback on any failure — a bad file can never
    /// leave the store half-imported.
    ///
    /// `refreshStores: false` lets unit tests run against injected defaults/directories without
    /// touching the shared singletons.
    static func importArchive(
        _ data: Data,
        context: ModelContext,
        defaults: UserDefaults = .standard,
        attachmentsDirectory: URL? = nil,
        refreshStores: Bool = true
    ) async throws {
        try beginExclusiveOperation()
        defer { isBusy = false }

        // 1. Cheap version probe first, so a newer-format file gets a clear error instead of a
        //    generic decode failure.
        guard let probe = try? JSONDecoder().decode(ArchiveVersionProbe.self, from: data) else {
            throw DataArchiveError.invalidFile(details: "missing formatVersion")
        }
        guard probe.formatVersion <= PulseArchive.currentFormatVersion else {
            throw DataArchiveError.unsupportedVersion(found: probe.formatVersion, supported: PulseArchive.currentFormatVersion)
        }

        // 2. Full decode off-main. Nothing has been mutated yet, so any failure here is safe.
        let archive: PulseArchive
        do {
            archive = try await Task.detached(priority: .userInitiated) {
                try ArchiveCoding.makeDecoder().decode(PulseArchive.self, from: data)
            }.value
        } catch {
            throw DataArchiveError.invalidFile(details: String(describing: error))
        }

        // 3. Validate in memory (unique keys, attachment names) before mutating.
        try validate(archive)

        // 4. Wipe + insert as one transaction. The mutation window is deliberately SYNCHRONOUS
        //    (no awaits): the app's always-on subscribers share this same mainContext and call
        //    save() on their own events, so any suspension point here would let them commit a
        //    half-imported store. With no awaits, main-actor reentrancy is impossible; autosave is
        //    off as belt-and-braces; single save at the end; rollback discards everything
        //    (deletes included) on failure. Let the spinner overlay render first, though.
        await Task.yield()
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }
        do {
            try wipeAllData(context: context)
            insertAll(archive, context: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // 5. Side stores, only after the SwiftData commit succeeded. An attachment write failure
        //    degrades one chat image, not the whole import.
        applySettings(archive.settings, defaults: defaults)
        restoreAttachments(archive.attachments, to: attachmentsDirectory ?? Self.defaultAttachmentsDirectory())
        if refreshStores {
            refreshSharedStores()
        }

        // 6. Self-heal readiness history. A v1 archive predates the table entirely, and a v2 one may
        //    carry rows scored by an older algorithm version. Both cases recompute from the
        //    measurements we just restored; rows already at the current version are skipped.
        ReadinessService.backfill(days: 90, context: context)
    }

    /// Whether any of the 25 model tables has at least one row — gates the destructive
    /// "Replace all data?" confirmation.
    static func hasAnyData(context: ModelContext) -> Bool {
        func has<T: PersistentModel>(_ type: T.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<T>())) ?? 0) > 0
        }
        return has(Device.self) || has(ActivityDaily.self) || has(PulseLoop.Measurement.self)
            || has(BatterySample.self) || has(SleepSession.self) || has(SleepStageBlock.self)
            || has(ReadinessDaily.self)
            || has(RawPacketRow.self) || has(DerivedUpdateRow.self) || has(UserProfile.self)
            || has(UserGoal.self) || has(DeviceMeasurementConfig.self) || has(ActivitySession.self)
            || has(ActivitySample.self) || has(ActivityBucketSample.self) || has(ActivityGpsPoint.self)
            || has(ActivityEvent.self) || has(ActivitySensorPollEvent.self) || has(CoachConversation.self)
            || has(CoachMessage.self) || has(CoachMemory.self) || has(CoachToolCall.self)
            || has(CoachNotificationRecord.self) || has(CoachSummary.self) || has(WearableLog.self)
    }

    /// Deletes every row of every model in the schema — all 25 types, unlike `SeedData.clearAll`
    /// (which predates six of them). Tracked deletes, no save, and deliberately synchronous — see
    /// the atomicity note in `importArchive`.
    static func wipeAllData(context: ModelContext) throws {
        try deleteAll(Device.self, context)
        try deleteAll(ActivityDaily.self, context)
        try deleteAll(PulseLoop.Measurement.self, context)
        try deleteAll(BatterySample.self, context)
        try deleteAll(SleepSession.self, context)
        try deleteAll(SleepStageBlock.self, context)
        try deleteAll(ReadinessDaily.self, context)
        try deleteAll(RawPacketRow.self, context)
        try deleteAll(DerivedUpdateRow.self, context)
        try deleteAll(UserProfile.self, context)
        try deleteAll(UserGoal.self, context)
        try deleteAll(DeviceMeasurementConfig.self, context)
        try deleteAll(ActivitySession.self, context)
        try deleteAll(ActivitySample.self, context)
        try deleteAll(ActivityBucketSample.self, context)
        try deleteAll(ActivityGpsPoint.self, context)
        try deleteAll(ActivityEvent.self, context)
        try deleteAll(ActivitySensorPollEvent.self, context)
        try deleteAll(CoachConversation.self, context)
        try deleteAll(CoachMessage.self, context)
        try deleteAll(CoachMemory.self, context)
        try deleteAll(CoachToolCall.self, context)
        try deleteAll(CoachNotificationRecord.self, context)
        try deleteAll(CoachSummary.self, context)
        try deleteAll(WearableLog.self, context)
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }

    private static func insertAll(_ archive: PulseArchive, context: ModelContext) {
        insert(archive.devices, context)
        insert(archive.activityDailies, context)
        insert(archive.measurements, context)
        insert(archive.batterySamples, context)
        insert(archive.sleepSessions, context)
        insert(archive.sleepStageBlocks, context)
        insert(archive.readinessDailies ?? [], context)
        insert(archive.rawPackets, context)
        insert(archive.derivedUpdates, context)
        insert(archive.userProfiles, context)
        insert(archive.userGoals, context)
        insert(archive.deviceMeasurementConfigs, context)
        insert(archive.activitySessions, context)
        insert(archive.activitySamples, context)
        insert(archive.activityBucketSamples, context)
        insert(archive.activityGpsPoints, context)
        insert(archive.activityEvents, context)
        insert(archive.activitySensorPollEvents, context)
        insert(archive.coachConversations, context)
        insert(archive.coachMessages, context)
        insert(archive.coachMemories, context)
        insert(archive.coachToolCalls, context)
        insert(archive.coachNotificationRecords, context)
        insert(archive.coachSummaries, context)
        insert(archive.wearableLogs, context)
    }

    private static func insert(_ rows: [some ArchiveInsertable], _ context: ModelContext) {
        for row in rows {
            row.insert(into: context)
        }
    }

    // MARK: - Validation

    private static func validate(_ archive: PulseArchive) throws {
        try requireUnique(archive.devices.map(\.id), entity: "device")
        try requireUnique(archive.activityDailies.map(\.id), entity: "daily activity")
        try requireUnique(archive.measurements.map(\.id), entity: "measurement")
        try requireUnique(archive.batterySamples.map(\.id), entity: "battery sample")
        try requireUnique(archive.sleepSessions.map(\.id), entity: "sleep session")
        try requireUnique(archive.sleepStageBlocks.map(\.id), entity: "sleep stage")
        try requireUnique((archive.readinessDailies ?? []).map(\.id), entity: "readiness score")
        try requireUnique(archive.rawPackets.map(\.id), entity: "raw packet")
        try requireUnique(archive.derivedUpdates.map(\.id), entity: "derived update")
        try requireUnique(archive.userProfiles.map(\.id), entity: "profile")
        try requireUnique(archive.userGoals.map(\.id), entity: "goal")
        try requireUnique(archive.deviceMeasurementConfigs.map(\.deviceId), entity: "measurement config")
        try requireUnique(archive.activitySessions.map(\.id), entity: "workout")
        try requireUnique(archive.activitySamples.map(\.id), entity: "workout sample")
        try requireUnique(archive.activityBucketSamples.map(\.startEpoch), entity: "activity bucket")
        try requireUnique(archive.activityGpsPoints.map(\.id), entity: "GPS point")
        try requireUnique(archive.activityEvents.map(\.id), entity: "workout event")
        try requireUnique(archive.activitySensorPollEvents.map(\.id), entity: "sensor poll")
        try requireUnique(archive.coachConversations.map(\.id), entity: "conversation")
        try requireUnique(archive.coachMessages.map(\.id), entity: "coach message")
        try requireUnique(archive.coachMemories.map(\.id), entity: "coach memory")
        try requireUnique(archive.coachToolCalls.map(\.id), entity: "tool call")
        try requireUnique(archive.coachNotificationRecords.map(\.id), entity: "notification record")
        try requireUnique(archive.coachSummaries.map(\.id), entity: "coach summary")
        try requireUnique(archive.wearableLogs.map(\.id), entity: "wearable log")

        // Attachment names come from the file — never let one escape coach_attachments/.
        for attachment in archive.attachments {
            let name = attachment.file
            if name.isEmpty || name.contains("/") || name.contains("..") || name.hasPrefix(".") {
                throw DataArchiveError.invalidFile(details: "unsafe attachment name: \(name)")
            }
        }
    }

    private static func requireUnique<K: Hashable>(_ keys: [K], entity: String) throws {
        guard Set(keys).count == keys.count else {
            throw DataArchiveError.duplicateKeys(entity: entity)
        }
    }

    // MARK: - Settings, attachments, stores

    private static func applySettings(_ settings: [String: String], defaults: UserDefaults) {
        for key in settingsKeys {
            if let blob = settings[key], let data = blob.data(using: .utf8) {
                defaults.set(data, forKey: key)
            } else {
                // The source device never customized this blob — return to defaults here too.
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func restoreAttachments(_ attachments: [ArchiveAttachment], to directory: URL) {
        let fm = FileManager.default
        // Replace the directory wholesale: stale files from the wiped dataset must not linger.
        try? fm.removeItem(at: directory)
        guard !attachments.isEmpty else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.base64) else { continue }
            try? data.write(to: directory.appendingPathComponent(attachment.file), options: .atomic)
        }
    }

    /// Re-reads the shared settings singletons from the (just-imported) UserDefaults blobs so the
    /// change shows without a relaunch — same trick as the factory reset. Also re-stamps the Apple
    /// Health watermarks to "now": importing history must not trigger a surprise full re-export
    /// into this device's Health store.
    private static func refreshSharedStores() {
        let defaults = UserDefaults.standard
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        MetricPrefsStore.shared.settings = decode(MetricPrefs.self, "pulseloop.metricprefs.v1") ?? .default
        WorkoutPrefsStore.shared.settings = decode(WorkoutPrefs.self, "pulseloop.workoutprefs.v1") ?? .default
        CalibrationStore.shared.settings = decode(Calibration.self, "pulseloop.calibration.v1") ?? .default
        CoachSettingsStore.shared.settings = decode(CoachSettings.self, "pulseloop.coach.settings.v1") ?? .default
        AppleHealthPrefsStore.shared.prefs = decode(AppleHealthPrefs.self, "pulseloop.applehealth.prefs.v1") ?? .default
        if AppleHealthPrefsStore.shared.prefs.masterEnabled {
            AppleHealthPrefsStore.shared.resetWatermarks(to: Date())
        }
        #if DEBUG
        // The factory-reset flow re-arms `forceOnboarding`; an imported completed profile should
        // land on the main UI, so disarm it.
        defaults.removeObject(forKey: "forceOnboarding")
        #endif
    }

    private static func defaultAttachmentsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("coach_attachments", isDirectory: true)
    }
}

/// Shared shape of the 25 DTOs' model-restoring side, so `insertAll` can chunk generically.
@MainActor
protocol ArchiveInsertable {
    func insert(into context: ModelContext)
}

extension ArchiveDevice: ArchiveInsertable {}
extension ArchiveActivityDaily: ArchiveInsertable {}
extension ArchiveMeasurement: ArchiveInsertable {}
extension ArchiveBatterySample: ArchiveInsertable {}
extension ArchiveSleepSession: ArchiveInsertable {}
extension ArchiveSleepStageBlock: ArchiveInsertable {}
extension ArchiveReadinessDaily: ArchiveInsertable {}
extension ArchiveRawPacket: ArchiveInsertable {}
extension ArchiveDerivedUpdate: ArchiveInsertable {}
extension ArchiveUserProfile: ArchiveInsertable {}
extension ArchiveUserGoal: ArchiveInsertable {}
extension ArchiveDeviceMeasurementConfig: ArchiveInsertable {}
extension ArchiveActivitySession: ArchiveInsertable {}
extension ArchiveActivitySample: ArchiveInsertable {}
extension ArchiveActivityBucketSample: ArchiveInsertable {}
extension ArchiveActivityGpsPoint: ArchiveInsertable {}
extension ArchiveActivityEvent: ArchiveInsertable {}
extension ArchiveActivitySensorPollEvent: ArchiveInsertable {}
extension ArchiveCoachConversation: ArchiveInsertable {}
extension ArchiveCoachMessage: ArchiveInsertable {}
extension ArchiveCoachMemory: ArchiveInsertable {}
extension ArchiveCoachToolCall: ArchiveInsertable {}
extension ArchiveCoachNotificationRecord: ArchiveInsertable {}
extension ArchiveCoachSummary: ArchiveInsertable {}
extension ArchiveWearableLog: ArchiveInsertable {}
