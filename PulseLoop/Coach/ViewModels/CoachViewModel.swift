import Foundation
import SwiftData

/// Owns one coach turn end-to-end: persist the user message, build flags +
/// context, run the orchestrator off the SwiftData reads it needs, persist the
/// assistant message (+ tool-call trace), and surface live progress. The iOS
/// analogue of the web `coach_service.send_message`.
@MainActor
@Observable
final class CoachViewModel {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

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
        let budget = flags.contextBudget
        let environment = await CoachEnvironmentContextService.shared.snapshot()
        let packet = CoachContextBuilder.build(context: context, budget: budget, environment: environment)
        let recent = recentMessages(
            conversationId: conversationId, excluding: userMessage.id, context: context, limit: budget.historyTurns)
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

        persist(result, conversationId: conversationId, context: context, flags: flags)
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
        // A confirmed edit still touches a real workout — surface its card. Deletes
        // have nothing left to show, so skip them.
        let loggedIds: String? = action.kind == .updateActivitySession
            ? UUID(uuidString: action.activityId).map { Self.encodeActivityIds([$0]) } ?? nil
            : nil
        context.insert(CoachMessage(
            conversationId: message.conversationId, role: "assistant", body: resultText,
            loggedActivityIdsJSON: loggedIds))
        try? context.save()
    }

    /// Dismiss a proposed action after the user taps Cancel.
    func cancelPendingAction(_ message: CoachMessage, context: ModelContext) {
        message.pendingActionJSON = nil
        context.insert(CoachMessage(conversationId: message.conversationId, role: "assistant", body: "Okay, I won't make that change."))
        try? context.save()
    }

    // MARK: - Persistence

    private func persist(_ result: CoachOrchestrator.TurnResult, conversationId: UUID, context: ModelContext, flags: CoachFeatureFlags) {
        // A failed turn surfaces as a red error bubble (role "error") carrying the
        // code + reason, instead of the generic assistant fallback. Failed turns
        // still burned tokens, so usage rides on the error message too.
        if let error = result.error {
            let errorMessage = CoachMessage(
                conversationId: conversationId,
                role: "error",
                body: error.plainText,
                cardsJSON: error.encodedJSON()
            )
            applyUsage(result.usage, to: errorMessage, flags: flags)
            context.insert(errorMessage)
            persistTrace(result.trace, messageId: errorMessage.id, conversationId: conversationId, context: context)
            touchConversation(conversationId, context: context, usage: result.usage, cost: errorMessage.costUSD)
            try? context.save()
            return
        }

        let assistant = CoachMessage(
            conversationId: conversationId,
            role: "assistant",
            body: result.assistant.plainText,
            cardsJSON: result.assistant.encodedJSON(),
            pendingActionJSON: result.pendingActions.first?.encodedJSON(),
            loggedActivityIdsJSON: Self.encodeActivityIds(result.loggedActivityIds)
        )
        applyUsage(result.usage, to: assistant, flags: flags)
        context.insert(assistant)

        persistTrace(result.trace, messageId: assistant.id, conversationId: conversationId, context: context)
        touchConversation(conversationId, context: context, usage: result.usage, cost: assistant.costUSD)
        try? context.save()
    }

    /// Stamps a turn's token/cost accounting onto the message. Cost prefers the
    /// provider-reported figure (OpenRouter), else the catalog estimate; `nil` when
    /// the model is unknown or on-device (the UI shows "cost unavailable").
    private func applyUsage(_ usage: CoachTokenUsage?, to message: CoachMessage, flags: CoachFeatureFlags) {
        message.modelUsed = flags.effectiveModel
        message.providerUsed = flags.settings.providerMode.rawValue
        guard let usage else { return }
        message.inputTokens = usage.inputTokens
        message.outputTokens = usage.outputTokens
        message.costUSD = usage.reportedCostUSD ?? CoachPricingCatalog.cost(model: flags.effectiveModel, usage: usage)
    }

    /// Internal (not private) so unit tests can assert label/status/sequence are
    /// persisted rather than dropped.
    func persistTrace(
        _ trace: [CoachToolCallTrace], messageId: UUID, conversationId: UUID, context: ModelContext
    ) {
        for (index, entry) in trace.enumerated() {
            context.insert(CoachToolCall(
                conversationId: conversationId,
                messageId: messageId,
                toolName: entry.toolName,
                inputJSON: entry.argsRedacted,
                outputJSON: entry.resultSummary,
                label: entry.label,
                statusRaw: entry.status,
                sequence: index
            ))
        }
    }

    /// Encodes activity ids logged/edited during a turn onto a message. Returns
    /// nil for the common empty case to keep migrations light.
    static func encodeActivityIds(_ ids: [UUID]) -> String? {
        guard !ids.isEmpty else { return nil }
        return (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func touchConversation(
        _ conversationId: UUID, context: ModelContext, usage: CoachTokenUsage? = nil, cost: Double? = nil
    ) {
        if let convo = fetchConversation(conversationId, context: context) {
            convo.updatedAt = Date()
            if let usage {
                convo.totalInputTokens += usage.inputTokens
                convo.totalOutputTokens += usage.outputTokens
            }
            if let cost { convo.totalCostUSD += cost }
        }
    }

    private func recentMessages(
        conversationId: UUID, excluding excludedId: UUID, context: ModelContext, limit: Int = 10
    ) -> [CoachOrchestrator.PriorMessage] {
        // Fetch the NEWEST 40 (descending), then restore chronological order for replay. Sorting
        // ascending with a fetchLimit caps at the OLDEST 40 rows, so a conversation past 40 messages
        // would freeze the coach's replayed context at messages 31–40 and never see anything newer.
        // historyTurns is 4/10, so 40 is an ample buffer after dropping the current turn + errors.
        var descriptor = FetchDescriptor<CoachMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 40
        let rows = Array(((try? context.fetch(descriptor)) ?? []).reversed())
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
