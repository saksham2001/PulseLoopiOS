import XCTest
@testable import PulseLoop

/// Pure-logic coverage for the Today/Vitals card reorder + hide preferences: order persistence,
/// how an unordered metric slots into a saved order, tolerant decoding, and the capability gate the
/// grids use in place of the stores' cached `visibleMetrics` snapshot.
@MainActor
final class CardReorderPrefsTests: XCTestCase {

    private func makeStore() -> MetricPrefsStore {
        MetricPrefsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    /// Today's canonical order, mirrored from `TodayView.defaultOrder`.
    private let defaultOrder = [
        MetricKey.steps, .sleep, .heartRate, .spo2, .hrv, .temperature,
        .stress, .fatigue, .bloodSugar, .bloodPressureSystolic
    ].map(\.rawValue)

    private func resolve(_ store: MetricPrefsStore, visible: [String]) -> [String] {
        store.resolvedOrder(visible: Set(visible), defaultOrder: defaultOrder, scope: .today)
    }

    // MARK: - Order resolution

    func testNoSavedOrderFallsBackToDefaultOrder() {
        let store = makeStore()
        XCTAssertEqual(resolve(store, visible: defaultOrder), defaultOrder)
    }

    func testSavedOrderIsHonoredAndScopedIndependently() {
        let store = makeStore()
        let reversed = Array(defaultOrder.reversed())
        store.setOrder(reversed, for: .today)

        XCTAssertEqual(resolve(store, visible: defaultOrder), reversed)
        // The vitals scope is untouched by a today-scope reorder.
        XCTAssertEqual(store.order(for: .vitals), [])
    }

    func testResolvedOrderDropsMetricsThatAreNotVisible() {
        let store = makeStore()
        store.setOrder(defaultOrder, for: .today)
        let visible = defaultOrder.filter { $0 != MetricKey.hrv.rawValue }

        XCTAssertEqual(resolve(store, visible: visible), visible)
        // The saved order itself is untouched — hiding is not a reorder.
        XCTAssertEqual(store.order(for: .today), defaultOrder)
    }

    /// A card restored from the Hidden tray (or unlocked by a new ring) is absent from the saved
    /// order. It must land in its default neighbourhood, not be appended to the bottom.
    func testUnorderedMetricSlotsIntoItsDefaultPositionNotTheEnd() {
        let store = makeStore()
        // The user reordered while `.hrv` was hidden, so it never made it into the saved order.
        let saved = defaultOrder.filter { $0 != MetricKey.hrv.rawValue }
        store.setOrder(saved, for: .today)

        let resolved = resolve(store, visible: defaultOrder)
        // `.hrv` follows `.spo2` by default, so it lands directly after it — not last.
        let spo2 = resolved.firstIndex(of: MetricKey.spo2.rawValue)
        let hrv = resolved.firstIndex(of: MetricKey.hrv.rawValue)
        XCTAssertEqual(hrv, spo2.map { $0 + 1 })
        XCTAssertNotEqual(hrv, resolved.count - 1)
        XCTAssertEqual(Set(resolved), Set(defaultOrder))
        XCTAssertEqual(resolved.count, defaultOrder.count)
    }

    /// The first default metric has no preceding anchor — it must go to the front, not the back.
    func testUnorderedFirstMetricSlotsToTheFront() {
        let store = makeStore()
        store.setOrder(defaultOrder.filter { $0 != MetricKey.steps.rawValue }, for: .today)

        let resolved = resolve(store, visible: defaultOrder)
        XCTAssertEqual(resolved.first, MetricKey.steps.rawValue)
        XCTAssertEqual(resolved, defaultOrder)
    }

    /// A run of consecutive missing metrics keeps its relative default order.
    func testConsecutiveUnorderedMetricsKeepDefaultRelativeOrder() {
        let store = makeStore()
        let missing = [MetricKey.hrv.rawValue, MetricKey.temperature.rawValue]
        store.setOrder(defaultOrder.filter { !missing.contains($0) }, for: .today)

        XCTAssertEqual(resolve(store, visible: defaultOrder), defaultOrder)
    }

    func testResolvedOrderIgnoresSavedIdsThatAreNoLongerVisible() {
        let store = makeStore()
        store.setOrder(["not_a_metric"] + defaultOrder, for: .today)
        XCTAssertEqual(resolve(store, visible: defaultOrder), defaultOrder)
    }

    // MARK: - Persistence

    func testOrderPersistsAcrossStoreInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let reversed = Array(defaultOrder.reversed())
        MetricPrefsStore(defaults: defaults).setOrder(reversed, for: .vitals)

        XCTAssertEqual(MetricPrefsStore(defaults: defaults).order(for: .vitals), reversed)
    }

    /// Order is a display preference layered onto an older payload — decoding must tolerate its
    /// absence rather than throwing away the whole prefs blob.
    func testDecodingPrefsWrittenBeforeOrderExistedYieldsEmptyOrder() throws {
        let legacy = Data(#"{"hiddenMetrics":["hrv"],"todayHiddenMetrics":[]}"#.utf8)
        let prefs = try JSONDecoder().decode(MetricPrefs.self, from: legacy)

        XCTAssertEqual(prefs.todayOrder, [])
        XCTAssertEqual(prefs.vitalsOrder, [])
        XCTAssertEqual(prefs.hiddenMetrics, ["hrv"])
    }

    // MARK: - Capability gate

    /// The grids gate on `MetricKey.isSupported(by:)` against the store's cached capability set
    /// rather than the stale `visibleMetrics` snapshot, so hide/restore round-trips.
    func testIsSupportedMatchesCapabilitySet() {
        let colmi: Set<WearableCapability> = [.heartRate, .spo2, .steps, .sleep, .battery, .stress, .hrv, .temperature]

        XCTAssertTrue(MetricKey.hrv.isSupported(by: colmi))
        XCTAssertTrue(MetricKey.steps.isSupported(by: colmi))
        // No BP capability on a Colmi → the card can never render, so it stays out of grid and tray.
        XCTAssertFalse(MetricKey.bloodPressureSystolic.isSupported(by: colmi))
        XCTAssertFalse(MetricKey.bloodSugar.isSupported(by: colmi))
    }

    /// Hiding a metric must never change whether the device supports it — that asymmetry is what
    /// lets the grid recompute visibility live while capability stays pinned to the paired ring.
    func testHidingAMetricDoesNotAffectSupport() {
        let store = makeStore()
        let caps: Set<WearableCapability> = [.heartRate, .spo2, .hrv]

        store.setHidden(.hrv, true, scope: .today)
        XCTAssertTrue(store.isHidden(.hrv, scope: .today))
        XCTAssertTrue(MetricKey.hrv.isSupported(by: caps))

        // …and the grid's composed gate flips back the moment the tray restores it.
        store.setHidden(.hrv, false, scope: .today)
        XCTAssertFalse(store.isHidden(.hrv, scope: .today))
    }

    /// The end-to-end shape of the bug this guards: hide → (store rebuild) → restore must bring the
    /// card back. Composing capability with a live `isHidden` makes the round-trip total.
    func testHideThenRestoreRoundTripsThroughTheGridGate() {
        let store = makeStore()
        let caps: Set<WearableCapability> = [.heartRate, .spo2, .steps, .sleep, .battery, .stress, .hrv, .temperature]
        func gridKeys() -> [MetricKey] {
            [MetricKey.steps, .sleep, .heartRate, .spo2, .hrv, .temperature, .stress, .fatigue]
                .filter { $0.isSupported(by: caps) && !store.isHidden($0, scope: .today) }
        }

        XCTAssertTrue(gridKeys().contains(.hrv))
        store.setHidden(.hrv, true, scope: .today)
        XCTAssertFalse(gridKeys().contains(.hrv))
        store.setHidden(.hrv, false, scope: .today)
        XCTAssertTrue(gridKeys().contains(.hrv), "restoring from the Hidden tray must bring the card back")
    }
}
