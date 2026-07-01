import SwiftUI
import SwiftData

struct VitalsView: View {
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

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    var body: some View {
        guard let activeStore = store else {
            // One pre-`.task` frame before the store is built: themed background, zero DB work.
            return AnyView(PulseColors.background.ignoresSafeArea().task { ensureStore() })
        }
        let summary = activeStore.summary
        let hrSamples = activeStore.hrSamples
        let spo2Samples = activeStore.spo2Samples
        let stressSamples = activeStore.stressSamples
        let hrvSamples = activeStore.hrvSamples
        let tempSamples = activeStore.tempSamples
        let systolicSamples = activeStore.systolicSamples
        let diastolicSamples = activeStore.diastolicSamples
        let bloodSugarSamples = activeStore.bloodSugarSamples
        let fatigueSamples = activeStore.fatigueSamples

        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vitals").font(.system(size: 26, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                    Text("Live measurements and trends").font(.system(size: 14)).foregroundStyle(PulseColors.textSecondary)
                }

                // On-demand measurement buttons are capability-gated: a ring that can't do an instant
                // reading (e.g. Colmi has no spot SpO2) simply doesn't show that button.
                let caps = activeStore.capabilities
                if caps.contains(.manualHeartRate) || caps.contains(.manualSpo2) {
                    HStack(spacing: 8) {
                        if caps.contains(.manualHeartRate) {
                            QuickActionButton(label: "Start HR", accent: true) { measuring = .hr }
                        }
                        if caps.contains(.manualSpo2) {
                            QuickActionButton(label: "Start SpO₂") { measuring = .spo2 }
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.heartRate) {
                    DetailCard(title: "Heart rate", color: PulseColors.heartRate) {
                        let label = TodayInsights.hrRangeLabel(hrSamples, summary.latestHeartRate?.value)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(label).font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if !hrSamples.isEmpty || summary.latestHeartRate != nil {
                                Text("bpm range").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)

                        // swiftlint:disable:next line_length
                        Text("Resting estimate: \(summary.restingHeartRateEstimate.map { "\(Int($0))" } ?? "Calibrating")  ·  Peak today: \(summary.peakHeartRateToday.map { "\(Int($0))" } ?? "Not enough data")")
                            .font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
                            .padding(.top, 8)
                        Text("\(statusLine(summary, .heartRate))")
                            .font(.system(size: 10, weight: .medium)).tracking(1.0)
                            .foregroundStyle(PulseColors.textMuted)
                            .padding(.top, 4)

                        if hrSamples.count > 1 {
                            HRLineChart(samples: hrSamples).padding(.top, 12)
                        } else {
                            InlineEmptyState(title: "No HR samples yet", message: "Take a reading to start your trend.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.spo2) {
                    DetailCard(title: "Blood oxygen", color: PulseColors.spo2) {
                        let label = TodayInsights.averageLabel(spo2Samples, summary.latestSpO2?.value)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(label).font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if !spo2Samples.isEmpty || summary.latestSpO2 != nil {
                                Text("% avg").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)
                        Text("\(statusLine(summary, .spo2))")
                            .font(.system(size: 10, weight: .medium)).tracking(1.0)
                            .foregroundStyle(PulseColors.textMuted)
                            .padding(.top, 4)

                        if spo2Samples.count > 1 {
                            SpO2DotsChart(samples: spo2Samples).padding(.top, 12)
                        } else {
                            InlineEmptyState(title: "No SpO₂ samples yet", message: "Take a reading to start your trend.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.stress) {
                    DetailCard(title: "Stress", color: PulseColors.stress) {
                        if let latest = stressSamples.last?.value {
                            StressGaugeChart(value: latest).padding(.top, 12)
                        } else {
                            InlineEmptyState(title: "No stress data yet", message: "Wear the ring through the day and sync.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.hrv) {
                    DetailCard(title: "HRV", color: PulseColors.hrv) {
                        let label = hrvSamples.last.map { "\(Int($0.value))" } ?? "--"
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(label).font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if !hrvSamples.isEmpty {
                                Text("ms").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)
                        if hrvSamples.count > 1 {
                            HRVTrendBandChart(samples: hrvSamples).padding(.top, 12)
                        } else {
                            InlineEmptyState(title: "No HRV data yet", message: "HRV builds up over a few hours of wear.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.temperature) {
                    DetailCard(title: "Skin temperature", color: PulseColors.temperature) {
                        let formatted = tempSamples.last.map { UnitsFormatter.temperature(celsius: $0.value, units: units) }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(formatted?.value ?? "--").font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if let formatted {
                                Text(formatted.unit).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)
                        if tempSamples.count > 1 {
                            TemperatureRangeChart(samples: tempSamples).padding(.top, 12)
                        } else {
                            InlineEmptyState(title: "No temperature data yet", message: "Temperature trends appear after overnight wear.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.bloodPressureSystolic) {
                    DetailCard(title: "Blood pressure", color: PulseColors.bloodPressure) {
                        let sys = systolicSamples.last.map { Int($0.value) }
                        let dia = diastolicSamples.last.map { Int($0.value) }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(sys.map(String.init) ?? "--")
                                .font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            Text("/").font(.system(size: 28, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            Text(dia.map(String.init) ?? "--")
                                .font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if sys != nil, dia != nil {
                                Text("mmHg").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)
                        if sys == nil || dia == nil {
                            InlineEmptyState(title: "No blood pressure yet", message: "Take a combined measurement and sync.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.bloodSugar) {
                    DetailCard(title: "Blood sugar", color: PulseColors.bloodSugar) {
                        let latest = bloodSugarSamples.last.map { Int($0.value.rounded()) }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(latest.map(String.init) ?? "--")
                                .font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if latest != nil {
                                Text("mg/dL").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)
                        if latest == nil {
                            InlineEmptyState(title: "No blood sugar yet", message: "Estimated from your profile — set it in Settings → Profile.")
                        }
                    }
                }

                if activeStore.visibleMetrics.contains(.fatigue) {
                    DetailCard(title: "Fatigue", color: PulseColors.fatigue) {
                        let latest = fatigueSamples.last.map { Int($0.value) }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(latest.map(String.init) ?? "--")
                                .font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                            if latest != nil {
                                Text("/ 100").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                            }
                        }
                        .padding(.top, 12)
                        if latest == nil {
                            InlineEmptyState(title: "No fatigue data yet", message: "Wear the ring through the day and sync.")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .task { ensureStore(); if isActive { store?.refreshIfNeeded() } }
        // Rebuild once per coalesced persistence flush — but only while this tab is on screen, and
        // the store's signature check still makes it a no-op when nothing changed.
        .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
        // When returning to this tab, catch up on anything that changed while it was off-screen.
        .onChange(of: isActive) { _, active in if active { store?.refreshIfNeeded() } }
        .sheet(item: Binding(get: { measuring.map(VitalsMeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
            MeasurementSheet(kind: item.kind)
        })
    }

    /// Build the store exactly once, off the `body` path.
    private func ensureStore() {
        if store == nil { store = VitalsStore(modelContext: modelContext) }
    }

    private func statusLine(_ summary: TodaySummary, _ key: MetricKey) -> String {
        let state = summary.metricStates[key]
        let status = state?.status ?? "No reading yet"
        return status.uppercased()
    }

}

private struct VitalsMeasuringItem: Identifiable {
    let kind: MeasurementSheet.Kind
    var id: Int { kind == .hr ? 0 : 1 }
}
