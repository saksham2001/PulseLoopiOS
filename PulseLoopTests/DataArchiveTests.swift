import XCTest
import SwiftData
@testable import PulseLoop

/// Locks down the full-app export/import archive: a complete round trip over all 25 models,
/// wipe completeness, version/corruption rejection (without data loss), and the settings +
/// attachment side channels. Hermetic — in-memory SwiftData, suite-scoped UserDefaults, temp dirs.
@MainActor
final class DataArchiveTests: XCTestCase {

    // MARK: - Helpers

    private func count<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    /// One row of every model type `SeedData.seedDemo` does NOT create, so seed + these = all 25.
    private func insertModelsMissingFromSeed(_ context: ModelContext, deviceId: UUID) {
        context.insert(BatterySample(percent: 57, timestamp: Date(timeIntervalSince1970: 1_750_000_000)))
        context.insert(DeviceMeasurementConfig(deviceId: deviceId))
        let bucket = ActivityBucketSample(
            timestamp: Date(timeIntervalSince1970: 1_750_000_900),
            steps: 123,
            distanceMeters: 88,
            source: "ring_history"
        )
        // Diverge the stored unique key from what the init derives from the timestamp, so the
        // round-trip test proves the importer restores the STORED value instead of re-deriving it.
        bucket.startEpoch += 7
        context.insert(bucket)
        context.insert(ActivitySensorPollEvent(sessionId: UUID(), kind: "hr", status: "success", value: 62))
        context.insert(CoachMemory(key: "prefers", value: "morning runs"))
        context.insert(CoachToolCall(conversationId: UUID(), toolName: "get_hr", label: "Got HR data"))
        context.insert(CoachNotificationRecord(slotRaw: "morning", dateKey: "2026-07-25", title: "Hi", body: "Check in"))
        context.insert(CoachSummary(kind: "today", scopeKey: "2026-07-25", title: "Today", body: "Solid", dataSignature: "sig1"))
        context.insert(WearableLog(category: .sync, level: .info, message: "sync done", metadataJSON: #"{"n":1}"#))
        try? context.save()
    }

    private func assertAllCountsEqual(_ a: ModelContext, _ b: ModelContext, file: StaticString = #filePath, line: UInt = #line) {
        func check<T: PersistentModel>(_ type: T.Type) {
            XCTAssertEqual(count(type, a), count(type, b), "\(T.self) count mismatch", file: file, line: line)
            XCTAssertGreaterThan(count(type, b), 0, "\(T.self) should have rows in this test", file: file, line: line)
        }
        check(Device.self); check(ActivityDaily.self); check(PulseLoop.Measurement.self)
        check(BatterySample.self); check(SleepSession.self); check(SleepStageBlock.self)
        check(RawPacketRow.self); check(DerivedUpdateRow.self); check(UserProfile.self)
        check(UserGoal.self); check(DeviceMeasurementConfig.self); check(ActivitySession.self)
        check(ActivitySample.self); check(ActivityBucketSample.self); check(ActivityGpsPoint.self)
        check(ActivityEvent.self); check(ActivitySensorPollEvent.self); check(CoachConversation.self)
        check(CoachMessage.self); check(CoachMemory.self); check(CoachToolCall.self)
        check(CoachNotificationRecord.self); check(CoachSummary.self); check(WearableLog.self)
        check(CycleDay.self)
    }

    private func makeSuiteDefaults(_ name: String) -> UserDefaults {
        let suite = "DataArchiveTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Round trip

    func testRoundTripRestoresEverything() async throws {
        let source = try TestSupport.makeContext()
        SeedData.seedDemo(source, completeOnboarding: true)
        let device = try XCTUnwrap(try source.fetch(FetchDescriptor<Device>()).first)
        insertModelsMissingFromSeed(source, deviceId: device.id)

        // Snapshot reference values before export.
        let sourceMeasurements = try source.fetch(FetchDescriptor<PulseLoop.Measurement>(sortBy: [SortDescriptor(\.timestamp)]))
        let referenceMeasurement = try XCTUnwrap(sourceMeasurements.first)
        let refID = referenceMeasurement.id
        let refKind = referenceMeasurement.kindRaw
        let refValue = referenceMeasurement.value
        let refTimestamp = referenceMeasurement.timestamp
        let refCapabilities = device.capabilitiesRaw
        let refBucketEpoch = try XCTUnwrap(try source.fetch(FetchDescriptor<ActivityBucketSample>()).first).startEpoch

        let defaults = makeSuiteDefaults(#function)
        let attachmentsDir = try makeTempDirectory()
        let data = try await DataArchiveService.exportArchive(context: source, defaults: defaults, attachmentsDirectory: attachmentsDir)

        // Import into a completely fresh store.
        let target = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(
            data, context: target, defaults: defaults,
            attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )

        assertAllCountsEqual(source, target)

        // Spot-check field-level fidelity: exact UUID, raw strings, ms-tolerant dates.
        let imported = try target.fetch(FetchDescriptor<PulseLoop.Measurement>(predicate: #Predicate { $0.id == refID }))
        let importedMeasurement = try XCTUnwrap(imported.first, "reference measurement must survive with its UUID")
        XCTAssertEqual(importedMeasurement.kindRaw, refKind)
        XCTAssertEqual(importedMeasurement.value, refValue)
        XCTAssertEqual(importedMeasurement.timestamp.timeIntervalSince1970, refTimestamp.timeIntervalSince1970, accuracy: 0.005)

        let importedDevice = try XCTUnwrap(try target.fetch(FetchDescriptor<Device>()).first)
        XCTAssertEqual(importedDevice.id, device.id)
        XCTAssertEqual(importedDevice.capabilitiesRaw, refCapabilities)

        // startEpoch is the bucket's unique upsert key. The fixture deliberately stores a value
        // that differs from what the init would re-derive from the timestamp, so this fails if
        // the importer ever drops the explicit restore.
        let importedBucket = try XCTUnwrap(try target.fetch(FetchDescriptor<ActivityBucketSample>()).first)
        XCTAssertEqual(importedBucket.startEpoch, refBucketEpoch)
        XCTAssertNotEqual(importedBucket.startEpoch, Int(importedBucket.timestamp.timeIntervalSince1970))

        // FK integrity: every child row still points at a parent that exists.
        let sessionIDs = Set(try target.fetch(FetchDescriptor<SleepSession>()).map(\.id))
        for block in try target.fetch(FetchDescriptor<SleepStageBlock>()) {
            XCTAssertTrue(sessionIDs.contains(block.sessionId), "orphaned SleepStageBlock after import")
        }
        let conversationIDs = Set(try target.fetch(FetchDescriptor<CoachConversation>()).map(\.id))
        for message in try target.fetch(FetchDescriptor<CoachMessage>()) {
            XCTAssertTrue(conversationIDs.contains(message.conversationId), "orphaned CoachMessage after import")
        }
    }

    // MARK: - Cycle days

    private func fetchCycleDay(_ key: String, _ context: ModelContext) throws -> CycleDay? {
        let rows = try context.fetch(FetchDescriptor<CycleDay>(predicate: #Predicate { $0.dateString == key }))
        XCTAssertLessThanOrEqual(rows.count, 1, "dateString must stay unique after import")
        return rows.first
    }

    /// Period days, excluded nights and notes are the most sensitive rows in the store, and they
    /// joined the archive after its first format shipped — so lock their round trip down on its
    /// own: export → clear → import restores every row under its `dateString` key, and importing
    /// the same file twice is idempotent.
    func testCycleDaysRoundTripByDateKey() async throws {
        let context = try TestSupport.makeContext()
        let period = CycleDay(date: TestSupport.day(-12), isPeriod: true)
        let disturbed = CycleDay(
            date: TestSupport.day(-3), isDisturbed: true, disturbedAutoDetected: true,
            notes: "Fever 38.5 °C — night excluded"
        )
        let noted = CycleDay(date: TestSupport.day(-1), notes: "Spotting")
        // Simulate a row logged in a timezone 9h ahead: its stored `date` is that zone's midnight,
        // not the local one, while `dateString` is the key computed there. The importer must
        // restore both verbatim — re-deriving them through the init would file the night under
        // the previous day here.
        disturbed.date = disturbed.date.addingTimeInterval(-9 * 3600)
        context.insert(period)
        context.insert(disturbed)
        context.insert(noted)
        try context.save()
        let periodKey = period.dateString
        let notedKey = noted.dateString
        let disturbedKey = disturbed.dateString
        let disturbedDate = disturbed.date
        let disturbedUpdatedAt = disturbed.updatedAt
        XCTAssertNotEqual(
            disturbedKey, CycleDay.key(for: Calendar.current.startOfDay(for: disturbedDate)),
            "fixture must diverge the stored key from what the init would re-derive"
        )

        func assertRestored(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(count(CycleDay.self, context), 3, file: file, line: line)

            let restoredPeriod = try XCTUnwrap(try fetchCycleDay(periodKey, context), file: file, line: line)
            XCTAssertTrue(restoredPeriod.isPeriod, file: file, line: line)
            XCTAssertFalse(restoredPeriod.isDisturbed, file: file, line: line)
            XCTAssertNil(restoredPeriod.notes, file: file, line: line)

            let restoredDisturbed = try XCTUnwrap(try fetchCycleDay(disturbedKey, context), file: file, line: line)
            XCTAssertFalse(restoredDisturbed.isPeriod, file: file, line: line)
            XCTAssertTrue(restoredDisturbed.isDisturbed, file: file, line: line)
            XCTAssertTrue(restoredDisturbed.disturbedAutoDetected, file: file, line: line)
            XCTAssertEqual(restoredDisturbed.notes, "Fever 38.5 °C — night excluded", file: file, line: line)
            XCTAssertEqual(
                restoredDisturbed.date.timeIntervalSince1970, disturbedDate.timeIntervalSince1970, accuracy: 0.005,
                "stored date must be restored, not re-normalized to the local startOfDay", file: file, line: line
            )
            XCTAssertEqual(
                restoredDisturbed.updatedAt.timeIntervalSince1970, disturbedUpdatedAt.timeIntervalSince1970, accuracy: 0.005,
                "updatedAt must not be re-stamped to import time", file: file, line: line
            )

            let restoredNoted = try XCTUnwrap(try fetchCycleDay(notedKey, context), file: file, line: line)
            XCTAssertEqual(restoredNoted.notes, "Spotting", file: file, line: line)
            XCTAssertFalse(restoredNoted.isPeriod, file: file, line: line)
            XCTAssertFalse(restoredNoted.isDisturbed, file: file, line: line)
        }

        let defaults = makeSuiteDefaults(#function)
        let data = try await DataArchiveService.exportArchive(
            context: context, defaults: defaults, attachmentsDirectory: try makeTempDirectory()
        )

        // Clear, then restore into the same store — the "restore onto this device" path, where the
        // unique dateString keys are deleted and re-inserted within one save.
        try DataArchiveService.wipeAllData(context: context)
        try context.save()
        XCTAssertEqual(count(CycleDay.self, context), 0)

        try await DataArchiveService.importArchive(
            data, context: context, defaults: defaults, attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )
        try assertRestored()

        // Importing the same file again must yield the same three rows — not six, not a failed save.
        try await DataArchiveService.importArchive(
            data, context: context, defaults: defaults, attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )
        try assertRestored()
    }

    /// A backup written before cycle tracking existed has no `cycleDays` key at all. It must still
    /// import (the key is optional, not a corruption) and — replace-all semantics — leave the store
    /// with no cycle days, exactly like every other entity absent from the file.
    func testImportAcceptsArchiveWithoutCycleDaysKey() async throws {
        let defaults = makeSuiteDefaults(#function)
        let exported = try await DataArchiveService.exportArchive(
            context: try TestSupport.makeContext(), defaults: defaults, attachmentsDirectory: try makeTempDirectory()
        )
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "cycleDays"), "export must always write the cycleDays key")
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let context = try TestSupport.makeContext()
        context.insert(CycleDay(date: TestSupport.day(-2), isPeriod: true))
        try context.save()
        try await DataArchiveService.importArchive(
            legacy, context: context, defaults: defaults, attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )
        XCTAssertEqual(count(CycleDay.self, context), 0, "replace-all import must not keep rows the file doesn't carry")
    }

    // MARK: - Wipe completeness

    func testWipeAllDataCoversAllModels() async throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true)
        let device = try XCTUnwrap(try context.fetch(FetchDescriptor<Device>()).first)
        insertModelsMissingFromSeed(context, deviceId: device.id)

        try DataArchiveService.wipeAllData(context: context)
        try context.save()

        func assertEmpty<T: PersistentModel>(_ type: T.Type) {
            XCTAssertEqual(count(type, context), 0, "\(T.self) survived wipeAllData")
        }
        assertEmpty(Device.self); assertEmpty(ActivityDaily.self); assertEmpty(PulseLoop.Measurement.self)
        assertEmpty(BatterySample.self); assertEmpty(SleepSession.self); assertEmpty(SleepStageBlock.self)
        assertEmpty(RawPacketRow.self); assertEmpty(DerivedUpdateRow.self); assertEmpty(UserProfile.self)
        assertEmpty(UserGoal.self); assertEmpty(DeviceMeasurementConfig.self); assertEmpty(ActivitySession.self)
        assertEmpty(ActivitySample.self); assertEmpty(ActivityBucketSample.self); assertEmpty(ActivityGpsPoint.self)
        assertEmpty(ActivityEvent.self); assertEmpty(ActivitySensorPollEvent.self); assertEmpty(CoachConversation.self)
        assertEmpty(CoachMessage.self); assertEmpty(CoachMemory.self); assertEmpty(CoachToolCall.self)
        assertEmpty(CoachNotificationRecord.self); assertEmpty(CoachSummary.self); assertEmpty(WearableLog.self)
        assertEmpty(CycleDay.self)
    }

    // MARK: - Rejection without data loss

    func testImportRejectsNewerFormatVersion() async throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: Date(), into: context)
        let before = count(PulseLoop.Measurement.self, context)

        let newer = Data(#"{"formatVersion": 999}"#.utf8)
        do {
            try await DataArchiveService.importArchive(newer, context: context, refreshStores: false)
            XCTFail("expected unsupportedVersion")
        } catch let DataArchiveError.unsupportedVersion(found, supported) {
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, PulseArchive.currentFormatVersion)
        }
        XCTAssertEqual(count(PulseLoop.Measurement.self, context), before, "a rejected file must not touch existing data")
    }

    func testImportRejectsCorruptJSONWithoutDataLoss() async throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: Date(), into: context)
        let before = count(PulseLoop.Measurement.self, context)

        // Not JSON at all.
        do {
            try await DataArchiveService.importArchive(Data("not json".utf8), context: context, refreshStores: false)
            XCTFail("expected invalidFile")
        } catch DataArchiveError.invalidFile {
            // expected
        }

        // Valid JSON, right version, but not an archive (truncated).
        do {
            try await DataArchiveService.importArchive(Data(#"{"formatVersion": 1}"#.utf8), context: context, refreshStores: false)
            XCTFail("expected invalidFile")
        } catch DataArchiveError.invalidFile {
            // expected
        }

        XCTAssertEqual(count(PulseLoop.Measurement.self, context), before)
    }

    // MARK: - Settings blobs

    func testSettingsBlobsRoundTrip() async throws {
        let source = try TestSupport.makeContext()
        let exportDefaults = makeSuiteDefaults("export")
        var prefs = MetricPrefs.default
        prefs.hiddenMetrics = ["stress", "hrv"]
        prefs.resolution = .coarse
        let blob = try JSONEncoder().encode(prefs)
        exportDefaults.set(blob, forKey: "pulseloop.metricprefs.v1")

        let data = try await DataArchiveService.exportArchive(
            context: source, defaults: exportDefaults, attachmentsDirectory: try makeTempDirectory()
        )

        let importDefaults = makeSuiteDefaults("import")
        // Pre-set a key the archive doesn't carry: import must clear it back to defaults.
        importDefaults.set(Data("{}".utf8), forKey: "pulseloop.calibration.v1")
        try await DataArchiveService.importArchive(
            data, context: try TestSupport.makeContext(), defaults: importDefaults,
            attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )

        XCTAssertEqual(importDefaults.data(forKey: "pulseloop.metricprefs.v1"), blob, "settings blob must restore byte-identical")
        XCTAssertNil(importDefaults.data(forKey: "pulseloop.calibration.v1"), "keys absent from the archive must reset")
    }

    // MARK: - Attachments

    func testAttachmentsRoundTrip() async throws {
        let sourceDir = try makeTempDirectory()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        try bytes.write(to: sourceDir.appendingPathComponent("photo-a.jpg"))

        let data = try await DataArchiveService.exportArchive(
            context: try TestSupport.makeContext(), defaults: makeSuiteDefaults("attach"), attachmentsDirectory: sourceDir
        )

        let targetDir = try makeTempDirectory()
        // A stale file from the pre-import dataset must not survive the restore.
        try Data([0x00]).write(to: targetDir.appendingPathComponent("stale.jpg"))
        try await DataArchiveService.importArchive(
            data, context: try TestSupport.makeContext(), defaults: makeSuiteDefaults("attach2"),
            attachmentsDirectory: targetDir, refreshStores: false
        )

        XCTAssertEqual(try Data(contentsOf: targetDir.appendingPathComponent("photo-a.jpg")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("stale.jpg").path))
    }
}
