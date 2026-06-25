import SwiftUI
import SwiftData

struct VitalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @State private var measuring: MeasurementSheet.Kind?

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    var body: some View {
        let summary = MetricsService.buildTodaySummary(context: modelContext)
        let hrSamples = MetricsService.metricRange(metric: .heartRate, range: .twentyFourHours, context: modelContext)
        let spo2Samples = MetricsService.metricRange(metric: .spo2, range: .twentyFourHours, context: modelContext)
        let stressSamples = MetricsService.metricRange(metric: .stress, range: .twentyFourHours, context: modelContext)
        let hrvSamples = MetricsService.metricRange(metric: .hrv, range: .twentyFourHours, context: modelContext)
        let tempSamples = MetricsService.metricRange(metric: .temperature, range: .twentyFourHours, context: modelContext)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vitals").font(.system(size: 26, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                    Text("Live measurements and trends").font(.system(size: 14)).foregroundStyle(PulseColors.textSecondary)
                }

                // On-demand measurement buttons are capability-gated: a ring that can't do an instant
                // reading (e.g. Colmi has no spot SpO2) simply doesn't show that button.
                let caps = MetricsService.deviceCapabilities(modelContext)
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

                if MetricsService.isVisible(.heartRate, context: modelContext) {
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

                if MetricsService.isVisible(.spo2, context: modelContext) {
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

                if MetricsService.isVisible(.stress, context: modelContext) {
                    DetailCard(title: "Stress", color: PulseColors.stress) {
                        if let latest = stressSamples.last?.value {
                            StressGaugeChart(value: latest).padding(.top, 12)
                        } else {
                            InlineEmptyState(title: "No stress data yet", message: "Wear the ring through the day and sync.")
                        }
                    }
                }

                if MetricsService.isVisible(.hrv, context: modelContext) {
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

                if MetricsService.isVisible(.temperature, context: modelContext) {
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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .sheet(item: Binding(get: { measuring.map(VitalsMeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
            MeasurementSheet(kind: item.kind)
        }
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
