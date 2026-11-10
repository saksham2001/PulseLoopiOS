import XCTest
import SwiftData
@testable import PulseLoop

/// Deleting an intraday activity bucket (issue #70): the day is restated without the live ratchet,
/// the bucket stays deleted across re-syncs, and the ring's live counter is corrected by the deficit.
/// Plus the Activity screen's per-day totals (issues #76 / #101).
@MainActor
final class ActivityBucketDeletionTests: XCTestCase {
    private let calendar = Calendar.current

    private func at(_ day: Date, hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func buckets(_ context: ModelContext) throws -> [ActivityBucketSample] {
        try context.fetch(FetchDescriptor<ActivityBucketSample>())
    }

    func testDeletingAPastBucketRestatesTheDayAndSurvivesResync() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let day = TestSupport.day(-2)
        subscriber.persist(.activityBucket(timestamp: at(day, hour: 9), steps: 1_000, distanceMeters: 700))
        subscriber.persist(.activityBucket(timestamp: at(day, hour: 13), steps: 6_000, distanceMeters: 4_200))
        subscriber.persist(.activityBucket(timestamp: at(day, hour: 17), steps: 2_000, distanceMeters: 1_400))
        subscriber.flush()
        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 9_000)

        let records = ActivityBucketDeletion.records(on: day, context: context)
        XCTAssertEqual(records.map(\.steps), [2_000, 6_000, 1_000], "newest first")
        let car = records[1]
        let preview = ActivityBucketDeletion.stepsAfterDeleting(car, context: context)
        XCTAssertEqual(preview.before, 9_000)
        XCTAssertEqual(preview.after, 3_000)

        XCTAssertTrue(ActivityBucketDeletion.delete(startEpoch: car.startEpoch, context: context))
        let row = try XCTUnwrap(MetricsRepository.activity(on: day, context: context))
        XCTAssertEqual(row.steps, 3_000)
        XCTAssertEqual(row.distanceMeters, 2_100, accuracy: 0.001)
        XCTAssertEqual(row.deletedSteps, 6_000)

        // The next sync replays the day.
        subscriber.persist(.activityBucket(timestamp: at(day, hour: 9), steps: 1_000, distanceMeters: 700))
        subscriber.persist(.activityBucket(timestamp: at(day, hour: 13), steps: 6_000, distanceMeters: 4_200))
        subscriber.persist(.activityBucket(timestamp: at(day, hour: 17), steps: 2_000, distanceMeters: 1_400))
        subscriber.flush()
        XCTAssertEqual(try buckets(context).count, 2, "the deleted bucket must not come back")
        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 3_000)
        XCTAssertFalse(ActivityBucketDeletion.delete(startEpoch: car.startEpoch, context: context), "already gone")
    }

    /// Today is normally ratcheted against the live counter; a deletion must still let the total fall,
    /// and the next live reading is reduced by what was deleted instead of restoring it.
    func testTodayDropsBelowTheRatchetAndLiveUpdatesAreCorrected() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let today = calendar.startOfDay(for: Date())
        let early = today.addingTimeInterval(60)
        subscriber.persist(.activityUpdate(timestamp: early, steps: 5_000, distanceMeters: 3_500, calories: 220))
        subscriber.persist(.activityBucket(timestamp: early, steps: 1_500, distanceMeters: 1_000))
        subscriber.persist(.activityBucket(timestamp: early.addingTimeInterval(900), steps: 3_000, distanceMeters: 2_100))
        subscriber.flush()
        XCTAssertEqual(MetricsRepository.activity(on: today, context: context)?.steps, 5_000, "live counter leads the buckets")

        let epoch = Int(early.addingTimeInterval(900).timeIntervalSince1970)
        XCTAssertTrue(ActivityBucketDeletion.delete(startEpoch: epoch, context: context))
        var row = try XCTUnwrap(MetricsRepository.activity(on: today, context: context))
        XCTAssertEqual(row.steps, 1_500, "restated as the bucket sum, without the ratchet")
        XCTAssertNil(row.deviceReportedCalories, "the ring's calorie figure counted the deleted block")

        // The ring re-sends its cumulative count (still including the deleted 3,000) plus 200 new steps.
        subscriber.persist(.activityUpdate(timestamp: early, steps: 5_200, distanceMeters: 3_600, calories: 230))
        subscriber.flush()
        row = try XCTUnwrap(MetricsRepository.activity(on: today, context: context))
        XCTAssertEqual(row.steps, 2_200)
        XCTAssertEqual(row.distanceMeters, 1_500, accuracy: 0.001)
        XCTAssertNil(row.deviceReportedCalories, "calories stay on the estimate after a deletion")
    }

    func testRatchetIsUnchangedWithoutADeletion() {
        XCTAssertEqual(ActivityBucketDeletion.ratchet(stored: 4_000, ring: 5_000, deleted: 0), 5_000)
        XCTAssertEqual(ActivityBucketDeletion.ratchet(stored: 6_000, ring: 5_000, deleted: 0), 6_000)
        XCTAssertEqual(ActivityBucketDeletion.ratchet(stored: 1_000, ring: 5_000, deleted: 6_000), 1_000)
    }

    func testRWfitHistoryRespectsTheTombstone() throws {
        let context = try TestSupport.makeContext()
        let day = TestSupport.day(-1)
        let ts = at(day, hour: 10)
        context.insert(ActivityBucketSample(timestamp: ts, steps: 800, distanceMeters: 500))
        try context.save()
        XCTAssertTrue(ActivityBucketDeletion.delete(startEpoch: Int(ts.timeIntervalSince1970), context: context))

        let persistence = try RWfitActivityPersistence(context: context)
        XCTAssertTrue(persistence.apply(.activityBucket(timestamp: ts, steps: 800, distanceMeters: 500)))
        try context.save()
        XCTAssertTrue(try buckets(context).isEmpty)
    }

    func testDayTotalsReadTheShownDayOnly() throws {
        let context = try TestSupport.makeContext()
        let today = calendar.startOfDay(for: Date())
        TestSupport.insertActivity(date: today, steps: 8_000, calories: 400, distanceMeters: 5_000, into: context)

        XCTAssertEqual(ActivityDayTotals.load(day: TestSupport.day(-3), context: context), .empty,
                       "a day with nothing stored reads empty, never today's numbers")

        let totals = ActivityDayTotals.load(day: today, context: context)
        let row = try XCTUnwrap(MetricsRepository.activity(on: today, context: context))
        XCTAssertEqual(totals.steps, 8_000)
        XCTAssertEqual(totals.calories,
                       row.effectiveCalories(profile: MetricsProfileValues(profile: ProfileRepository.profile(context: context))),
                       "calories come from the same read path the Today screen uses")
        XCTAssertEqual(totals.calories, 400)
    }

    func testArchiveCarriesTheDeletionDeficit() async throws {
        let source = try TestSupport.makeContext()
        let day = TestSupport.day(-1)
        let ts = at(day, hour: 10)
        ActivityService.applyActivityBucket(date: ts, steps: 800, distanceMeters: 500, context: source)
        ActivityService.applyActivityBucket(date: ts.addingTimeInterval(900), steps: 300, distanceMeters: 200, context: source)
        try source.save()
        ActivityBucketDeletion.delete(startEpoch: Int(ts.timeIntervalSince1970), context: source)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "ActivityBucketDeletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let data = try await DataArchiveService.exportArchive(context: source, defaults: defaults, attachmentsDirectory: dir)
        let target = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(data, context: target, defaults: defaults,
                                                   attachmentsDirectory: dir, refreshStores: false)
        XCTAssertEqual(MetricsRepository.activity(on: day, context: target)?.deletedSteps, 800)
        XCTAssertTrue(MeasurementDeletionService.isActivityBucketDeleted(startEpoch: Int(ts.timeIntervalSince1970), context: target))
    }
}
