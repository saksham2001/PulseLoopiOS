import SwiftUI

/// Past conversations: tap one to resume it, swipe one to delete it, or delete
/// them all. Every delete asks first — it takes the messages, the tool-call trace
/// and any attached photos with it, and there's no undo.
struct CoachHistorySheet: View {
    let conversations: [CoachConversationSummary]
    let activeId: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onDeleteAll: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: CoachConversationSummary?
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    Text("No conversations yet. Ask the coach something and it will show up here.")
                        .font(PulseFont.subheadline.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(conversations) { convo in
                                row(convo)
                                    .listRowBackground(PulseColors.card)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        // Not `role: .destructive`: that removes the row before the
                                        // dialog answers, so a cancel would leave it looking deleted.
                                        Button { pendingDelete = convo } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(PulseColors.danger)
                                    }
                            }
                        } footer: {
                            Text("Swipe a conversation to delete it.")
                        }
                        Section {
                            Button("Delete all conversations", role: .destructive) { confirmDeleteAll = true }
                                .frame(maxWidth: .infinity)
                                .listRowBackground(PulseColors.card)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(PulseColors.background)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .alert(
                "Delete this conversation?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { convo in
                Button("Delete", role: .destructive) { onDelete(convo.id); pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { convo in
                Text("“\(convo.title)” and its replies will be deleted. This can't be undone.")
            }
            .alert("Delete all conversations?", isPresented: $confirmDeleteAll) {
                Button("Delete all", role: .destructive) { onDeleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(conversations.count == 1
                     ? "Your conversation and its replies will be deleted. This can't be undone."
                     : "All \(conversations.count) conversations and their replies will be deleted. This can't be undone.")
            }
        }
    }

    private func row(_ convo: CoachConversationSummary) -> some View {
        Button { onSelect(convo.id); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(convo.title)
                        .font(PulseFont.callout)
                        .foregroundStyle(PulseColors.textPrimary)
                        .lineLimit(2)
                    Text(CoachHistoryText.subtitle(convo))
                        .font(PulseFont.caption2.weight(.regular))
                        .foregroundStyle(PulseColors.textMuted)
                }
                Spacer()
                if convo.id == activeId {
                    Image(systemName: "checkmark").foregroundStyle(PulseColors.accent)
                        .accessibilityLabel("Open now")
                }
            }
        }
    }
}
