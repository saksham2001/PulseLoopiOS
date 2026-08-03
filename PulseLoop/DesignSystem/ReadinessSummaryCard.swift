import SwiftUI

/// Band colouring for readiness, shared by the summary card, the detail hero, and the trend chart so
/// a score is never drawn in one band while being labelled another. Thresholds mirror
/// `ReadinessScore.band`; `ReadinessTileTests` asserts they agree.
///
/// Lives outside any view because three different surfaces need it and none of them should depend
/// on another's type name.
enum ReadinessZones {
    static let all: [MetricZone] = [
        MetricZone(id: "rest", label: "Rest needed", lower: 0, upper: 55,
                   severity: .high, colorToken: .orange,
                   explanation: "Your body is still recovering. Keep today easy."),
        MetricZone(id: "moderate", label: "Moderate", lower: 55, upper: 70,
                   severity: .watch, colorToken: .amber,
                   explanation: "Partial recovery. Moderate effort is fine; hold back on intensity."),
        MetricZone(id: "ready", label: "Ready", lower: 70, upper: 85,
                   severity: .normal, colorToken: .cyan,
                   explanation: "Recovered. A normal training day."),
        MetricZone(id: "primed", label: "Primed", lower: 85, upper: 101,
                   severity: .optimal, colorToken: .mint,
                   explanation: "Well recovered — a good day to push.")
    ]

    static func color(for score: Int) -> Color {
        all.first { $0.contains(Double(score)) }?.color ?? PulseColors.readiness
    }
}

/// Readiness as a **full-width** card, pinned directly under the Today hero.
///
/// Deliberately not a tile in the reorderable grid. Every other tile reports one measurement;
/// readiness is a verdict *over* those measurements — HRV, resting HR, sleep, temperature and
/// yesterday's load collapsed into one number. Sitting it beside a peer tile framed it as a sibling
/// metric, which is the wrong mental model, and half a tile's width couldn't carry the reasoning
/// that stops it being a black box.
///
/// The extra width buys the top two contributors instead of one truncated line, so the card answers
/// "how recovered am I, and why" without a tap.
struct ReadinessSummaryCard: View {
    let readiness: ReadinessSnapshot?
    /// Progress toward a first score. Drives the empty state so it counts down instead of
    /// repeating an open-ended instruction.
    let progress: ReadinessProgress?
    let calibration: CalibrationState
    var onTap: () -> Void

    /// How many contributor lines the width affords before it starts to read as a list.
    private static let maxReasons = 2

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let readiness {
                    scored(readiness)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(PulseColors.readiness).frame(width: 8, height: 8)
                .shadow(color: PulseColors.readiness.opacity(0.7), radius: 5)
            Text("READINESS")
                .font(PulseFont.caption2)
                .tracking(0.6)
                .foregroundStyle(PulseColors.textMuted)
            Spacer(minLength: 0)
            // Coverage is surfaced, never hidden: a score from a partial night is a weaker claim
            // than the same number from a complete one.
            if let readiness, readiness.coverage < 1 {
                Text("\(Int((readiness.coverage * 100).rounded()))% of signals")
                    .font(PulseFont.micro)
                    .foregroundStyle(PulseColors.textMuted)
            }
        }
    }

    @ViewBuilder
    private func scored(_ readiness: ReadinessSnapshot) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VitalRingGauge(
                value: Double(readiness.score),
                domain: 0...100,
                zones: ReadinessZones.all,
                valueColor: ReadinessZones.color(for: readiness.score),
                centerValue: "\(readiness.score)",
                centerStatus: readiness.band.rawValue,
                size: 112,
                lineWidth: 10
            )

            VStack(alignment: .leading, spacing: 8) {
                ForEach(reasons(readiness), id: \.kindRaw) { record in
                    reasonRow(record)
                }
                if reasons(readiness).isEmpty {
                    Text("Every signal at or above your baseline.")
                        .font(PulseFont.caption)
                        .foregroundStyle(PulseColors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One reason line: a band-coloured dot, the contributor's own explanation, and how much it cost.
    private func reasonRow(_ record: ReadinessContributorRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dragColor(record))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.detail)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("−\(formatted(record.drag)) pts")
                    .font(PulseFont.micro)
                    .foregroundStyle(PulseColors.textMuted)
                    .monospacedDigit()
            }
        }
    }

    /// The contributors actually holding the score back, worst first. Nothing is listed on a clean
    /// night rather than manufacturing a reason.
    private func reasons(_ readiness: ReadinessSnapshot) -> [ReadinessContributorRecord] {
        readiness.contributors
            .filter { $0.drag > 0.5 }
            .sorted { $0.drag > $1.drag }
            .prefix(Self.maxReasons)
            .map { $0 }
    }

    /// Coloured by how much of its own points the contributor lost, so the eye lands on the problem.
    private func dragColor(_ record: ReadinessContributorRecord) -> Color {
        guard record.maxPoints > 0 else { return PulseColors.textMuted }
        let lost = record.drag / record.maxPoints
        if lost >= 0.45 { return PulseColors.zoneOrange }
        if lost >= 0.15 { return PulseColors.zoneAmber }
        return PulseColors.zoneMint
    }

    @ViewBuilder
    private var empty: some View {
        HStack(spacing: 14) {
            // Nights collected, as a ring — the same visual language as a score, so the card reads
            // as "filling up" rather than as an error.
            ZStack {
                Circle()
                    .stroke(PulseColors.textMuted.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.02, progress?.fraction ?? 0))
                    .stroke(PulseColors.readiness.opacity(0.75),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let progress, progress.nightsCollected > 0 {
                    VStack(spacing: -2) {
                        Text("\(progress.nightsCollected)")
                            .font(PulseFont.numberL)
                            .monospacedDigit()
                            .foregroundStyle(PulseColors.textPrimary)
                        Text(progress.centerCaption)
                            .font(PulseFont.micro)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                } else {
                    Image(systemName: "bolt.heart")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(PulseColors.readiness.opacity(0.6))
                }
            }
            .frame(width: 82, height: 82)
            .padding(.leading, 15)

            VStack(alignment: .leading, spacing: 3) {
                Text(emptyTitle)
                    .font(PulseFont.callout.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Text(emptyDetail)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Prefers the readiness-specific night count over the generic pairing calibration: a user can
    /// be long past first-sync calibration and still be days away from a baseline, which is exactly
    /// the state the old copy described as a flat "No score yet".
    private var emptyTitle: String {
        if let progress { return progress.title }
        return calibration.isCalibrating ? "Learning your baseline" : "No score yet"
    }

    private var emptyDetail: String {
        if let progress { return progress.detail }
        return calibration.isCalibrating
            ? "Day \(calibration.day) of \(calibration.totalDays). Readiness needs about a week of nights before it can compare tonight to your normal."
            : "Wear your ring overnight to get a readiness score."
    }

    /// VoiceOver gets the number, the band, and the reasons — "93" alone is meaningless spoken.
    private var accessibilityLabel: String {
        guard let readiness else { return "Readiness. \(emptyTitle). \(emptyDetail)" }
        let why = reasons(readiness).map(\.detail).joined(separator: ". ")
        let coverage = readiness.coverage < 1
            ? " Based on \(Int((readiness.coverage * 100).rounded())) percent of signals."
            : ""
        return "Readiness \(readiness.score) out of 100, \(readiness.band.rawValue)."
            + coverage
            + (why.isEmpty ? " Every signal at or above your baseline." : " \(why).")
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
