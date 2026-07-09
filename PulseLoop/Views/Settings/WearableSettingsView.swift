import SwiftUI
import SwiftData

/// Wearable detail screen: connection state and the ring actions (sync / find / disconnect / forget /
/// pair). Relocated from the old flat `SettingsView` Ring section.
struct WearableSettingsView: View {
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var devices: [Device]
    @Binding var path: NavigationPath

    /// Colmi reports battery in-band (not via a GATT characteristic), so it lands on the persisted
    /// `Device` rather than `ble.batteryPercent`. Mirror the header's fallback so this never shows "--"
    /// when the header shows a value.
    private var batteryPercent: Int? { ble.batteryPercent ?? devices.first?.batteryPercent }
    private var wearableDisplayName: String {
        let storedModel = WearableModel.model(id: devices.first?.wearableModelID)
        return ble.activeWearableModel?.displayName
            ?? storedModel?.displayName
            ?? ble.activeDeviceType?.displayName
            ?? devices.first?.deviceType.displayName
            ?? "Connected ring"
    }

    /// `RelativeDateTimeFormatter` is expensive to allocate; reuse one instance instead of building
    /// a fresh formatter on every access.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var lastSyncedLabel: String {
        guard let date = coordinator.lastSyncAt else { return "Not yet" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if ble.state == .connected {
                    SettingsGroup(header: "Connected ring") {
                        FormValueRow(title: "Device") { Text(wearableDisplayName).foregroundStyle(PulseColors.textMuted) }
                        FormValueRow(title: "Battery") { Text(batteryPercent.map { "\($0)%" } ?? "--").foregroundStyle(PulseColors.textMuted) }
                        FormValueRow(title: "Last synced") { Text(lastSyncedLabel).foregroundStyle(PulseColors.textMuted) }
                    }
                    BatteryHistorySection()
                    SecondaryButton(title: "Sync now", systemImage: "clock.arrow.circlepath") { coordinator.syncNow() }
                    SecondaryButton(title: "Find ring", systemImage: "bell.fill") { coordinator.findRing() }
                    SecondaryButton(title: "Disconnect", systemImage: "xmark.circle") { ble.disconnect() }
                    SecondaryButton(title: "Forget ring", systemImage: "trash") { ble.forget() }
                } else {
                    SettingsGroup(header: "No ring connected") {
                        FormValueRow(title: "Status") { Text(ble.state.rawValue.capitalized).foregroundStyle(PulseColors.textMuted) }
                    }
                    PrimaryButton(title: "Add a ring", systemImage: "plus.circle") {
                        path.append(AppRoute.pairing)
                    }
                    if ble.hasLastKnownRing && ble.state != .reconnecting {
                        SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") { ble.connectLastKnown() }
                        SecondaryButton(title: "Forget ring", systemImage: "trash") { ble.forget() }
                    }
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Wearable")
    }
}

/// Battery-drainage chart for the connected ring. Reads the throttled `BatterySample` history (written
/// by `EventPersistenceSubscriber`) for the selected window and draws it with the shared `ZoneLineChart`
/// on a fixed 0–100 axis. The fetch is on-demand (only while this screen is visible) and re-runs when the
/// window changes or new data is persisted — so it adds no ongoing cost.
private struct BatteryHistorySection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var dataChange = PulseDataChange.shared
    @State private var range: MetricRange = .twentyFourHours
    @State private var samples: [ChartSample] = []

    /// Only the two windows that make sense for battery: a day of drainage, or a week of cycles.
    private static let ranges: [MetricRange] = [.twentyFourHours, .sevenDays]

    private func rangeLabel(_ r: MetricRange) -> String { r == .twentyFourHours ? "24h" : "7d" }

    private func color(for percent: Double) -> Color {
        percent <= 20 ? PulseColors.danger : (percent <= 50 ? PulseColors.warning : PulseColors.success)
    }

    var body: some View {
        SettingsGroup(header: "Battery history") {
            FormValueRow(title: "Range") {
                Picker("Range", selection: $range) {
                    ForEach(Self.ranges, id: \.self) { Text(rangeLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            FormField {
                if samples.count >= 2 {
                    ZoneLineChart(
                        samples: samples,
                        metric: .heartRate,          // axis styling only; battery uses its own domain + colors
                        yDomain: 0...100,
                        range: range,
                        showAxes: true,
                        height: 160,
                        colorForValue: color(for:)
                    )
                } else {
                    Text("Not enough data yet — battery history builds up as your ring reports its level.")
                        .font(.system(size: 13))
                        .foregroundStyle(PulseColors.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
    }

    private func reload() {
        let end = Date()
        let start: Date
        switch range {
        case .twentyFourHours: start = Calendar.current.date(byAdding: .hour, value: -24, to: end) ?? end
        default:               start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        }
        let rows = MetricsRepository.batterySamples(start: start, end: end, context: modelContext)
        samples = rows.map { ChartSample(timestamp: $0.timestamp, value: Double($0.percent)) }
    }
}
