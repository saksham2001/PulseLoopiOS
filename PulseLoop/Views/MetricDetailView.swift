import SwiftUI
import SwiftData
import Charts

/// Tap-through detail for one vitals metric: period selector, a full-axis zone chart, stat tiles,
/// a threshold legend, an explainer, and a disclaimer for estimated metrics. Re-fetches through the
/// existing `MetricsService.metricRange` (the same fetch path the dashboard uses) when the period
/// changes — no new data plumbing.
struct MetricDetailView: View {
    let metric: MetricKind
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var period: DetailPeriod = .today
    @State private var primary: [MetricSample] = []
    @State private var secondary: [MetricSample] = []   // diastolic, for BP
    /// The SpO₂ window holds hourly readings this ring computed from heart rate (`EstimatedSpO2`).
    @State private var spo2Estimated = false
    /// The window's stored readings, newest first — the deletable list under the chart (issue #60).
    @State private var readings: [VitalReading] = []
    @State private var readingsExpanded = false
    @State private var readingsVisible = Self.readingsPageSize
    @State private var pendingDelete: VitalReading?
    /// Observed so the detail chart/tiles re-fetch when a background sync lands while this is open.
    @State private var dataChange = PulseDataChange.shared

    private var profile: UserPhysiologyProfile { UserPhysiologyProfile(profiles.first) }
    private var units: UnitsPreference { profiles.first?.units ?? .metric }
    private var glucoseUnit: GlucoseUnit { profile.preferredGlucoseUnit }

    /// Canonical stored value (°C, mg/dL) → user's display unit. Identity for every
    /// other metric. `toRaw` is the inverse, needed to color the line (thresholds are
    /// evaluated in canonical units) after the samples are converted for display.
    private func toDisplay(_ raw: Double) -> Double {
        switch metric {
        case .temperature: return UnitsFormatter.temperatureValue(celsius: raw, units: units)
        case .glucose: return UnitsFormatter.glucoseValue(mgdl: raw, unit: glucoseUnit)
        default: return raw
        }
    }
    private func toRaw(_ disp: Double) -> Double {
        switch metric {
        case .temperature: return units == .imperial ? (disp - 32) * 5 / 9 : disp
        case .glucose: return glucoseUnit == .mmol ? disp * 18.0182 : disp
        default: return disp
        }
    }
    private var unitLabel: String {
        switch metric {
        case .temperature: return UnitsFormatter.temperatureUnit(units)
        case .glucose: return UnitsFormatter.glucoseUnit(glucoseUnit)
        default: return metric.unit
        }
    }

    enum DetailPeriod: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }
        var range: MetricRange {
            switch self {
            case .today: return .twentyFourHours
            case .week: return .sevenDays
            case .month: return .thirtyDays
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                periodSelector
                chartSection
                statTiles
                readingsCard
                legend
                explainer
                if isEstimatedMetric { disclaimer }
            }
            .padding(16)
            .padding(.bottom, 40)
            // Stacked glass cards share one container so their glass renders/blends consistently.
            .pulseGlassContainer(spacing: 18)
        }
        .background(PulseColors.background)
        // Shared glass chrome: centered title + glass back button, no system nav
        // bar (so the zoom transition doesn't reflow the content).
        .pageChrome(metric.title)
        .task(id: period) { readingsVisible = Self.readingsPageSize; reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
        .alert("Delete this reading?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { reading in
            Button("Delete", role: .destructive) { delete(reading) }
            Button("Cancel", role: .cancel) {}
        } message: { reading in
            Text("\(readingText(reading))\(unitLabel.isEmpty ? "" : " \(unitLabel)") at \(readingTime(reading.timestamp)).\n\n"
                 + "This can't be undone, and the reading stays deleted the next time your ring syncs.")
        }
    }

    // MARK: - Period selector

    private var periodSelector: some View {
        Picker("Period", selection: $period) {
            ForEach(DetailPeriod.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        let dispPrimary = primary.map { MetricSample(timestamp: $0.timestamp, value: toDisplay($0.value)) }
        let chart = ChartSampleBuilder.from(dispPrimary)
        let baseline = baselineForChart
        VStack(alignment: .leading, spacing: 8) {
            if !unitLabel.isEmpty {
                Text(unitLabel)
                    .font(PulseFont.caption.weight(.semibold))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if chart.count < 2 {
                Text("Not enough data for this period.")
                    .font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else if metric == .bloodPressure {
                bloodPressureChart
            } else {
                ZoneLineChart(
                    samples: chart,
                    metric: metric,
                    yDomain: yDomain(chart),
                    referenceBands: detailBands(baseline: baseline),
                    range: period.range,
                    showPoints: metric == .spo2,
                    showAxes: true,
                    dashedRules: dashedRules(baseline: baseline).map(toDisplay),
                    height: 240,
                    thresholds: VitalsThresholdEngine.zoneThresholds(for: metric, profile: profile, baseline: baseline).map(toDisplay),
                    colorForValue: { value in
                        // Samples are in display units; color lookup needs canonical units.
                        VitalsThresholdEngine.colorToken(forValue: toRaw(value), metric: metric, profile: profile, baseline: baseline).color
                    }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    /// BP shows two series — systolic in the metric accent, diastolic lighter.
    private var bloodPressureChart: some View {
        let sys = ChartSampleBuilder.from(primary)
        let dia = ChartSampleBuilder.from(secondary)
        let allValues = (primary + secondary).map(\.value).filter { $0 > 0 }
        let lo = (allValues.min() ?? 50) - 10
        let hi = (allValues.max() ?? 160) + 10
        return Chart {
            ForEach(sys) { s in
                LineMark(x: .value("Time", s.timestamp), y: .value("Systolic", s.value), series: .value("Series", "Systolic"))
                    .foregroundStyle(PulseColors.bloodPressure)
                    .interpolationMethod(.monotone)
            }
            ForEach(dia) { s in
                LineMark(x: .value("Time", s.timestamp), y: .value("Diastolic", s.value), series: .value("Series", "Diastolic"))
                    .foregroundStyle(PulseColors.bloodPressure.opacity(0.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: lo...hi)
        .frame(height: 200)
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        let values = primary.map(\.value).filter { $0 > 0 }
        let latest = values.last.map { fmt(toDisplay($0)) } ?? "--"
        let avg = values.isEmpty ? "--" : fmt(toDisplay(values.reduce(0, +) / Double(values.count)))
        let lo = values.min().map { fmt(toDisplay($0)) } ?? "--"
        let hi = values.max().map { fmt(toDisplay($0)) } ?? "--"
        return HStack(spacing: 0) {
            stat("Latest", latest)
            statDivider
            stat("Average", avg)
            statDivider
            stat("Min", lo)
            statDivider
            stat("Max", hi)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 8) {
            Text(title.uppercased())
                .font(PulseFont.caption2).tracking(0.6)
                .foregroundStyle(PulseColors.textMuted)
                .lineLimit(1)
            Text(value)
                .font(PulseFont.numberXL).monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(PulseColors.borderSubtle).frame(width: 1, height: 34)
    }

    // MARK: - Readings

    /// How many readings the list shows before asking for more — a Month of all-day history is
    /// thousands of rows, and someone scanning for one bad measurement reads a page.
    private static let readingsPageSize = 50

    /// The window's individual readings with a delete per row (issue #60). Deletion only — a recorded
    /// value can be removed, never edited — and always behind a confirmation.
    private var readingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(PulseMotion.spring) { readingsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("READINGS").font(PulseFont.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                    Spacer()
                    Text("\(readings.count)").font(PulseFont.caption).monospacedDigit().foregroundStyle(PulseColors.textMuted)
                    Image(systemName: readingsExpanded ? "chevron.up" : "chevron.down")
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Readings, \(readings.count)")
            .accessibilityHint(readingsExpanded ? "Hides the readings" : "Shows the readings")

            if readingsExpanded {
                if readings.isEmpty {
                    Text("No readings in this period.")
                        .font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(readings.prefix(readingsVisible)) { reading in
                            readingRow(reading)
                        }
                    }
                    if readings.count > readingsVisible {
                        Button("Show \(min(Self.readingsPageSize, readings.count - readingsVisible)) more") {
                            readingsVisible += Self.readingsPageSize
                        }
                        .font(PulseFont.footnote.weight(.semibold))
                        .foregroundStyle(PulseColors.accent)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    Spacer().frame(height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func readingRow(_ reading: VitalReading) -> some View {
        HStack(spacing: 6) {
            Text(readingTime(reading.timestamp))
                .font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(readingText(reading))
                .font(PulseFont.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
            if !unitLabel.isEmpty {
                Text(unitLabel).font(PulseFont.caption2.weight(.regular)).foregroundStyle(PulseColors.textMuted)
            }
            if reading.isEstimated {
                Text("Estimated")
                    .font(PulseFont.caption2.weight(.semibold))
                    .foregroundStyle(PulseColors.warning)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(PulseColors.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Button { pendingDelete = reading } label: {
                Image(systemName: "trash")
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete reading \(readingText(reading)) at \(readingTime(reading.timestamp))")
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .accessibilityElement(children: .contain)
    }

    private func readingText(_ reading: VitalReading) -> String {
        let primary = fmt(toDisplay(reading.value))
        guard let secondary = reading.secondary else { return primary }
        return "\(primary)/\(fmt(toDisplay(secondary)))"
    }

    private func readingTime(_ date: Date) -> String {
        period == .today
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    private func delete(_ reading: VitalReading) {
        VitalReadings.delete(reading, context: modelContext)
        pendingDelete = nil
        reload()
    }

    // MARK: - Legend

    private var legend: some View {
        let zones = VitalsThresholdEngine.zones(for: metric, profile: profile, baseline: baselineForChart)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REFERENCE ZONES").font(PulseFont.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                Spacer()
                // HR zones are user-configurable (Standard / Auto / Custom) — deep-link to the editor.
                if metric == .heartRate {
                    Button("Edit") { path.append(AppRoute.settingsHeartRateZones) }
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.accent)
                }
            }
            ForEach(zones) { zone in
                HStack(spacing: 10) {
                    Circle().fill(zone.color).frame(width: 8, height: 8)
                    Text(zone.label).font(PulseFont.footnote).foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    Text(rangeText(zone)).font(PulseFont.caption.weight(.regular)).monospacedDigit().foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT THIS MEANS").font(PulseFont.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            Text(explainerText).font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(PulseColors.warning)
            Text(disclaimerText).font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous).stroke(PulseColors.warning.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Data

    private func reload() {
        if metric == .bloodPressure {
            primary = MetricsService.metricRange(metric: .bloodPressureSystolic, range: period.range, context: modelContext)
            secondary = MetricsService.metricRange(metric: .bloodPressureDiastolic, range: period.range, context: modelContext)
        } else if metric == .spo2 {
            let series = MetricsService.spo2Series(range: period.range, context: modelContext)
            primary = series.samples
            secondary = []
            spo2Estimated = series.isEstimated
        } else {
            primary = MetricsService.metricRange(metric: metric.metricKey, range: period.range, context: modelContext)
            secondary = []
        }
        let window = readingsWindow
        readings = VitalReadings.load(metric: metric, start: window.start, end: window.end, context: modelContext)
    }

    /// The span the readings list covers — the same rolling window the chart fetches.
    private var readingsWindow: DateInterval {
        let now = Date()
        let seconds: TimeInterval
        switch period {
        case .today: seconds = 86_400
        case .week: seconds = 7 * 86_400
        case .month: seconds = 30 * 86_400
        }
        return DateInterval(start: now.addingTimeInterval(-seconds), end: now.addingTimeInterval(1))
    }

    /// HRV detail can compute a real baseline because Week/Month fetch enough history.
    private var baselineForChart: BaselineStats? {
        metric == .hrv ? BaselineStats.compute(primary) : nil
    }

    private func detailBands(baseline: BaselineStats?) -> [ReferenceBand] {
        switch metric {
        case .spo2: return [ReferenceBand(lower: 95, upper: 100, colorToken: .cyan)]
        case .hrv:
            guard let baseline, baseline.isEstablished else { return [] }
            let half = max(6, baseline.mean * 0.12)
            return [ReferenceBand(lower: baseline.mean - half, upper: baseline.mean + half, colorToken: .metricAccent(.hrv), opacity: 0.12)]
        default: return []
        }
    }

    private func dashedRules(baseline: BaselineStats?) -> [Double] {
        if metric == .spo2 { return [92] }
        if metric == .hrv, let baseline, baseline.isEstablished { return [baseline.mean] }
        return []
    }

    private func yDomain(_ samples: [ChartSample]) -> ClosedRange<Double> {
        if metric == .spo2 { return 88...100 }
        if metric == .stress || metric == .fatigue { return 0...100 }
        let values = samples.map(\.value).filter { $0 > 0 }
        guard let lo = values.min(), let hi = values.max(), lo < hi else { return 0...100 }
        let pad = (hi - lo) * 0.1 + 1
        return (lo - pad)...(hi + pad)
    }

    // MARK: - Formatting helpers

    /// Formats a value already in display units (temperature and mmol/L glucose want one decimal).
    private func fmt(_ value: Double) -> String {
        if metric == .temperature { return String(format: "%.1f", value) }
        if metric == .glucose, glucoseUnit == .mmol { return String(format: "%.1f", value) }
        return "\(Int(value.rounded()))"
    }

    private func rangeText(_ zone: MetricZone) -> String {
        // Zone bounds are canonical; convert to display units before formatting.
        switch (zone.lower.map(toDisplay), zone.upper.map(toDisplay)) {
        case let (lo?, hi?): return "\(fmt(lo))–\(fmt(hi))"
        case let (lo?, nil): return "≥ \(fmt(lo))"
        case let (nil, hi?): return "< \(fmt(hi))"
        default: return ""
        }
    }

    private var isEstimatedMetric: Bool {
        metric == .glucose || (metric == .spo2 && spo2Estimated)
    }

    private var explainerText: String {
        switch metric {
        case .heartRate:
            return "Resting heart rate reflects how hard your heart works at rest. Guidelines cite 60–100 bpm, "
                + "but most healthy adults rest between 50 and 90; fitness, medication, caffeine, and stress all shift it. "
                + "You can adjust your zones from the legend above."
        case .spo2:
            return "Blood oxygen (SpO₂) is the percentage of oxygen your blood carries. 95–100% is normal; "
                + "altitude and lung conditions can lower it."
        case .hrv:
            return "Heart-rate variability is the variation between beats. It's highly individual, so we track it "
                + "against your personal baseline rather than a universal cutoff."
        case .bloodPressure:
            return "Blood pressure is systolic over diastolic (mmHg). The category is the worse of the two. "
                + "A ring estimate is not a substitute for a cuff."
        case .stress:
            return "A device wellness score from 0–100 based on heart-rate patterns. Lower is calmer. "
                + "It's an estimate, not a medical stress measure."
        case .fatigue:
            return "A device wellness score from 0–100 estimating tiredness. Higher means more fatigue. "
                + "It's a ring estimate, not a clinical scale."
        case .glucose:
            return "An estimated glucose value. No smart ring is cleared to measure glucose, so treat this "
                + "as a wellness estimate only."
        case .temperature:
            return "Skin temperature from the ring runs cooler than core body temperature. "
                + "Trends over time matter more than any single reading."
        }
    }

    private var disclaimerText: String {
        switch metric {
        case .glucose:
            return "Estimated wellness metric — not for dosing or diabetes decisions. No smart ring or watch is "
                + "FDA-authorized to measure or estimate glucose on its own."
        case .spo2:
            return EstimatedSpO2.disclaimer
        case .bloodPressure:
            return "Ring blood pressure is an estimate. Calibrate against a validated cuff in Settings → Calibration, "
                + "and talk to a clinician about persistent high or low readings."
        default: return ""
        }
    }
}
