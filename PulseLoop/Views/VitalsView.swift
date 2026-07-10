import SwiftUI
import SwiftData
import UIKit

struct VitalsView: View {
    @Binding var path: NavigationPath
    /// Whether the Vitals tab is the one on screen. The `.page` TabView keeps adjacent tabs alive, so
    /// we gate expensive rebuilds on visibility — an off-screen Vitals must not rebuild on every sync.
    let isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.zoomNamespace) private var zoomNS
    @Query private var profiles: [UserProfile]
    @State private var measuring: MeasurementSheet.Kind?
    @State private var dataChange = PulseDataChange.shared
    /// Owns the prepared vitals state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: VitalsStore?
    // Card reorder ("edit mode"): long-press a card to enter, drag to reorder, Done to exit. The Done
    // bar itself is rendered by `MainTabView`, which is why edit state lives in a shared session.
    @State private var reorder = CardReorderSession.shared
    @State private var dragging: MetricKey?
    @State private var prefs = MetricPrefsStore.shared
    /// The order being dragged — see the matching note in `TodayView`. Persisted on drop and on exit.
    @State private var liveKeys: [MetricKey] = []
    /// Whether the user actually moved a card; an unsaved order means "use the screen default".
    @State private var orderDirty = false

    /// Canonical Vitals card order (used until the user reorders). Card id = `MetricKey`.
    private static let defaultOrder: [MetricKey] = [
        .heartRate, .spo2, .bloodPressureSystolic, .hrv, .stress, .fatigue, .bloodSugar, .temperature
    ]

    private var profile: UserProfile? { profiles.first }
    private var editing: Bool { reorder.editingScope == .vitals }

    var body: some View {
        guard let activeStore = store else {
            return AnyView(PulseColors.background.ignoresSafeArea().task { ensureStore() })
        }

        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                measureRow(activeStore)
                grid(activeStore)
            }
            .padding(.horizontal, 16)
            // Extra clearance while editing so the last card stays draggable above the Done bar.
            .padding(.bottom, editing ? PulseLayout.scrollBottomInsetEditing : PulseLayout.scrollBottomInset)
        }
        // Tap-outside-to-exit: a catcher layered above the opaque background colour — `.background`
        // stacks back-to-front, so adding it after `PulseColors.background` would bury it.
        .background {
            if editing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { exitEdit() }
                    .accessibilityHidden(true)
            }
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .pulseScrollEdges()
        // A sync can rebuild the store mid-edit — fold the new card set into the on-screen order, and
        // never while a drag is in flight.
        .onChange(of: activeStore.revision) { _, _ in
            guard editing, dragging == nil else { return }
            liveKeys = CardOrder.reconcile(current: liveKeys, target: orderedKeys(activeStore))
        }
        .onChange(of: reorder.editingScope) { old, new in
            guard old == .vitals, new != .vitals else { return }
            dragging = nil
            persistOrder()
        }
        .task { ensureStore(); if isActive { store?.updateProfile(profile) } }
        .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
        .onChange(of: isActive) { _, active in if active { store?.updateProfile(profile) } }
        .onChange(of: profile?.updatedAt) { _, _ in store?.updateProfile(profile) }
        .sheet(item: Binding(get: { measuring.map(VitalsMeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
            MeasurementSheet(kind: item.kind)
        })
    }

    // MARK: - Measure row

    @ViewBuilder
    private func measureRow(_ store: VitalsStore) -> some View {
        // On-demand spot measurements are capability-gated. A combined "Measure now" button (BP + SpO₂
        // + stress) needs a new BLE command and is deferred; for now we surface the supported spot
        // readings the ring can do today.
        // TODO(combined-measure): replace these with a single "Measure now" pill once the combined
        // measurement command lands.
        let caps = store.capabilities
        if caps.contains(.manualHeartRate) || caps.contains(.manualSpo2) || caps.contains(.manualHrv) {
            HStack(spacing: 8) {
                if caps.contains(.manualHeartRate) {
                    QuickActionButton(label: "Measure HR", accent: true) { measuring = .hr }
                }
                if caps.contains(.manualSpo2) {
                    QuickActionButton(label: "Measure SpO₂") { measuring = .spo2 }
                }
                if caps.contains(.manualHrv) {
                    QuickActionButton(label: "Measure HRV") { measuring = .hrv }
                }
            }
        }
    }

    // MARK: - Grid

    /// Single full-width column, rendered in the user's saved order. Long-press any card → reorder.
    @ViewBuilder
    private func grid(_ store: VitalsStore) -> some View {
        let physiology = UserPhysiologyProfile(profile)
        // While editing the column follows the in-flight drag order; otherwise the saved one.
        let keys = editing ? liveKeys : orderedKeys(store)

        VStack(spacing: 14) {
            ReorderableForEach(items: keys, isEditing: editing, revision: store.revision, dragging: $dragging,
                               move: { from, to in move(from, to) },
                               commit: { persistOrder() },
                               hide: { key in hide(key, store) },
                               displayName: { $0.reorderDisplayName },
                               symbolName: { $0.reorderSymbolName },
                               content: { key in
                cardFor(key, store, physiology)
                    // simultaneousGesture so the long-press fires even though each card is a Button.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45).onEnded { _ in enterEdit(store) }
                    )
            })

            // Restore tray: only while editing, and only if something is hidden.
            if editing {
                HiddenMetricsTray(
                    hidden: hiddenKeys(store),
                    restore: { restore($0, store) },
                    displayName: { $0.reorderDisplayName },
                    symbolName: { $0.reorderSymbolName }
                )
            }
        }
    }

    /// Metrics hidden in the Vitals scope, so the tray stays in lockstep with Settings visibility.
    /// Device-unsupported metrics stay out of the tray — restoring one could never produce a card.
    private func hiddenKeys(_ store: VitalsStore) -> [MetricKey] {
        Self.defaultOrder.filter {
            $0.isSupported(by: store.capabilities) && prefs.isHidden($0, scope: .vitals)
        }
    }

    /// Hide and restore change which keys belong on screen, so they capture the drag order and then
    /// re-derive it — reusing `resolvedOrder`, which knows where a restored card should land.
    private func hide(_ key: MetricKey, _ store: VitalsStore) {
        ReorderHaptics.selection.selectionChanged()
        persistOrder()
        prefs.setHidden(key, true, scope: .vitals)
        liveKeys = orderedKeys(store)
    }

    private func restore(_ key: MetricKey, _ store: VitalsStore) {
        persistOrder()
        prefs.setHidden(key, false, scope: .vitals)
        liveKeys = orderedKeys(store)
    }

    /// The one place the drag order reaches `UserDefaults`: on drop, on exit, and around a hide.
    private func persistOrder() {
        guard orderDirty, !liveKeys.isEmpty else { return }
        prefs.setOrder(liveKeys.map(\.rawValue), for: .vitals)
        orderDirty = false
    }

    /// Visible Vitals cards in the saved order (falling back to `defaultOrder`).
    private func orderedKeys(_ store: VitalsStore) -> [MetricKey] {
        // Capability from the store's snapshot, hidden read live from `prefs` — see the matching note
        // in `TodayView.orderedKeys` for why `store.visibleMetrics` can't be the gate here.
        let visible = Self.defaultOrder.filter {
            $0.isSupported(by: store.capabilities) && !prefs.isHidden($0, scope: .vitals)
        }
        let raws = prefs.resolvedOrder(
            visible: Set(visible.map(\.rawValue)),
            defaultOrder: Self.defaultOrder.map(\.rawValue),
            scope: .vitals
        )
        return raws.compactMap { MetricKey(rawValue: $0) }
    }

    @ViewBuilder
    private func cardFor(_ key: MetricKey, _ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        switch key {
        case .heartRate: chartCard(store, .heartRate, physiology)
        case .spo2: chartCard(store, .spo2, physiology, showPoints: true)
        case .bloodPressureSystolic: bpCard(store, physiology)
        case .hrv: chartCard(store, .hrv, physiology)
        case .stress:
            if let m = card(store, .stress) { VitalGaugeCard(model: m) { open(.stress) } }
        case .fatigue:
            if let m = card(store, .fatigue) { VitalGaugeCard(model: m) { open(.fatigue) } }
        case .bloodSugar:
            if let g = card(store, .glucose) { VitalGlucoseCard(model: g) { open(.glucose) } }
        case .temperature: chartCard(store, .temperature, physiology)
        default: EmptyView()
        }
    }

    /// Fires on every cell a dragged card crosses — view state only, no persistence.
    private func move(_ from: Int, _ to: Int) {
        liveKeys = CardOrder.moving(liveKeys, from: from, to: to)
        orderDirty = true
    }

    private func enterEdit(_ store: VitalsStore) {
        guard !editing else { return }
        liveKeys = orderedKeys(store)   // seed before flipping, or the first frame renders an empty column
        orderDirty = false
        ReorderHaptics.selection.prepare()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { reorder.begin(.vitals) }
        // Drag is invisible to VoiceOver — tell VO users how to reorder without it.
        AccessibilityNotification.Announcement(
            "Editing layout. Double-tap and hold to drag, or use actions to move cards."
        ).post()
    }

    /// Ends edit mode. The order is persisted (and `dragging` cleared) by the `editingScope` observer,
    /// which also covers the Done bar and tab switches.
    private func exitEdit() {
        guard editing else { return }
        withAnimation(.easeInOut(duration: 0.2)) { reorder.end() }
    }

    // MARK: - Card builders

    /// The card model, with no visibility gate of its own: `orderedKeys` already decides which cards
    /// the grid renders, and re-checking the store's cached `visibleMetrics` here would drop a card
    /// that was just restored from the Hidden tray, leaving an empty cell behind its remove badge.
    private func card(_ store: VitalsStore, _ metric: MetricKind) -> VitalCardViewModel? {
        store.cards[metric]
    }

    @ViewBuilder
    private func chartCard(_ store: VitalsStore, _ metric: MetricKind,
                           _ physiology: UserPhysiologyProfile, showPoints: Bool = false) -> some View {
        if let model = card(store, metric) {
            let baseline = metric == .hrv ? store.hrvBaseline : nil
            VitalChartCard(model: model, profile: physiology, baseline: baseline, showPoints: showPoints) { open(metric) }
                .pulseZoomSource(AppRoute.metricDetail(metric), in: zoomNS)
        }
    }

    @ViewBuilder
    private func bpCard(_ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        if let model = card(store, .bloodPressure) {
            VitalBloodPressureCard(
                model: model,
                systolic: store.systolicSamples.last?.value,
                diastolic: store.diastolicSamples.last?.value,
                systolicZones: VitalsThresholdEngine.zones(for: .bloodPressure, profile: physiology),
                diastolicZones: VitalsThresholdEngine.diastolicReferenceZones(),
                onTap: { open(.bloodPressure) }
            )
            .pulseZoomSource(AppRoute.metricDetail(.bloodPressure), in: zoomNS)
        }
    }

    private func open(_ metric: MetricKind) {
        path.append(AppRoute.metricDetail(metric))
    }

    // MARK: - Store lifecycle

    private func ensureStore() {
        if store == nil { store = VitalsStore(modelContext: modelContext, profile: profile) }
    }
}

private struct VitalsMeasuringItem: Identifiable {
    let kind: MeasurementSheet.Kind
    var id: Int { kind == .hr ? 0 : 1 }
}
