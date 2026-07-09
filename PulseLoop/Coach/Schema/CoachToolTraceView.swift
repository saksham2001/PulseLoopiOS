import SwiftUI
import SwiftData

/// Per-message transparency disclosure: a muted collapsed summary of the tools a
/// turn ran ("Got HR data → Drew chart"), expanding to ordered rows with status
/// icons and one-line output summaries. Renders nothing when the message ran no
/// tools, so it can be dropped unconditionally after any assistant/error bubble.
struct CoachToolTraceDisclosure: View {
    @Query private var calls: [CoachToolCall]
    @State private var expanded = false

    init(messageId: UUID) {
        // Splitting the predicate and sort out of the Query(...) call keeps this
        // initializer's type-check cost low (the inline form is slow enough to
        // risk the compiler's expression budget on CI's slower runners).
        let predicate = #Predicate<CoachToolCall> { $0.messageId == messageId }
        let order: [SortDescriptor<CoachToolCall>] = [
            SortDescriptor(\.sequence, order: .forward),
            SortDescriptor(\.createdAt, order: .forward),
        ]
        _calls = Query(filter: predicate, sort: order)
    }

    /// Collapsed line: joins ≤2 friendly labels with " → ", else "Used N tools".
    private var collapsedText: String {
        let labels = calls.map(Self.displayLabel)
        if labels.count <= 2 { return labels.joined(separator: " → ") }
        return "Used \(labels.count) tools"
    }

    var body: some View {
        if calls.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(PulseFont.micro.weight(.regular))
                        Text(collapsedText)
                            .font(PulseFont.caption2.weight(.regular))
                            .lineLimit(1)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(PulseFont.nano)
                    }
                    .foregroundStyle(PulseColors.textMuted)
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calls) { call in
                            traceRow(call)
                        }
                    }
                }
            }
            .padding(.leading, 6)
        }
    }

    private func traceRow(_ call: CoachToolCall) -> some View {
        let isError = call.statusRaw == "error"
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "xmark.circle" : "checkmark.circle")
                .font(PulseFont.caption2.weight(.regular))
                .foregroundStyle(isError ? PulseColors.danger : PulseColors.success)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.displayLabel(call))
                    .font(PulseFont.caption2.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                if let summary = call.outputJSON, !summary.isEmpty {
                    Text(summary)
                        .font(PulseFont.micro.weight(.regular))
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Friendly label, falling back to a humanized `toolName` for legacy rows
    /// that predate the persisted `label` field.
    static func displayLabel(_ call: CoachToolCall) -> String {
        if !call.label.isEmpty { return call.label }
        return call.toolName.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
