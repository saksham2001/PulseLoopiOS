import SwiftUI

/// The day's movement score plus this week's training-load balance, as one compact card.
///
/// Lives on the **Activity** tab rather than Today: Today is already a dense tile grid, and a score
/// that summarises the rest of that tab belongs beside what it summarises. The contributor
/// breakdown is disclosed on tap rather than shown by default, so the card stays one line tall
/// until asked.
struct ActivityScoreCard: View {
    let result: ActivityScoreResult
    let balance: TrainingLoad.Balance

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(alignment: .center, spacing: 14) {
                    scoreDial
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MOVEMENT")
                            .font(PulseFont.caption2.weight(.semibold)).tracking(1.0)
                            .foregroundStyle(PulseColors.textMuted)
                        Text(result.band.rawValue)
                            .font(PulseFont.headline)
                            .foregroundStyle(PulseColors.textPrimary)
                        Text(loadLine)
                            .font(PulseFont.caption)
                            .foregroundStyle(PulseColors.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(PulseFont.footnote.weight(.semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Movement score \(result.score) out of 100, \(result.band.rawValue). \(loadLine)")
            .accessibilityHint(expanded ? "Hides the breakdown" : "Shows what made up the score")

            if expanded {
                VStack(spacing: 8) {
                    ForEach(result.contributors, id: \.kind) { contributor in
                        contributorRow(contributor)
                    }
                    if result.coverage < 1 {
                        Text(coverageNote)
                            .font(PulseFont.caption.weight(.regular))
                            .foregroundStyle(PulseColors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var scoreDial: some View {
        ZStack {
            Circle()
                .stroke(PulseColors.cardSoft, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.02, Double(result.score) / 100))
                .stroke(PulseColors.steps, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(result.score)")
                .font(PulseFont.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
        }
        .frame(width: 58, height: 58)
    }

    private func contributorRow(_ contributor: ActivityContributor) -> some View {
        let fraction = contributor.maxPoints > 0 ? contributor.earned / contributor.maxPoints : 0
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contributor.kind.title)
                    .font(PulseFont.caption.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Text(contributor.detail)
                    .font(PulseFont.caption2)
                    .foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PulseColors.cardSoft)
                    Capsule().fill(PulseColors.steps)
                        .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                }
            }
            .frame(width: 70, height: 6)

            Text("\(Int(contributor.earned.rounded()))/\(Int(contributor.maxPoints))")
                .font(PulseFont.caption2.monospacedDigit())
                .foregroundStyle(PulseColors.textSecondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// One sentence on this week's load. Says what it can't say when history is thin, rather than
    /// showing a ratio built on a fortnight and calling it a baseline.
    private var loadLine: String {
        guard balance.ratio != nil else { return balance.band.detail }
        return "Training load · \(balance.band.rawValue.lowercased())"
    }

    private var coverageNote: String {
        "Scored out of \(Int((result.coverage * 100).rounded())) — your ring didn't report everything "
            + "this score can use, so the missing parts were left out rather than counted against you."
    }
}
