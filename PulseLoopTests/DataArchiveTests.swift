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
        // Inserted explicitly rather than relying on the seed's readiness backfill, which only
        // scores days that happen to have a full enough night.
        context.insert(ReadinessDaily(
            date: Date(timeIntervalSince1970: 1_750_000_000),
            score: 78,
            band: .ready,
            availablePoints: 85,
            contributorsJSON: #"[{"kindRaw":"hrv","earned":22.5,"maxPoints":30,"value":44,"baseline":50,"deviation":-12,"detail":"HRV 12% below your baseline"}]"#
        ))
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
        check(ReadinessDaily.self)
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

    /// Format version 2 added `readinessDailies`. Archives exported before it have no such key, and
    /// `PulseArchive` decodes via the synthesized decoder — which has no notion of property
    /// defaults — so the field must stay Optional or every older backup becomes unimportable.
    /// This test builds a genuine v1 file by stripping the key from a real export.
    func testV1ArchiveWithoutReadinessStillImports() async throws {
        let source = try TestSupport.makeContext()
        SeedData.seedDemo(source)
        TestSupport.insertMeasurement(kind: .heartRate, value: 71, timestamp: Date(), into: source)
        let measurementCount = count(PulseLoop.Measurement.self, source)
        XCTAssertGreaterThan(measurementCount, 0)

        let data = try await DataArchiveService.exportArchive(context: source)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "export should be a JSON object"
        )
        XCTAssertNotNil(json["readinessDailies"], "a v2 export must write the key")
        json.removeValue(forKey: "readinessDailies")
        json["formatVersion"] = 1
        let v1Data = try JSONSerialization.data(withJSONObject: json)

        let destination = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(v1Data, context: destination, refreshStores: false)

        XCTAssertEqual(count(PulseLoop.Measurement.self, destination), measurementCount,
                       "a v1 archive must restore everything it does contain")
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
