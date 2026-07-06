import Foundation
import SwiftData

/// Owns one coach turn end-to-end: persist the user message, build flags +
/// context, run the orchestrator off the SwiftData reads it needs, persist the
/// assistant message (+ tool-call trace), and surface live progress. The iOS
/// analogue of the web `coach_service.send_message`.
@MainActor
@Observable
final class CoachViewModel {
    var traceEvents: [CoachTraceEvent] = []
    var isSending = false
    var errorBanner: String?

    private let keyStore: APIKeyStore
    private let geminiKeyStore: APIKeyStore
    private let openRouterKeyStore: APIKeyStore
    private let minimaxKeyStore: APIKeyStore
    private let settingsStore: CoachSettingsStore
    private let clientFactory: (String) -> ResponsesClient

    init(
        keyStore: APIKeyStore = OpenAIKeychainStore(),
        geminiKeyStore: APIKeyStore = GeminiKeychainStore(),
        openRouterKeyStore: APIKeyStore = OpenRouterKeychainStore(),
        minimaxKeyStore: APIKeyStore = MiniMaxKeychainStore(),
        settingsStore: CoachSettingsStore = .shared,
        clientFactory: @escaping (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) {
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.openRouterKeyStore = openRouterKeyStore
        self.minimaxKeyStore = minimaxKeyStore
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory
    }

    func send(
        _ text: String,
        conversationId: UUID,
        context: ModelContext,
        attachments: [CoachAttachmentRef] = [],
        coordinator: RingSyncCoordinator? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow image-only sends: require either text or an attachment.
        guard !(trimmed.isEmpty && attachments.isEmpty), !isSending else { return }
        isSending = true
        traceEvents = []
        errorBanner = nil
        defer { isSending = false }

        // Optimistically persist the user message so the UI shows it immediately.
        let userMessage = CoachMessage(
            conversationId: conversationId, role: "user", body: trimmed,
            attachmentsJSON: CoachAttachmentRef.encode(attachments))
        context.insert(userMessage)
        try? context.save()

        let (apiKey, activeClient) = resolveClient()
        let flags = CoachFeatureFlags(settings: settingsStore.settings, hasAPIKey: apiKey != nil)
        let packet = CoachContextBuilder.build(context: context)
        let recent = recentMessages(conversationId: conversationId, excluding: userMessage.id, context: context)
        let userImages = CoachAttachmentStore.payloads(for: attachments)

        let orchestrator = CoachOrchestrator(
            client: activeClient,
            registry: ToolRegistry(flags: flags),
            flags: flags,
            toolContext: ToolExecutionContext(modelContext: context, flags: flags, coordinator: coordinator)
        )

        let result = await orchestrator.runTurn(
            userText: trimmed,
            packet: packet,
            recentMessages: recent,
            userImages: userImages
        ) { [weak self] event in
            self?.traceEvents.append(event)
        }

        persist(result, conversationId: conversationId, context: context)
    }

    // MARK: - Provider resolution

    private func resolveClient() -> (key: String?, client: ResponsesClient) {
        CoachClientResolver.resolve(
            settings: settingsStore.settings,
            openAIKeyStore: keyStore,
            geminiKeyStore: geminiKeyStore,
            openRouterKeyStore: openRouterKeyStore,
            minimaxKeyStore: minimaxKeyStore,
            openAIClientFactory: clientFactory
        )
    }

    // MARK: - Confirmation cards

    /// Execute a proposed risky action after the user taps Confirm.
    func confirmPendingAction(_ message: CoachMessage, context: ModelContext) {
        guard let action = PendingAction.decode(fromJSON: message.pendingActionJSON) else { return }
        let resultText = PendingActionExecutor.execute(action, context: context)
        message.pendingActionJSON = nil
        context.insert(CoachMessage(conversationId: message.conversationId, role: "assistant", body: resultText))
        try? context.save()
    }

    /// Dismiss a proposed action after the user taps Cancel.
    func cancelPendingAction(_ message: CoachMessage, context: ModelContext) {
        message.pendingActionJSON = nil
        context.insert(CoachMessage(conversationId: message.conversationId, role: "assistant", body: "Okay, I won't make that change."))
        try? context.save()
    }

    // MARK: - Persistence

    private func persist(_ result: CoachOrchestrator.TurnResult, conversationId: UUID, context: ModelContext) {
        // A failed turn surfaces as a red error bubble (role "error") carrying the
        // code + reason, instead of the generic assistant fallback.
        if let error = result.error {
            let errorMessage = CoachMessage(
                conversationId: conversationId,
                role: "error",
                body: error.plainText,
                cardsJSON: error.encodedJSON()
            )
            context.insert(errorMessage)
            persistTrace(result.trace, messageId: errorMessage.id, conversationId: conversationId, context: context)
            touchConversation(conversationId, context: context)
            try? context.save()
            return
        }

        let assistant = CoachMessage(
            conversationId: conversationId,
            role: "assistant",
            body: result.assistant.plainText,
            cardsJSON: result.assistant.encodedJSON(),
            pendingActionJSON: result.pendingActions.first?.encodedJSON()
        )
        context.insert(assistant)

        persistTrace(result.trace, messageId: assistant.id, conversationId: conversationId, context: context)
        touchConversation(conversationId, context: context)
        try? context.save()
    }

    private func persistTrace(
        _ trace: [CoachToolCallTrace], messageId: UUID, conversationId: UUID, context: ModelContext
    ) {
        for entry in trace {
            context.insert(CoachToolCall(
                conversationId: conversationId,
                messageId: messageId,
                toolName: entry.toolName,
                inputJSON: entry.argsRedacted,
                outputJSON: entry.resultSummary
            ))
        }
    }

    private func touchConversation(_ conversationId: UUID, context: ModelContext) {
        if let convo = fetchConversation(conversationId, context: context) {
            convo.updatedAt = Date()
        }
    }

    private func recentMessages(
        conversationId: UUID, excluding excludedId: UUID, context: ModelContext, limit: Int = 10
    ) -> [CoachOrchestrator.PriorMessage] {
        var descriptor = FetchDescriptor<CoachMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 40
        let rows = (try? context.fetch(descriptor)) ?? []
        let recent = rows
            .filter { $0.id != excludedId && $0.role != "error" }  // never replay error bubbles to the model
            .suffix(limit)
        // Replay images only on the most recent prior user turn that has them, to
        // keep context coherent without ballooning the payload with old base64.
        let lastImageRowId = recent.last { CoachAttachmentRef.decode(fromJSON: $0.attachmentsJSON).isEmpty == false }?.id
        return recent.map { row in
            let images = row.id == lastImageRowId
                ? CoachAttachmentStore.payloads(for: CoachAttachmentRef.decode(fromJSON: row.attachmentsJSON))
                : []
            return CoachOrchestrator.PriorMessage(role: row.role, text: row.body, images: images)
        }
    }

    private func fetchConversation(_ id: UUID, context: ModelContext) -> CoachConversation? {
        let descriptor = FetchDescriptor<CoachConversation>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }
}
