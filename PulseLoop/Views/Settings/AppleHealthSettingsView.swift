import SwiftUI
import SwiftData
import UIKit

/// Apple Health detail screen. A master toggle gates writing ring data to Apple Health; enabling it
/// requests HealthKit share authorization (denied → revert + "Open Health" hint) and, on first
/// success, asks whether to backfill all history or only sync new data from now on. Per-type toggles,
/// a workouts-export toggle, a manual "export full history" action, and a destructive "remove my data"
/// action live below, all gated on the master toggle (except removal, which stays available so users
/// can clean up after turning sync off).
struct AppleHealthSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @State private var service = HealthSyncService.shared
    @State private var store = AppleHealthPrefsStore.shared
    /// First-enable backfill choice ("all history" vs "new only" vs cancel).
    @State private var showBackfillDialog = false
    /// Confirmation before deleting PulseLoop's samples out of Apple Health.
    @State private var showRemoveAlert = false
    /// Set when authorization was refused — surfaces the "Open Health" hint row.
    @State private var accessDenied = false

    private var masterOn: Bool { store.prefs.masterEnabled }

    /// What the connected ring can actually produce. Rows for metrics it can't are hidden outright
    /// rather than shown-and-inert: a VO₂max toggle on a jring is a promise the hardware can't keep.
    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCopy(title: status.title, body: status.body)

                masterGroup

                if accessDenied {
                    accessDeniedHint
                }

                dataTypesGroup
                    .disabled(!masterOn)
                    .opacity(masterOn ? 1 : 0.5)

                workoutsGroup
                    .disabled(!masterOn)
                    .opacity(masterOn ? 1 : 0.5)

                actionsGroup
                    .disabled(!masterOn)
                    .opacity(masterOn ? 1 : 0.5)

                dangerGroup
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Apple Health")
        .confirmationDialog("Sync your history?", isPresented: $showBackfillDialog, titleVisibility: .visible) {
            Button("Sync all history") { startFullHistoryBackfill() }
            Button("Only new data from now on") { startNewDataOnly() }
            Button("Cancel", role: .cancel) { store.prefs.masterEnabled = false }
        } message: {
            Text("Choose how much of your ring history to copy into Apple Health.")
        }
        .alert("Remove PulseLoop data from Apple Health?", isPresented: $showRemoveAlert) {
            Button("Remove", role: .destructive) {
                Task { await service.removeAllExportedData(context: modelContext) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only the samples PulseLoop wrote. Data from other apps is untouched.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var masterGroup: some View {
        SettingsGroup(
            footer: "When on, PulseLoop mirrors your ring's data into Apple Health. "
                + "Turning it off stops writing — data already in Health stays."
        ) {
            FormToggleRow(title: "Sync to Apple Health", isOn: Binding(
                get: { store.prefs.masterEnabled },
                set: { setMaster($0) }
            ))
        }
        .disabled(!service.isAvailable)
        .opacity(service.isAvailable ? 1 : 0.5)
    }

    @ViewBuilder private var accessDeniedHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PulseLoop wasn't granted access. Turn it on for PulseLoop in the Health app.")
                .font(.caption)
                .foregroundStyle(PulseColors.danger)
            QuickActionButton(label: "Open Health") { openHealthApp() }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var dataTypesGroup: some View {
        SettingsGroup(
            header: "Data types",
            footer: "Stress and fatigue have no Apple Health equivalent — Health has no type for a device "
                + "wellness score — so they can't be synced. Rows appear only for metrics your ring can produce."
        ) {
            FormToggleRow(title: "Heart rate", isOn: prefBinding(\.syncHeartRate))
            FormToggleRow(title: "Blood oxygen", isOn: prefBinding(\.syncSpO2))
            FormToggleRow(title: "Heart rate variability", isOn: prefBinding(\.syncHRV))
            FormToggleRow(title: "Temperature", isOn: prefBinding(\.syncTemperature))
            if shows(.respiratoryRate) {
                FormToggleRow(title: "Respiratory rate", isOn: prefBinding(\.syncRespiratoryRate))
            }
            if shows(.vo2max) {
                FormToggleRow(title: "Cardio fitness (VO₂max)", isOn: prefBinding(\.syncVO2Max))
            }
            if shows(.bloodSugar, capability: .bloodSugar) {
                FormToggleRow(title: "Blood glucose", isOn: prefBinding(\.syncBloodSugar))
            }
            if shows(.bloodPressureSystolic, capability: .bloodPressure) {
                FormToggleRow(title: "Blood pressure", isOn: prefBinding(\.syncBloodPressure))
            }
            FormToggleRow(title: "Sleep", isOn: prefBinding(\.syncSleep))
            FormToggleRow(title: "Steps & activity", isOn: prefBinding(\.syncActivity))
        }
    }

    /// Whether to offer a toggle for a ring-dependent metric.
    ///
    /// Shown when the connected ring declares the capability **or** the store already holds a reading
    /// of that kind. The second arm matters for two cases the capability alone misses: respiratory
    /// rate and VO₂max have no `WearableCapability` of their own (they ride the YCBT history records),
    /// and history from a previously-paired ring should stay exportable after switching hardware.
    private func shows(_ kind: MeasurementKind, capability: WearableCapability? = nil) -> Bool {
        if let capability, capabilities.contains(capability) { return true }
        return MetricsRepository.hasAnyMeasurement(kind: kind, context: modelContext)
    }

    @ViewBuilder private var workoutsGroup: some View {
        SettingsGroup(
            header: "Workouts",
            footer: "Export finished workouts with calories, distance, heart-rate stats, and GPS route."
        ) {
            FormToggleRow(title: "Export workouts", isOn: prefBinding(\.exportWorkouts))
        }
    }

    @ViewBuilder private var actionsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuickActionButton(label: service.isSyncing ? "Exporting…" : "Export full history now") {
                Task { await service.exportHistory(context: modelContext) }
            }
            .disabled(service.isSyncing)
            if let result = service.lastResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder private var dangerGroup: some View {
        SettingsGroup(footer: "Deletes only the samples PulseLoop wrote to Apple Health.") {
            Button {
                showRemoveAlert = true
            } label: {
                HStack {
                    Text("Remove PulseLoop data from Apple Health")
                        .font(PulseFont.body)
                        .foregroundStyle(PulseColors.danger)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .disabled(!service.isAvailable || service.isSyncing)
        .opacity(service.isAvailable ? 1 : 0.5)
    }

    // MARK: - Status copy

    private var status: (title: String, body: String) {
        guard service.isAvailable else {
            return ("Apple Health unavailable", "Apple Health isn't available on this device.")
        }
        switch service.authState {
        case .authorized where masterOn:
            if let last = store.syncState.lastSyncAt {
                return ("Connected", "Last synced \(Self.relative(last)).")
            }
            return ("Connected", "PulseLoop is mirroring your ring data to Apple Health.")
        case .denied:
            return ("Access is off", "PulseLoop's access to Apple Health is turned off. Turn it back on in the Health app.")
        default:
            return ("Not connected", "Turn on Apple Health to mirror your ring's vitals, sleep, and activity.")
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Bindings & actions

    private func prefBinding(_ keyPath: WritableKeyPath<AppleHealthPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.prefs[keyPath: keyPath] },
            set: { store.prefs[keyPath: keyPath] = $0 }
        )
    }

    /// Master toggle. Turning ON requests HealthKit authorization (mirrors the notifications idiom:
    /// the toggle only latches ON once granted); denied → leave OFF and show the "Open Health" hint.
    /// First grant with no backfill decision yet → open the backfill dialog.
    private func setMaster(_ on: Bool) {
        guard on else {
            store.prefs.masterEnabled = false
            return
        }
        accessDenied = false
        Task {
            do {
                try await service.requestAuthorization()
            } catch {
                store.prefs.masterEnabled = false
                accessDenied = true
                return
            }
            guard service.authState == .authorized else {
                store.prefs.masterEnabled = false
                accessDenied = true
                return
            }
            store.prefs.masterEnabled = true
            if store.prefs.backfillChoice == .notAsked {
                showBackfillDialog = true
            } else {
                await service.exportIncremental(context: modelContext)
            }
        }
    }

    private func startFullHistoryBackfill() {
        store.resetWatermarks(to: nil)
        store.prefs.backfillChoice = .fullHistory
        Task { await service.exportHistory(context: modelContext) }
    }

    private func startNewDataOnly() {
        store.resetWatermarks(to: Date())
        store.prefs.backfillChoice = .newDataOnly
        Task { await service.exportIncremental(context: modelContext) }
    }

    /// Deep-link into the Health app so the user can flip PulseLoop's access back on; fall back to
    /// PulseLoop's iOS Settings page if the Health URL scheme can't be opened.
    private func openHealthApp() {
        if let health = URL(string: "x-apple-health://"), UIApplication.shared.canOpenURL(health) {
            UIApplication.shared.open(health)
        } else if let settings = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settings)
        }
    }
}
