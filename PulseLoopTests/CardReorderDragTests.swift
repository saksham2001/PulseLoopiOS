import XCTest
import SwiftData
@testable import PulseLoop

/// Coverage for the drag machinery behind card reorder: the pure list operations a hover and a
/// mid-edit sync perform, and the store `revision` that lets `ReorderCell` cache a card's rendered
/// body across reorders. Between them these are what keep a drag off the persistence path.
@MainActor
final class CardReorderDragTests: XCTestCase {

    private let keys: [MetricKey] = [.steps, .sleep, .heartRate, .spo2, .hrv]

    // MARK: - CardOrder.moving

    /// `to` indexes the array *before* the removal — that's what the drop delegate hands us.
    func testMovingForwardLandsAtTargetIndex() {
        XCTAssertEqual(CardOrder.moving([0, 1, 2, 3], from: 0, to: 2), [1, 2, 0, 3])
    }

    func testMovingBackwardLandsAtTargetIndex() {
        XCTAssertEqual(CardOrder.moving([0, 1, 2, 3], from: 3, to: 1), [0, 3, 1, 2])
    }

    func testMovingToEitherEnd() {
        XCTAssertEqual(CardOrder.moving(keys, from: 0, to: 4), [.sleep, .heartRate, .spo2, .hrv, .steps])
        XCTAssertEqual(CardOrder.moving(keys, from: 4, to: 0), [.hrv, .steps, .sleep, .heartRate, .spo2])
    }

    func testMovingIsIdentityWhenSourceEqualsDestination() {
        XCTAssertEqual(CardOrder.moving(keys, from: 2, to: 2), keys)
    }

    /// The delegate derives indices from a snapshot, so an out-of-range index must not trap.
    func testMovingIgnoresOutOfRangeSource() {
        XCTAssertEqual(CardOrder.moving(keys, from: 9, to: 0), keys)
    }

    func testMovingClampsOutOfRangeDestination() {
        XCTAssertEqual(CardOrder.moving([0, 1, 2], from: 0, to: 99), [1, 2, 0])
        XCTAssertEqual(CardOrder.moving([0, 1, 2], from: 2, to: -5), [2, 0, 1])
    }

    // MARK: - CardOrder.reconcile

    /// A sync landing mid-edit must not undo the reorder the user can see on screen.
    func testReconcilePreservesTheUsersOrder() {
        let current: [MetricKey] = [.hrv, .steps, .heartRate]
        let target: [MetricKey] = [.steps, .heartRate, .hrv]
        XCTAssertEqual(CardOrder.reconcile(current: current, target: target), current)
    }

    func testReconcileDropsKeysThatVanished() {
        let current: [MetricKey] = [.hrv, .steps, .heartRate]
        let target: [MetricKey] = [.steps, .heartRate]
        XCTAssertEqual(CardOrder.reconcile(current: current, target: target), [.steps, .heartRate])
    }

    /// A newly-supported metric slots in where the freshly-derived order puts it, not at the end.
    func testReconcileInsertsNewKeyAtItsTargetIndex() {
        let current: [MetricKey] = [.steps, .heartRate]
        let target: [MetricKey] = [.steps, .spo2, .heartRate]
        XCTAssertEqual(CardOrder.reconcile(current: current, target: target), [.steps, .spo2, .heartRate])
    }

    func testReconcileWithEmptyCurrentYieldsTarget() {
        XCTAssertEqual(CardOrder.reconcile(current: [], target: keys), keys)
    }

    func testReconcileWithEmptyTargetYieldsEmpty() {
        XCTAssertEqual(CardOrder.reconcile(current: keys, target: []), [])
    }

    /// Reconcile must be a fixed point once the two agree, or a sync storm would shuffle cards.
    func testReconcileIsIdempotent() {
        let current: [MetricKey] = [.hrv, .steps]
        let target: [MetricKey] = [.steps, .hrv, .spo2]
        let once = CardOrder.reconcile(current: current, target: target)
        XCTAssertEqual(CardOrder.reconcile(current: once, target: once), once)
    }

    // MARK: - Store revision

    /// `ReorderCell` skips a card's `body` while `revision` holds. If a rebuild ever failed to bump it,
    /// the grid would render stale charts — so this is the invariant the whole perf fix rests on.
    func testTodayStoreRevisionBumpsOnlyWhenCardsRebuild() throws {
        let context = try TestSupport.makeContext()
        let store = TodayStore(modelContext: context)
        let initial = store.revision

        // No data changed → the signature holds → no rebuild → no bump.
        store.refreshIfNeeded()
        XCTAssertEqual(store.revision, initial, "an unchanged signature must not invalidate cached cards")

        // A forced rebuild does bump, so a real data change re-renders the charts.
        store.invalidate()
        XCTAssertEqual(store.revision, initial + 1)
        store.invalidate()
        XCTAssertEqual(store.revision, initial + 2)
    }

    func testVitalsStoreRevisionBumpsOnlyWhenCardsRebuild() throws {
        let context = try TestSupport.makeContext()
        let store = VitalsStore(modelContext: context)
        let initial = store.revision

        store.refreshIfNeeded()
        XCTAssertEqual(store.revision, initial)

        store.invalidate()
        XCTAssertEqual(store.revision, initial + 1)
    }

    // MARK: - Cached HRV baseline

    /// The chart tiles used to recompute this in `body`. Cache it, but keep it equal to what they'd
    /// have computed.
    func testTodayStoreCachesTheHRVBaseline() throws {
        let context = try TestSupport.makeContext()
        let store = TodayStore(modelContext: context)
        XCTAssertEqual(store.hrvBaseline, BaselineStats.compute(store.hrvSamples))
    }

    func testVitalsStoreCachesTheHRVBaseline() throws {
        let context = try TestSupport.makeContext()
        let store = VitalsStore(modelContext: context)
        XCTAssertEqual(store.hrvBaseline, BaselineStats.compute(store.hrvSamples))
    }

    // MARK: - Hide / restore mid-edit

    /// The sequence `hide` and `restore` run: capture the drag order, toggle hidden, re-derive. A card
    /// dragged to the front and then hidden must come back to the front, not to its default slot.
    func testHiddenCardRestoresToItsDraggedPositionNotItsDefault() {
        let prefs = MetricPrefsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let defaultOrder = keys.map(\.rawValue)
        func resolve(_ visible: [MetricKey]) -> [MetricKey] {
            prefs.resolvedOrder(visible: Set(visible.map(\.rawValue)),
                                defaultOrder: defaultOrder, scope: .today)
                .compactMap { MetricKey(rawValue: $0) }
        }

        // User drags HRV to the front, so the live order is persisted on drop.
        let dragged: [MetricKey] = [.hrv, .steps, .sleep, .heartRate, .spo2]
        prefs.setOrder(dragged.map(\.rawValue), for: .today)

        // Then hides HRV. It leaves the grid...
        prefs.setHidden(.hrv, true, scope: .today)
        let visibleAfterHide = keys.filter { !prefs.isHidden($0, scope: .today) }
        XCTAssertEqual(resolve(visibleAfterHide), [.steps, .sleep, .heartRate, .spo2])

        // ...and the tray's "+" brings it back to where they dragged it, because it is still in the
        // saved order — `resolvedOrder` only filters that order by visibility.
        prefs.setHidden(.hrv, false, scope: .today)
        XCTAssertEqual(resolve(keys), dragged)
    }
}
