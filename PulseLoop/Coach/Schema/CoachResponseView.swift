import SwiftUI

/// Renders a decoded `CoachResponse` as the assistant bubble's content:
/// title, summary, bullets, embedded chart, safety + data-quality notes,
/// sources, and tappable follow-up chips.
struct CoachResponseView: View {
    let response: CoachResponse
    var onChipTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !response.title.isEmpty {
                Text(coachMarkdown: response.title)
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
            }

            if !response.summary.isEmpty {
                Text(coachMarkdown: response.summary)
                    .font(PulseFont.subheadline.weight(.regular))
                    .lineSpacing(4)
                    .foregroundStyle(PulseColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bulletsSection

            if let chart = response.chart {
                CoachChartView(chart: chart).padding(.top, 2)
            }

            if let safety = response.safetyNote, !safety.isEmpty {
                noteRow(icon: "exclamationmark.triangle.fill", text: safety, tone: PulseColors.warning)
            }

            if let dq = response.dataQualityNote, !dq.isEmpty {
                noteRow(icon: "info.circle", text: dq, tone: PulseColors.textMuted)
            }

            sourcesSection
            chipsSection
        }
    }

    @ViewBuilder
    private var bulletsSection: some View {
        if !response.bullets.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(response.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(PulseColors.accent)
                        Text(coachMarkdown: bullet).foregroundStyle(PulseColors.textSecondary)
                    }
                    .font(PulseFont.footnote.weight(.regular))
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        if !response.sources.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("SOURCES")
                    .font(PulseFont.nano).tracking(1.2)
                    .foregroundStyle(PulseColors.textMuted)
                ForEach(response.sources) { source in
                    sourceLink(source)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func sourceLink(_ source: CoachSource) -> some View {
        if let url = URL(string: source.url) {
            Link(destination: url) {
                Text("\(source.title) — \(source.publisher)")
                    .font(PulseFont.caption2.weight(.regular))
                    .foregroundStyle(PulseColors.info)
                    .underline()
            }
        } else {
            Text("\(source.title) — \(source.publisher)")
                .font(PulseFont.caption2.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
        }
    }

    @ViewBuilder
    private var chipsSection: some View {
        if !response.followUpChips.isEmpty {
            // Full-width tappable rows (≤2). Wider than the old capsules so a
            // real follow-up question reads without truncation. `.prefix(2)`
            // clamps legacy messages and non-strict providers at render time.
            VStack(spacing: 6) {
                ForEach(Array(response.followUpChips.prefix(2)), id: \.self) { chip in
                    Button { onChipTap?(chip) } label: {
                        CoachFollowUpChipLabel(text: chip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }

    private func noteRow(icon: String, text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(PulseFont.caption2.weight(.regular)).foregroundStyle(tone)
            Text(coachMarkdown: text).font(PulseFont.caption.weight(.regular)).foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Full-width follow-up chip row: wraps up to two lines of question text with a
/// trailing arrow glyph. Shared by the chat response view and the Today/Sleep
/// summary cards so both render the same wider treatment.
struct CoachFollowUpChipLabel: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(PulseFont.footnote.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(PulseFont.micro.weight(.semibold))
                .foregroundStyle(PulseColors.textMuted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        // Solid tile, not glass: this chip renders inside the assistant bubble's glass,
        // and glass can't sample glass (renders flat). A soft card fill + hairline keeps
        // the chip visible as a tappable affordance.
        .background(PulseColors.cardSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

extension Text {
    /// Renders inline Markdown (**bold**, *italic*, `code`, links) so model
    /// output like "**HR**" displays formatted instead of raw. Falls back to the
    /// literal string if parsing fails. `inlineOnlyPreservingWhitespace` keeps
    /// line breaks intact for multi-line summaries/bullets.
    init(coachMarkdown string: String) {
        if let attributed = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            self.init(attributed)
        } else {
            self.init(verbatim: string)
        }
    }
}
