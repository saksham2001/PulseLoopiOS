import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class RWfitHistoryPersistenceTests: XCTestCase {
    func testHistoryCommitIsDurableAndIdempotent() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let timestamp = Date().addingTimeInterval(-60)
        let events: [RingDecodedEvent] = [.historyMeasurement(kind: .heartRate, value: 72, timestamp: timestamp)]
        try subscriber.saveRWfitHistory(events)
        try subscriber.saveRWfitHistory(events)
        XCTAssertFalse(context.hasChanges)
        let rows = try context.fetch(FetchDescriptor<PulseLoop.Measurement>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value, 72)
    }

    func testRejectedHistoryPreventsAnyPageImport() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        XCTAssertThrowsError(try subscriber.saveRWfitHistory([
            .historyMeasurement(kind: .heartRate, value: 72, timestamp: Date()),
            .historyMeasurement(kind: .heartRate, value: 0, timestamp: Date())
        ]))
        XCTAssertTrue(try context.fetch(FetchDescriptor<PulseLoop.Measurement>()).isEmpty)
    }

    func testOverlappingRecoveredSleepExtendsSavedSessionWithoutInflation() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let start = Date().addingTimeInterval(-6 * 3600)
        try subscriber.saveRWfitHistory([.sleepTimeline(timestamp: start, stages: Array(repeating: .light, count: 30))])
        let aggregate: [RingDecodedEvent] = [.sleepTimeline(timestamp: start, stages: Array(repeating: .light, count: 60))]
        try subscriber.saveRWfitHistory(aggregate)
        try subscriber.saveRWfitHistory(aggregate)
        let blocks = try context.fetch(FetchDescriptor<SleepStageBlock>())
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 60)
    }

    func testRwfitFreshnessRequiresSuccessfulOutcome() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.deviceIdentified(deviceType: .rwfit, wearableModelID: nil,
                                             advertisedName: "SR16", capabilities: []))
        subscriber.persist(.deviceStateChanged(state: .connected, address: nil))
        subscriber.persist(.syncProgress(stage: "done"))
        subscriber.persist(.rwfitSyncOutcome(.failed(reason: "Timeout")))
        subscriber.persist(.rwfitSyncOutcome(.partial(records: 1, reason: "Interrupted")))
        subscriber.persist(.rwfitSyncOutcome(.cancelled))
        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertNil(device.lastSyncAt)
        XCTAssertNil(device.lastFullSyncAt)
        subscriber.persist(.rwfitSyncOutcome(.success(records: 0)))
        XCTAssertNotNil(device.lastSyncAt)
        XCTAssertEqual(device.lastSyncAt, device.lastFullSyncAt)
    }

    func testActivityFailureRollsBackEveryBucketAndRetryImportsOnce() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-24 * 3600)
        let events: [RingDecodedEvent] = [
            .activityBucket(timestamp: start, steps: 1000, distanceMeters: 700),
            .activityBucket(timestamp: start.addingTimeInterval(1800), steps: 2000, distanceMeters: 1400)
        ]
        enum StorageFailure: Error { case unavailable }
        XCTAssertThrowsError(try subscriber.saveRWfitHistory(events, commit: { throw StorageFailure.unavailable }))
        XCTAssertTrue(try context.fetch(FetchDescriptor<ActivityBucketSample>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ActivityDaily>()).isEmpty,
                      "An intermediate bucket helper must not commit before the transaction's final save")
        try subscriber.saveRWfitHistory(events)
        try subscriber.saveRWfitHistory(events)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ActivityBucketSample>()).count, 2)
        let days = try context.fetch(FetchDescriptor<ActivityDaily>())
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.steps, 3000)
    }

    func testActivityBucketsPreserveTodaysLargerCumulativeReading() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let now = Date()
        try subscriber.saveRWfitHistory([
            .activityUpdate(timestamp: now, steps: 8000, distanceMeters: 5600, calories: 300),
            .activityBucket(timestamp: now, steps: 2000, distanceMeters: 1400)
        ])
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<ActivityDaily>()).first)
        XCTAssertEqual(row.steps, 8000)
        XCTAssertEqual(row.distanceMeters, 5600)
        XCTAssertEqual(row.calories, 300)
    }

    func testSleepJournalSurvivesReloadAndDeduplicatesRetriesPerDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        RWfitHistoryPersistence.journalDirectoryOverride = directory
        defer {
            RWfitHistoryPersistence.journalDirectoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let device = UUID().uuidString
        let other = UUID().uuidString
        let pageID = UUID()
        let first: [UInt8] = [3, 4, 5, 11, 12, 13, 14, 2, 0, 0]
        let second: [UInt8] = [3, 4, 5, 21, 22, 23, 24, 3, 0, 0]
        try RWfitHistoryPersistence.stageSleepPage(first, deviceID: device, pageID: pageID)
        try RWfitHistoryPersistence.stageSleepPage(first, deviceID: device, pageID: pageID)
        try RWfitHistoryPersistence.stageSleepPage(first, deviceID: device, pageID: UUID())
        try RWfitHistoryPersistence.stageSleepPage(second, deviceID: device, pageID: UUID())
        XCTAssertEqual(try RWfitHistoryPersistence.sleepPayload(deviceID: device), first + second.dropFirst(3))
        XCTAssertEqual(try RWfitHistoryPersistence.sleepPayload(deviceID: other), [])
        try RWfitHistoryPersistence.clearSleepPages(deviceID: device)
        XCTAssertEqual(try RWfitHistoryPersistence.sleepPayload(deviceID: device), [])
    }
}
