import SwiftUI
import SwiftData

struct VitalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @State private var measuring: MeasurementSheet.Kind?

    var body: some View {
        let summary = MetricsService.buildTodaySummary(context: modelContext)
        let hrSamples = MetricsService.metricRange(metric: .heartRate, range: .twentyFourHours, context: modelContext)
        let spo2Samples = MetricsService.metricRange(metric: .spo2, range: .twentyFourHours, context: modelContext)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vitals").font(.system(size: 26, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                    Text("Live measurements and trends").font(.system(size: 14)).foregroundStyle(PulseColors.textSecondary)
                }

                HStack(spacing: 8) {
                    QuickActionButton(label: "Start HR", accent: true) { measuring = .hr }
                    QuickActionButton(label: "Start SpO₂") { measuring = .spo2 }
                }

                DetailCard(title: "Heart rate", color: PulseColors.heartRate) {
                    let label = TodayInsights.hrRangeLabel(hrSamples, summary.latestHeartRate?.value)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(label).font(.system(size: 40, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                        if !hrSamples.isEmpty || summary.latestHeartRate != nil {
                            Text("bpm range").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                        }
                    }
                    .padding(.top, 12)

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

                comingSoonCard(title: "HRV", message: "HRV decoding coming soon")
                comingSoonCard(title: "Skin temperature", message: "Temperature decoding coming soon")
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
        let confidence = state?.confidence.rawValue ?? "partial"
        return "\(status.uppercased()) · \(confidence.uppercased()) CONFIDENCE"
    }

    private func comingSoonCard(title: String, message: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            Text(message).font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

private struct VitalsMeasuringItem: Identifiable {
    let kind: MeasurementSheet.Kind
    var id: Int { kind == .hr ? 0 : 1 }
}
