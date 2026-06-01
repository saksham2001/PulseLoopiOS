import SwiftUI
import SwiftData

private let coldStartPrompts = [
    "How am I doing today?",
    "Explain my heart rate trend",
    "Summarize my week",
    "Should I work out?",
    "What data is missing?"
]

private let offlineReply = "Coach is offline right now — live insights arrive in a later phase. For now, explore your latest data in the Today, Vitals, Activity, and Sleep tabs."

struct CoachView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CoachMessage.createdAt) private var messages: [CoachMessage]
    @Query private var conversations: [CoachConversation]
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var showColdStart: Bool {
        messages.isEmpty || messages.last?.role == "assistant"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(messages) { message in
                            CoachBubble(message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            VStack(spacing: 0) {
                if showColdStart {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(coldStartPrompts, id: \.self) { prompt in
                                Button { send(prompt) } label: {
                                    Text(prompt)
                                        .font(.system(size: 12))
                                        .foregroundStyle(PulseColors.textSecondary)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(PulseColors.card, in: Capsule())
                                        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                composer
            }
            .background(PulseColors.secondaryBackground)
        }
        .background(PulseColors.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CoachOrb(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("PulseLoop Coach").font(.system(size: 14, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                Text("Using your latest ring sync").font(.system(size: 11)).foregroundStyle(PulseColors.textMuted)
            }
            Spacer()
            Button { newConversation() } label: {
                Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(PulseColors.textSecondary)
                    .frame(width: 36, height: 36).overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
            Button {} label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16)).foregroundStyle(PulseColors.textSecondary)
                    .frame(width: 36, height: 36).overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PulseColors.secondaryBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(PulseColors.borderSubtle).frame(height: 1) }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 18)).foregroundStyle(PulseColors.textMuted)
                .frame(width: 36, height: 36).background(PulseColors.card, in: Circle()).opacity(0.6)
            TextField("Ask the coach...", text: $draft)
                .focused($composerFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(PulseColors.card, in: Capsule())
                .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canSend ? .white : PulseColors.textMuted)
                    .frame(width: 36, height: 36)
                    .background(canSend ? PulseColors.accent : PulseColors.card, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let conversationId = activeConversationId()
        let now = Date()
        modelContext.insert(CoachMessage(conversationId: conversationId, role: "user", body: trimmed, createdAt: now))
        modelContext.insert(CoachMessage(conversationId: conversationId, role: "assistant", body: offlineReply, createdAt: now.addingTimeInterval(0.1)))
        try? modelContext.save()
        draft = ""
    }

    private func activeConversationId() -> UUID {
        if let existing = conversations.first { return existing.id }
        let conversation = CoachConversation()
        modelContext.insert(conversation)
        return conversation.id
    }

    private func newConversation() {
        let conversation = CoachConversation(title: "New chat")
        modelContext.insert(conversation)
        // Clear visible messages for a fresh start.
        for message in messages { modelContext.delete(message) }
        try? modelContext.save()
    }
}

struct CoachOrb: View {
    var size: CGFloat = 40
    @State private var animate = false
    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [PulseColors.accent, PulseColors.spo2, PulseColors.sleep, PulseColors.accent],
                    center: .center
                )
            )
            .frame(width: size, height: size)
            .overlay(Circle().fill(PulseColors.background.opacity(0.25)))
            .overlay(
                Circle().fill(.white.opacity(0.9)).frame(width: size * 0.22, height: size * 0.22)
                    .offset(x: -size * 0.12, y: -size * 0.12)
            )
            .shadow(color: PulseColors.accent.opacity(0.5), radius: animate ? 10 : 4)
            .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true } }
    }
}

struct CoachBubble: View {
    let message: CoachMessage
    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            Text(message.body)
                .font(.system(size: 14))
                .foregroundStyle(message.role == "user" ? .white : PulseColors.textPrimary)
                .padding(14)
                .background(message.role == "user" ? PulseColors.accent : PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(message.role == "user" ? Color.clear : PulseColors.borderSubtle, lineWidth: 1)
                )
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
