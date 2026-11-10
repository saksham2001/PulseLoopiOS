import XCTest
import SwiftData
@testable import PulseLoop

/// Days a LuckRing inflated by storing its running-total sport records as activity buckets.
@MainActor
final class LuckRingActivityRepairTests: XCTestCase {
    private let key = "luckRingActivityRepair.v1"
    /// Two days back at midnight, so the bucket path's today-only max guard doesn't apply.
    private let day = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    private func snapshot(_ offset: TimeInterval, _ steps: Int, _ distance: Double) -> (timestamp: Date, steps: Int, distanceMeters: Double) {
        (day.addingTimeInterval(offset), steps, distance)
    }

    /// The reporter's afternoon: 537 → 668 steps across the pushes, summed to thousands.
    private var afternoon: [(timestamp: Date, steps: Int, distanceMeters: Double)] {
        [snapshot(60_609, 537, 380), snapshot(63_473, 549, 389), snapshot(66_668, 584, 414),
         snapshot(66_780, 594, 421), snapshot(66_809, 640, 453), snapshot(67_619, 668, 473)]
    }

    private func storeAsBuckets(_ snapshots: [(timestamp: Date, steps: Int, distanceMeters: Double)], context: ModelContext) {
        for s in snapshots {
            ActivityService.applyActivityBucket(date: s.timestamp, steps: s.steps, distanceMeters: s.distanceMeters, context: context)
        }
    }

    private func pairRing(_ type: RingDeviceType, context: ModelContext) {
        context.insert(Device(deviceType: type, capabilities: [.steps, .heartRate]))
        try? context.save()
    }

    // MARK: Plan

    func testRunningTotalSnapshotsCollapseToTheLastOne() {
        let total = ActivityService.luckRingRunningTotal(afternoon.shuffled())
        XCTAssertEqual(total?.steps, 668)
        XCTAssertEqual(total?.distanceMeters, 473)
    }

    func testIntervalBucketsThatRiseAndFallAreLeftAlone() {
        XCTAssertNil(ActivityService.luckRingRunningTotal([snapshot(0, 300, 200), snapshot(900, 120, 80), snapshot(1800, 450, 310)]))
    }

    func testASingleBucketIsLeftAlone() {
        XCTAssertNil(ActivityService.luckRingRunningTotal([snapshot(0, 300, 200)]))
    }

    // MARK: Repair

    func testLuckRingDayIsRestoredAndItsSnapshotsRemoved() throws {
        let context = try TestSupport.makeContext()
        pairRing(.luckRing, context: context)
        storeAsBuckets(afternoon, context: context)
        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 3572, "precondition: summed")

        ActivityService.repairLuckRingActivityIfNeeded(context: context)

        let row = try XCTUnwrap(MetricsRepository.activity(on: day, context: context))
        XCTAssertEqual(row.steps, 668)
        XCTAssertEqual(row.distanceMeters, 473)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivityBucketSample>()), 0)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func testOtherRingFamiliesAreNotTouchedButTheRepairIsDone() throws {
        let context = try TestSupport.makeContext()
        pairRing(.colmiR02, context: context)
        storeAsBuckets(afternoon, context: context)

        ActivityService.repairLuckRingActivityIfNeeded(context: context)

        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 3572)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivityBucketSample>()), afternoon.count)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func testWaitsWithoutMarkingDoneWhileNoRingIsPaired() throws {
        let context = try TestSupport.makeContext()
        storeAsBuckets(afternoon, context: context)

        ActivityService.repairLuckRingActivityIfNeeded(context: context)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key), "no ring yet: retry on a later launch")
        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 3572)

        pairRing(.luckRing, context: context)
        ActivityService.repairLuckRingActivityIfNeeded(context: context)
        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 668)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func testLuckRingIntervalDaysAreLeftAlone() throws {
        let context = try TestSupport.makeContext()
        pairRing(.luckRing, context: context)
        storeAsBuckets([snapshot(0, 300, 200), snapshot(900, 120, 80), snapshot(1800, 450, 310)], context: context)

        ActivityService.repairLuckRingActivityIfNeeded(context: context)

        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 870)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivityBucketSample>()), 3)
    }
}
