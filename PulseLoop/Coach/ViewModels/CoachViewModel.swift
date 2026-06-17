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
    private let settingsStore: CoachSettingsStore
    private let clientFactory: (String) -> ResponsesClient

    init(
        keyStore: APIKeyStore = OpenAIKeychainStore(),
        geminiKeyStore: APIKeyStore = GeminiKeychainStore(),
        settingsStore: CoachSettingsStore = .shared,
        clientFactory: @escaping (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) {
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory
    }

    func send(
        _ text: String,
        conversationId: UUID,
        context: ModelContext,
        coordinator: RingSyncCoordinator? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        traceEvents = []
        errorBanner = nil
        defer { isSending = false }

        // Optimistically persist the user message so the UI shows it immediately.
        let userMessage = CoachMessage(conversationId: conversationId, role: "user", body: trimmed)
        context.insert(userMessage)
        try? context.save()

        let (apiKey, activeClient) = resolveClient()
        let flags = CoachFeatureFlags(settings: settingsStore.settings, hasAPIKey: apiKey != nil)
        let packet = CoachContextBuilder.build(context: context)
        let recent = recentMessages(conversationId: conversationId, excluding: userMessage.id, context: context)

        let orchestrator = CoachOrchestrator(
            client: activeClient,
            registry: ToolRegistry(flags: flags),
            flags: flags,
            toolContext: ToolExecutionContext(modelContext: context, flags: flags, coordinator: coordinator)
        )

        let result = await orchestrator.runTurn(
            userText: trimmed,
            packet: packet,
            recentMessages: recent
        ) { [weak self] event in
            self?.traceEvents.append(event)
        }

        persist(result, conversationId: conversationId, context: context)
    }

    // MARK: - Provider resolution

    private func resolveClient() -> (key: String?, client: ResponsesClient) {
        switch settingsStore.settings.providerMode {
        case .userGeminiKey:
            let key = (try? geminiKeyStore.readKey()) ?? nil
            return (key, GeminiClient(apiKey: key ?? ""))
        default:
            let key = (try? keyStore.readKey()) ?? nil
            return (key, clientFactory(key ?? ""))
        }
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
        let assistant = CoachMessage(
            conversationId: conversationId,
            role: "assistant",
            body: result.assistant.plainText,
            cardsJSON: result.assistant.encodedJSON(),
            pendingActionJSON: result.pendingActions.first?.encodedJSON()
        )
        context.insert(assistant)

        for entry in result.trace {
            context.insert(CoachToolCall(
                conversationId: conversationId,
                messageId: assistant.id,
                toolName: entry.toolName,
                inputJSON: entry.argsRedacted,
                outputJSON: entry.resultSummary
            ))
        }

        if let convo = fetchConversation(conversationId, context: context) {
            convo.updatedAt = Date()
        }
        try? context.save()
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
        return rows
            .filter { $0.id != excludedId }
            .suffix(limit)
            .map { CoachOrchestrator.PriorMessage(role: $0.role, text: $0.body) }
    }

    private func fetchConversation(_ id: UUID, context: ModelContext) -> CoachConversation? {
        let descriptor = FetchDescriptor<CoachConversation>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }
}
