import SwiftUI
import SwiftData

/// The HRV panel: the time- and frequency-domain measures the YCBT body-data record (`05 33`)
/// reports alongside the single HRV scalar every ring gives.
///
/// Reached only from the HRV detail screen, and only on rings that declare `.hrvDetail` — two taps
/// off the dashboard rather than six new cards on it. These are numbers you read occasionally to
/// understand a trend, not ones you glance at on a home screen.
///
/// One card per measure: latest value, a sparkline over the selected period, and a plain-language
/// explanation. No zone colouring — unlike heart rate or SpO₂ these have no population-normal band
/// worth drawing, and inventing one would be exactly the black box the project exists to avoid.
struct AutonomicDetailView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var period: MetricDetailView.DetailPeriod = .week
    @State private var series: [MeasurementKind: [MetricSample]] = [:]
    /// Observed so the cards refresh when a background sync lands while this is open.
    @State private var dataChange = PulseDataChange.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                periodSelector
                ForEach(MeasurementKind.autonomicKinds, id: \.self) { kind in
                    card(for: kind)
                }
                explainer
            }
            .padding(16)
            .padding(.bottom, 40)
            .pulseGlassContainer(spacing: 18)
        }
        .background(PulseColors.background)
        .pageChrome("HRV Detail")
        .task(id: period) { reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
    }

    private var periodSelector: some View {
        Picker("Period", selection: $period) {
            ForEach(MetricDetailView.DetailPeriod.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Per-measure card

    @ViewBuilder
    private func card(for kind: MeasurementKind) -> some View {
        let samples = series[kind] ?? []
        // A ring that reports some of the panel but not all shouldn't show empty cards for the rest.
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.shortTitle.uppercased())
                        .font(PulseFont.caption2.weight(.semibold)).tracking(1.0)
                        .foregroundStyle(PulseColors.textMuted)
                    Spacer()
                    Text(formatted(samples.last?.value, kind: kind))
                        .font(PulseFont.numberXL).monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                    if !kind.unit.isEmpty {
                        Text(kind.unit)
                            .font(PulseFont.caption).foregroundStyle(PulseColors.textMuted)
                    }
                }
                if samples.count >= 2 {
                    MiniSparkline(values: samples.map(\.value), color: PulseColors.hrv)
                        .frame(height: 40)
                }
                HStack(spacing: 0) {
                    stat("Average", formatted(average(samples), kind: kind))
                    stat("Min", formatted(samples.map(\.value).min(), kind: kind))
                    stat("Max", formatted(samples.map(\.value).max(), kind: kind))
                }
                Text(blurb(for: kind))
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title.uppercased())
                .font(PulseFont.caption2).tracking(0.6)
                .foregroundStyle(PulseColors.textMuted).lineLimit(1)
            Text(value)
                .font(PulseFont.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT THIS MEANS").font(PulseFont.caption2.weight(.semibold)).tracking(1.0)
                .foregroundStyle(PulseColors.textMuted)
            Text("These break the single HRV number down into its parts. They're computed by the ring's "
                 + "own firmware from beat-to-beat timing, so treat them as wellness signals rather than "
                 + "clinical measurements — and read them as trends against your own history, not against "
                 + "anyone else's numbers.")
                .font(PulseFont.footnote.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    // MARK: - Copy

    private func blurb(for kind: MeasurementKind) -> String {
        switch kind {
        case .rmssd:
            return "The beat-to-beat measure most tied to rest and recovery. It tracks the parasympathetic "
                + "\"rest and digest\" side, and tends to fall after hard training, alcohol, or a poor night."
        case .sdnn:
            return "Overall variability across the whole window. It picks up slower rhythms than RMSSD, so "
                + "it moves more with the length of the recording than with any single night."
        case .pnn50:
            return "The share of consecutive beats differing by more than 50 ms. It moves with RMSSD and is "
                + "another read on parasympathetic activity."
        case .lfPower:
            return "Power in the low-frequency band. Often described as sympathetic, but it reflects a mix of "
                + "influences including blood-pressure regulation — worth watching as a trend, not a verdict."
        case .hfPower:
            return "Power in the high-frequency band, driven largely by breathing. It rises with slow, deep "
                + "breathing and with restful sleep."
        case .lfHfRatio:
            return "The balance between the two bands, computed here from the LF and HF powers themselves. "
                + "It's commonly read as a stress-versus-recovery balance, though that reading is debated."
        default:
            return ""
        }
    }

    // MARK: - Data

    private func reload() {
        let now = Date()
        let start = now.addingTimeInterval(-Double(period.days) * 86_400)
        var next: [MeasurementKind: [MetricSample]] = [:]
        for kind in MeasurementKind.autonomicKinds {
            let rows = MetricsRepository.measurements(
                kind: kind, start: start, end: now, limit: 500, context: modelContext
            )
            // The repository returns newest-first; a chart wants chronological order.
            next[kind] = rows.reversed().map { MetricSample(timestamp: $0.timestamp, value: $0.value) }
        }
        series = next
    }

    private func average(_ samples: [MetricSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    }

    /// Ratios need a decimal; everything else in the panel is a whole number at display precision.
    private func formatted(_ value: Double?, kind: MeasurementKind) -> String {
        guard let value, value.isFinite else { return "--" }
        return kind == .lfHfRatio ? String(format: "%.2f", value) : "\(Int(value.rounded()))"
    }
}
