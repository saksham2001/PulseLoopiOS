import Foundation
import SwiftData

/// Owns the Today/Sleep coach-card summaries: self-gating regeneration and the
/// tap → seeded-chat flow. Read the current summary for a card with
/// `current(...)`; trigger regeneration with the `refresh…IfNeeded` methods
/// (safe to call often — they gate on data signature + rate limit).
@MainActor
final class CoachSummaryService {
    private let modelContext: ModelContext
    private let keyStore: APIKeyStore
    private let geminiKeyStore: APIKeyStore
    private let openRouterKeyStore: APIKeyStore
    private let settingsStore: CoachSettingsStore
    private let clientFactory: (String) -> ResponsesClient

    /// Minimum gap between Today / aggregate-sleep regenerations.
    private let minInterval: TimeInterval = 2 * 3600

    init(
        modelContext: ModelContext,
        keyStore: APIKeyStore = OpenAIKeychainStore(),
        geminiKeyStore: APIKeyStore = GeminiKeychainStore(),
        openRouterKeyStore: APIKeyStore = OpenRouterKeychainStore(),
        settingsStore: CoachSettingsStore = .shared,
        clientFactory: @escaping (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) {
        self.modelContext = modelContext
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.openRouterKeyStore = openRouterKeyStore
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory
    }

    // MARK: - Reads (for the views)

    func summary(kind rawKind: String, scopeKey: String) -> CoachSummary? {
        let descriptor = FetchDescriptor<CoachSummary>(
            predicate: #Predicate { $0.kind == rawKind && $0.scopeKey == scopeKey }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    func currentToday(now: Date = Date()) -> CoachSummary? {
        summary(kind: CoachSummaryKind.today.rawValue, scopeKey: CoachDataAccess.localDateString(now))
    }

    func currentSleepRange(_ range: SleepRangeKey) -> CoachSummary? {
        let kind = CoachSummaryKind.sleepRange(range)
        return summary(kind: kind.rawValue, scopeKey: kind.rawValue)
    }

    func currentSleepDay() -> CoachSummary? {
        // The nightly summary is keyed by the night's date; look up the latest one.
        var descriptor = FetchDescriptor<CoachSummary>(
            predicate: #Predicate { $0.kind == "sleep_day" },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Refresh (self-gating)

    func refreshTodayIfNeeded(now: Date = Date()) async {
        let built = CoachSummaryContextBuilder.today(context: modelContext, now: now)
        let existing = summary(kind: CoachSummaryKind.today.rawValue, scopeKey: built.scopeKey)
        if let existing {
            if existing.dataSignature == built.signature { return }       // no new data
            if now.timeIntervalSince(existing.updatedAt) < minInterval { return }  // ≥2h floor
        }
        await generateAndUpsert(.today, built: built, existing: existing, now: now)
    }

    func refreshSleepDayIfNeeded(now: Date = Date()) async {
        guard let built = CoachSummaryContextBuilder.sleepDay(context: modelContext, now: now) else { return }
        // Once per night: only when this night isn't summarized yet.
        if summary(kind: CoachSummaryKind.sleepDay.rawValue, scopeKey: built.scopeKey) != nil { return }
        await generateAndUpsert(.sleepDay, built: built, existing: nil, now: now)
    }

    func refreshSleepRangeIfNeeded(_ range: SleepRangeKey, now: Date = Date()) async {
        let built = CoachSummaryContextBuilder.sleepRange(range, context: modelContext, now: now)
        let existing = summary(kind: CoachSummaryKind.sleepRange(range).rawValue, scopeKey: built.scopeKey)
        if let existing {
            if existing.dataSignature == built.signature { return }
            if now.timeIntervalSince(existing.updatedAt) < minInterval { return }
        }
        await generateAndUpsert(.sleepRange(range), built: built, existing: existing, now: now)
    }

    private func resolveClient() -> (key: String?, client: ResponsesClient) {
        CoachClientResolver.resolve(
            settings: settingsStore.settings,
            openAIKeyStore: keyStore,
            geminiKeyStore: geminiKeyStore,
            openRouterKeyStore: openRouterKeyStore,
            openAIClientFactory: clientFactory
        )
    }

    private func generateAndUpsert(
        _ kind: CoachSummaryKind, built: CoachSummaryContextBuilder.Built,
        existing: CoachSummary?, now: Date
    ) async {
        let (apiKey, activeClient) = resolveClient()
        let flags = CoachFeatureFlags(settings: settingsStore.settings, hasAPIKey: apiKey != nil)
        let content = await CoachSummaryGenerator.generate(
            kind: kind, contextJSON: built.json, fallback: built.fallback,
            flags: flags, client: activeClient
        )
        if let existing {
            existing.apply(content, signature: built.signature, now: now)
        } else {
            modelContext.insert(CoachSummary(
                kind: kind.rawValue, scopeKey: built.scopeKey,
                title: content.title, body: content.body, chips: content.chips,
                dataSignature: built.signature
            ))
        }
        try? modelContext.save()
    }

    // MARK: - Tap → seeded chat

    /// Open (or create) the chat thread seeded with this summary as the first
    /// assistant message, then deep-link to it. Idempotent.
    func openInChat(_ summary: CoachSummary) {
        if let id = summary.conversationId, conversationExists(id) {
            CoachNavigation.shared.open(id)
            return
        }
        let convo = CoachConversation(title: conversationTitle(for: summary.kind))
        modelContext.insert(convo)
        let content = CoachSummaryContent(title: summary.title, body: summary.body, chips: summary.chips)
        modelContext.insert(CoachMessage(
            conversationId: convo.id, role: "assistant",
            body: "\(summary.title)\n\n\(summary.body)",
            cardsJSON: content.asCoachResponse().encodedJSON()
        ))
        summary.conversationId = convo.id
        try? modelContext.save()
        CoachNavigation.shared.open(convo.id)
    }

    private func conversationExists(_ id: UUID) -> Bool {
        let descriptor = FetchDescriptor<CoachConversation>(predicate: #Predicate { $0.id == id })
        return ((try? modelContext.fetch(descriptor))?.isEmpty == false)
    }

    private func conversationTitle(for rawKind: String) -> String {
        if rawKind == "today" { return CoachSummaryKind.today.conversationTitle }
        if rawKind == "sleep_day" { return CoachSummaryKind.sleepDay.conversationTitle }
        return "Sleep trend"
    }
}
