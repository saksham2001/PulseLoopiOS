import SwiftUI
import SwiftData

/// Tap-through detail for the readiness score: the hero ring, the full contributor breakdown, what
/// couldn't be measured, a trend chart, and an explainer.
///
/// The breakdown is the reason this screen exists. The tile can only show the single biggest drag;
/// here every contributor is accounted for, with its earned/possible points and its own
/// explanation, plus an explicit list of what wasn't measured. A user should be able to reconstruct
/// the arithmetic — that's what "documented metrics, no black boxes" has to mean in practice.
struct ReadinessDetailView: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext

    @State private var period: DetailPeriod = .month
    @State private var latest: ReadinessSnapshot?
    /// Progress toward a first score, loaded only while there is none.
    @State private var progress: ReadinessProgress?
    @State private var points: [ReadinessTrendPoint] = []
    /// Observed so the screen re-reads when a background sync scores a new night while it's open.
    @State private var dataChange = PulseDataChange.shared

    enum DetailPeriod: String, CaseIterable, Identifiable {
        case week = "Week"
        case month = "Month"
        case quarter = "90 Days"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let latest, !latest.contributors.isEmpty {
                    breakdown(latest)
                }
                if let latest, !latest.missingKinds.isEmpty {
                    notMeasured(latest.missingKinds)
                }
                periodSelector
                trendSection
                explainer
            }
            .padding(16)
            .padding(.bottom, 40)
            .pulseGlassContainer(spacing: 18)
        }
        .background(PulseColors.background)
        .pageChrome("Readiness")
        .task(id: period) { reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 10) {
            if let latest {
                VitalRingGauge(
                    value: Double(latest.score),
                    domain: 0...100,
                    zones: ReadinessZones.all,
                    valueColor: ReadinessZones.color(for: latest.score),
                    centerValue: "\(latest.score)",
                    centerStatus: latest.band.rawValue,
                    size: 190,
                    lineWidth: 16
                )
                // Coverage is stated, never hidden: a score from a partial night is not the same
                // claim as one from a complete night, even at the same number.
                if latest.coverage < 1 {
                    Text("Based on \(Int((latest.coverage * 100).rounded()))% of the full picture")
                        .font(PulseFont.caption)
                        .foregroundStyle(PulseColors.textMuted)
                }
            } else {
                // Counting up to the first score. Shown as a ring for the same reason the card
                // does: it reads as filling rather than as an error state.
                ZStack {
                    Circle()
                        .stroke(PulseColors.textMuted.opacity(0.15), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress?.fraction ?? 0))
                        .stroke(PulseColors.readiness.opacity(0.75),
                                style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if let progress, progress.nightsCollected > 0 {
                        VStack(spacing: 0) {
                            Text("\(progress.nightsCollected)")
                                .font(PulseFont.numberHero)
                                .monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                            Text(progress.centerCaption)
                                .font(PulseFont.caption)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                    } else {
                        Image(systemName: "bolt.heart")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(PulseColors.readiness.opacity(0.6))
                    }
                }
                .frame(width: 170, height: 170)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(progressAccessibilityLabel)

                Text(emptyTitle)
                    .font(PulseFont.title3.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Text(emptyDetail)
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColors.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var emptyTitle: String { progress?.title ?? "No score yet" }

    private var emptyDetail: String {
        progress?.detail
            ?? "Wear your ring overnight. Readiness needs about a week of nights before it can compare tonight to your normal."
    }

    private var progressAccessibilityLabel: String {
        guard let progress, progress.nightsCollected > 0 else { return emptyDetail }
        return "\(progress.nightsCollected) of \(progress.nightsNeeded) nights collected. \(progress.detail)"
    }

    // MARK: - Breakdown

    private func breakdown(_ readiness: ReadinessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("What drove it")
            // Already sorted biggest-drag-first by `ReadinessScore`; re-sorted defensively so an
            // older stored row can't present itself out of order.
            ForEach(readiness.contributors.sorted { $0.drag > $1.drag }, id: \.kindRaw) { record in
                ReadinessContributorRow(record: record)
            }
        }
        .padding(14)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    /// Naming what's absent matters as much as scoring what's present — it's the difference between
    /// "your temperature was fine" and "your temperature wasn't measured".
    private func notMeasured(_ kinds: [ReadinessContributor.Kind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Not measured last night")
            Text(kinds.map(\.title).joined(separator: ", "))
                .font(PulseFont.footnote)
                .foregroundStyle(PulseColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Missing signals are left out of the score rather than counted as zero.")
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textMuted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    // MARK: - Trend

    private var periodSelector: some View {
        Picker("Period", selection: $period) {
            ForEach(DetailPeriod.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Trend")
            if points.count < 2 {
                Text("Not enough scored days for this period.")
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ReadinessTrendChart(points: points)
                Text("The line is your 7-day average, so one rough night reads as noise rather than a trend.")
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    // MARK: - Explainer

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("How this is calculated")
            Text(
                "Readiness combines your overnight HRV, resting heart rate, sleep, skin temperature, and yesterday's "
                + "activity — each compared against your own baseline rather than a population average."
            )
                .font(PulseFont.footnote)
                .foregroundStyle(PulseColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Every weight and threshold is documented in the project docs (docs/project/readiness.md). It is computed on this device and never leaves it.")
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textMuted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(PulseFont.caption2)
            .tracking(0.6)
            .foregroundStyle(PulseColors.textMuted)
    }

    // MARK: - Data

    private func reload() {
        latest = ReadinessRepository.latest(context: modelContext).map(ReadinessSnapshot.init)
        // Only while there is nothing to show — this walks the baseline window.
        progress = latest == nil ? ReadinessService.progress(context: modelContext) : nil

        let calendar = Calendar.current
        // Anchor on the newest scored day, not `Date()`, so a demo store (whose "today" is its
        // newest seeded day) and a phone that hasn't synced today both still show their history.
        let anchor = latest?.date ?? calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(period.days - 1), to: anchor) ?? anchor
        points = ReadinessRepository.rows(from: start, to: anchor, context: modelContext)
            .map { ReadinessTrendPoint(date: $0.date, score: $0.score, band: $0.band) }
    }
}
