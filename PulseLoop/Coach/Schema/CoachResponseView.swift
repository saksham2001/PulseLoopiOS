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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PulseColors.textPrimary)
            }

            if !response.summary.isEmpty {
                Text(coachMarkdown: response.summary)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(PulseColors.textPrimary)
            }

            if !response.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(response.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(PulseColors.accent)
                            Text(coachMarkdown: bullet).foregroundStyle(PulseColors.textSecondary)
                        }
                        .font(.system(size: 13))
                    }
                }
            }

            if let chart = response.chart {
                CoachChartView(chart: chart).padding(.top, 2)
            }

            if let safety = response.safetyNote, !safety.isEmpty {
                noteRow(icon: "exclamationmark.triangle.fill", text: safety, tone: PulseColors.warning)
            }

            if let dq = response.dataQualityNote, !dq.isEmpty {
                noteRow(icon: "info.circle", text: dq, tone: PulseColors.textMuted)
            }

            if !response.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SOURCES")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(PulseColors.textMuted)
                    ForEach(response.sources) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Text("\(source.title) — \(source.publisher)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(PulseColors.info)
                                    .underline()
                            }
                        } else {
                            Text("\(source.title) — \(source.publisher)")
                                .font(.system(size: 11))
                                .foregroundStyle(PulseColors.textMuted)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if !response.followUpChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(response.followUpChips, id: \.self) { chip in
                            Button { onChipTap?(chip) } label: {
                                Text(chip)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PulseColors.textSecondary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(PulseColors.cardSoft, in: Capsule())
                                    .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func noteRow(icon: String, text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tone)
            Text(coachMarkdown: text).font(.system(size: 12)).foregroundStyle(tone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
