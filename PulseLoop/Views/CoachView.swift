import SwiftUI
import SwiftData
import UIKit
import PhotosUI

private let coldStartPrompts = [
    "How am I doing today?",
    "Explain my heart rate trend",
    "Summarize my week",
    "Should I work out?",
    "What data is missing?"
]

struct CoachView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query(sort: \CoachMessage.createdAt) private var allMessages: [CoachMessage]
    @Query(sort: \CoachConversation.updatedAt, order: .reverse) private var conversations: [CoachConversation]
    @State private var draft = ""
    @State private var viewModel = CoachViewModel()
    @State private var activeConversationId: UUID?
    @State private var showHistory = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var nav = CoachNavigation.shared
    @State private var settingsStore = CoachSettingsStore.shared
    @FocusState private var composerFocused: Bool

    // Image attachment (multimodal input). One staged image per message.
    @State private var stagedImage: UIImage?
    @State private var stagedAttachment: CoachAttachmentRef?
    @State private var showPhotosPicker = false
    @State private var showCamera = false
    @State private var photosPickerItem: PhotosPickerItem?

    private var imageInputEnabled: Bool { settingsStore.settings.enableImageInput }

    /// Bottom inset for the composer: clears the overlaid nav bar (~60) when the
    /// keyboard is hidden, and sits just above the keyboard when shown. Computed
    /// manually because the tab layout pins the keyboard safe area (see RootViews).
    private var composerBottomInset: CGFloat {
        guard keyboardHeight > 0 else { return 60 }
        return max(8, keyboardHeight - bottomSafeInset + 8)
    }

    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
    }

    /// Messages for the currently selected conversation.
    private var messages: [CoachMessage] {
        guard let id = activeConversationId else { return allMessages }
        return allMessages.filter { $0.conversationId == id }
    }

    private var showColdStart: Bool {
        !viewModel.isSending && (messages.isEmpty || messages.last?.role == "assistant")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(messages) { message in
                            CoachBubble(
                                message: message,
                                onChipTap: { send($0) },
                                onConfirm: { viewModel.confirmPendingAction(message, context: modelContext) },
                                onCancel: { viewModel.cancelPendingAction(message, context: modelContext) }
                            ).id(message.id)
                        }
                        if viewModel.isSending {
                            CoachTraceStrip(events: viewModel.traceEvents).id("trace")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: viewModel.traceEvents.count) {
                    withAnimation { proxy.scrollTo("trace", anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
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
            // Clears the nav bar when idle; rises above the keyboard when typing.
            .padding(.bottom, composerBottomInset)
            .background(PulseColors.secondaryBackground)
        }
        .background(PulseColors.background)
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            // Visible keyboard height = how far its top is above the screen bottom.
            keyboardHeight = max(0, screenHeight - frame.origin.y)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onAppear {
            if activeConversationId == nil {
                activeConversationId = allMessages.last?.conversationId ?? conversations.first?.id
            }
            if nav.requestedConversationId != nil { openRequestedConversation() }
        }
        .onChange(of: nav.requestedConversationId) { _, id in
            if id != nil { openRequestedConversation() }
        }
        .sheet(isPresented: $showHistory) {
            CoachHistorySheet(conversations: conversations, activeId: activeConversationId) { id in
                activeConversationId = id
            }
        }
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
            Button { composerFocused = false; showHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16)).foregroundStyle(PulseColors.textSecondary)
                    .frame(width: 36, height: 36).overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PulseColors.secondaryBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(PulseColors.borderSubtle).frame(height: 1) }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let stagedImage { stagedThumbnail(stagedImage) }

            HStack(spacing: 8) {
                // Camera button — only shown when image input is enabled in
                // Settings. Nothing is shown when off. Opens the camera directly;
                // falls back to the photo library where no camera exists (simulator).
                if imageInputEnabled {
                    Button {
                        composerFocused = false
                        if UIImagePickerController.cameraAvailable { showCamera = true }
                        else { showPhotosPicker = true }
                    } label: {
                        Image(systemName: "camera")
                            .font(.system(size: 17)).foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 36, height: 36).background(PulseColors.card, in: Circle())
                            .overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
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
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, item in
            guard let item else { return }
            Task { await loadPickedPhoto(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in stage(image) }
                .ignoresSafeArea()
        }
    }

    /// Small preview chip for the staged image, with a remove button.
    private func stagedThumbnail(_ image: UIImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
                Button { clearStagedImage() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            Spacer(minLength: 0)
        }
    }

    private var canSend: Bool {
        guard !viewModel.isSending else { return false }
        return !draft.trimmingCharacters(in: .whitespaces).isEmpty || stagedAttachment != nil
    }

    /// Compresses + persists the picked image and stages it for the next send.
    private func stage(_ image: UIImage) {
        guard let ref = CoachAttachmentStore.save(image) else { return }
        stagedImage = image
        stagedAttachment = ref
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            stage(image)
        }
        photosPickerItem = nil
    }

    /// Removes the staged image and deletes its on-disk file (it was never sent).
    private func clearStagedImage() {
        if let ref = stagedAttachment { CoachAttachmentStore.delete(ref) }
        stagedImage = nil
        stagedAttachment = nil
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = stagedAttachment
        // Allow image-only sends: require either text or a staged image.
        guard !(trimmed.isEmpty && attachment == nil), !viewModel.isSending else { return }
        let conversationId = resolveConversationId()
        // Title a fresh conversation from its opening message.
        if let convo = conversations.first(where: { $0.id == conversationId }),
           isDefaultTitle(convo.title),
           !allMessages.contains(where: { $0.conversationId == conversationId }) {
            let seed = trimmed.isEmpty ? "Photo" : String(trimmed.prefix(40))
            convo.title = seed
            try? modelContext.save()
        }
        draft = ""
        stagedImage = nil
        stagedAttachment = nil
        composerFocused = false
        let attachments = attachment.map { [$0] } ?? []
        Task { await viewModel.send(trimmed, conversationId: conversationId, context: modelContext, attachments: attachments, coordinator: coordinator) }
    }

    /// The active conversation, creating one on first use.
    private func resolveConversationId() -> UUID {
        if let id = activeConversationId { return id }
        if let existing = conversations.first {
            activeConversationId = existing.id
            return existing.id
        }
        let conversation = CoachConversation(title: "New chat")
        modelContext.insert(conversation)
        try? modelContext.save()
        activeConversationId = conversation.id
        return conversation.id
    }

    private func isDefaultTitle(_ title: String) -> Bool {
        title == "New chat" || title == "Today check-in"
    }

    /// Open a specific conversation requested via deep-link (notification tap or
    /// a Today/Sleep summary-card tap).
    private func openRequestedConversation() {
        if let id = nav.requestedConversationId {
            activeConversationId = id
        }
        nav.requestedConversationId = nil
    }

    private func newConversation() {
        composerFocused = false
        let conversation = CoachConversation(title: "New chat")
        modelContext.insert(conversation)
        try? modelContext.save()
        activeConversationId = conversation.id
    }
}

/// Conversation history sheet — pick a past conversation to resume.
struct CoachHistorySheet: View {
    let conversations: [CoachConversation]
    let activeId: UUID?
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    Text("No conversations yet.")
                        .font(.system(size: 14)).foregroundStyle(PulseColors.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(conversations) { convo in
                            Button { onSelect(convo.id); dismiss() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(convo.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(PulseColors.textPrimary)
                                        Text(Self.dateFormatter.string(from: convo.updatedAt))
                                            .font(.system(size: 11))
                                            .foregroundStyle(PulseColors.textMuted)
                                    }
                                    Spacer()
                                    if convo.id == activeId {
                                        Image(systemName: "checkmark").foregroundStyle(PulseColors.accent)
                                    }
                                }
                            }
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
        }
    }
}

extension UIApplication {
    /// Resigns the first responder app-wide (used to dismiss the keyboard on
    /// tab changes, where no single FocusState is in scope).
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
    var onChipTap: ((String) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private var structured: CoachResponse? {
        message.role == "assistant" ? CoachResponse.decode(fromJSON: message.cardsJSON) : nil
    }

    private var pendingAction: PendingAction? {
        message.role == "assistant" ? PendingAction.decode(fromJSON: message.pendingActionJSON) : nil
    }

    private var turnError: CoachTurnError? {
        message.role == "error" ? CoachTurnError.decode(fromJSON: message.cardsJSON) : nil
    }

    private var attachments: [CoachAttachmentRef] {
        CoachAttachmentRef.decode(fromJSON: message.attachmentsJSON)
    }

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
                ForEach(attachments, id: \.file) { ref in attachmentImage(ref) }
                content
                if let pendingAction {
                    CoachActionCardView(
                        action: pendingAction,
                        onConfirm: { onConfirm?() },
                        onCancel: { onCancel?() }
                    )
                }
            }
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var content: some View {
        if let turnError {
            CoachErrorBubble(error: turnError)
        } else if let structured {
            CoachResponseView(response: structured, onChipTap: onChipTap)
                .padding(14)
                .background(PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        } else if message.role == "user" && message.body.isEmpty && !attachments.isEmpty {
            // Image-only message: the image is the bubble, no empty text bubble below.
            EmptyView()
        } else {
            (message.role == "user" ? Text(message.body) : Text(coachMarkdown: message.body))
                .font(.system(size: 14))
                .foregroundStyle(message.role == "user" ? .white : PulseColors.textPrimary)
                .padding(14)
                .background(message.role == "user" ? PulseColors.accent : PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(message.role == "user" ? Color.clear : PulseColors.borderSubtle, lineWidth: 1)
                )
        }
    }

    /// Renders an attached image (loaded from `CoachAttachmentStore`) as part of
    /// the message bubble. Falls back to a placeholder if the file is missing.
    @ViewBuilder private func attachmentImage(_ ref: CoachAttachmentRef) -> some View {
        if let image = CoachAttachmentStore.loadImage(ref) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(maxWidth: 240, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PulseColors.card)
                .frame(width: 120, height: 90)
                .overlay(Image(systemName: "photo").foregroundStyle(PulseColors.textMuted))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }
}

/// Red-bordered error bubble shown when a coach turn fails. Displays the error
/// code (e.g. "HTTP 401") and the full reason so failures are explicit in chat,
/// across all providers. Matches the chat design system (card background, 18pt
/// radius, 14pt padding) with a `PulseColors.danger` accent.
struct CoachErrorBubble: View {
    let error: CoachTurnError

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Coach error")
                    .font(.system(size: 13, weight: .semibold))
                Text("·").foregroundStyle(PulseColors.textMuted)
                Text(error.code)
                    .font(.system(size: 12, weight: .semibold).monospaced())
            }
            .foregroundStyle(PulseColors.danger)

            Text(error.reason)
                .font(.system(size: 14))
                .foregroundStyle(PulseColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(PulseColors.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PulseColors.danger, lineWidth: 1.5)
        )
    }
}

/// Live progress strip shown while a turn runs (in-process trace).
struct CoachTraceStrip: View {
    let events: [CoachTraceEvent]

    private var label: String {
        events.last(where: { $0.status != .done })?.label ?? "Thinking…"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(PulseColors.accent)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(PulseColors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseColors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}
