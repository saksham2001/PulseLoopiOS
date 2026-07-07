import SwiftUI
import SwiftData

struct VitalsView: View {
    @Binding var path: NavigationPath
    /// Whether the Vitals tab is the one on screen. The `.page` TabView keeps adjacent tabs alive, so
    /// we gate expensive rebuilds on visibility — an off-screen Vitals must not rebuild on every sync.
    let isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @State private var measuring: MeasurementSheet.Kind?
    @State private var dataChange = PulseDataChange.shared
    /// Owns the prepared vitals state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: VitalsStore?

    private var profile: UserProfile? { profiles.first }

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
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
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
        if caps.contains(.manualHeartRate) || caps.contains(.manualSpo2) {
            HStack(spacing: 8) {
                if caps.contains(.manualHeartRate) {
                    QuickActionButton(label: "Measure HR", accent: true) { measuring = .hr }
                }
                if caps.contains(.manualSpo2) {
                    QuickActionButton(label: "Measure SpO₂") { measuring = .spo2 }
                }
            }
        }
    }

    // MARK: - Grid

    /// Single full-width column. Each card uses the full app width so values and charts stay legible.
    @ViewBuilder
    private func grid(_ store: VitalsStore) -> some View {
        let physiology = UserPhysiologyProfile(profile)

        VStack(spacing: 14) {
            chartCard(store, .heartRate, physiology)
            chartCard(store, .spo2, physiology, showPoints: true)
            bpCard(store, physiology)
            chartCard(store, .hrv, physiology)

            if let stress = card(store, .stress) {
                VitalGaugeCard(model: stress) { open(.stress) }
            }
            if let fatigue = card(store, .fatigue) {
                VitalGaugeCard(model: fatigue) { open(.fatigue) }
            }
            if let glucose = card(store, .glucose) {
                VitalGlucoseCard(model: glucose) { open(.glucose) }
            }
            // Skin temperature (Colmi).
            if store.visibleMetrics.contains(.temperature) {
                chartCard(store, .temperature, physiology)
            }
        }
    }

    // MARK: - Card builders

    private func card(_ store: VitalsStore, _ metric: MetricKind) -> VitalCardViewModel? {
        guard store.visibleMetrics.contains(metric.metricKey) else { return nil }
        return store.cards[metric]
    }

    @ViewBuilder
    private func chartCard(_ store: VitalsStore, _ metric: MetricKind,
                           _ physiology: UserPhysiologyProfile, showPoints: Bool = false) -> some View {
        if let model = card(store, metric) {
            let baseline = metric == .hrv ? BaselineStats.compute(store.hrvSamples) : nil
            VitalChartCard(model: model, profile: physiology, baseline: baseline, showPoints: showPoints) { open(metric) }
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
