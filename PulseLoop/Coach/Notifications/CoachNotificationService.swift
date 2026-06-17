import Foundation
import SwiftData
import UserNotifications

/// Core of the daily-check-in feature: decide whether a notification is due,
/// ensure we have fresh data (syncing the ring if needed), generate it with the
/// LLM, deliver it, and record it. Reused by the background task, a foreground
/// catch-up, and the Settings "send test" button.
@MainActor
final class CoachNotificationService {
    enum Outcome: Equatable {
        case sent(CoachNotificationSlot)
        case skippedNoSlot
        case skippedDuplicate
        case skippedDisabled
        case skippedNoData
    }

    private let modelContext: ModelContext
    private let coordinator: RingSyncCoordinator?
    private let keyStore: APIKeyStore
    private let geminiKeyStore: APIKeyStore
    private let settingsStore: CoachSettingsStore
    private let clientFactory: (String) -> ResponsesClient

    /// Data is "recent" if synced/measured within this window.
    private let freshnessWindow: TimeInterval = 3 * 3600

    init(
        modelContext: ModelContext,
        coordinator: RingSyncCoordinator? = nil,
        keyStore: APIKeyStore = OpenAIKeychainStore(),
        geminiKeyStore: APIKeyStore = GeminiKeychainStore(),
        settingsStore: CoachSettingsStore = .shared,
        clientFactory: @escaping (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) {
        self.modelContext = modelContext
        self.coordinator = coordinator
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory
    }

    /// Run the due slot. `force` bypasses the slot-window, dedupe, enabled, and
    /// freshness gates (used by the Settings test button).
    @discardableResult
    func runDueSlot(force: Bool = false, now: Date = Date()) async -> Outcome {
        let settings = settingsStore.settings

        let resolved = CoachNotificationSlot.current(for: now, morningHour: settings.morningHour, eveningHour: settings.eveningHour)
        guard let slot = resolved ?? (force ? forcedSlot(now: now) : nil) else { return .skippedNoSlot }

        if !force, isDuplicate(slot: slot, now: now) { return .skippedDuplicate }

        let (apiKey, activeClient) = resolveClient()
        let flags = CoachFeatureFlags(settings: settings, hasAPIKey: apiKey != nil)
        guard force || flags.coachEnabled else { return .skippedDisabled }

        if !force, !hasRecentData(now: now) {
            await attemptSync()
            if !hasRecentData(now: Date()) { return .skippedNoData }
        }

        let packet = NotificationContextBuilder.build(slot: slot, context: modelContext, now: now)
        let notification = await CoachNotificationGenerator.generate(
            slot: slot, packet: packet, flags: flags, client: activeClient
        )
        let conversation = record(notification, slot: slot, now: now)
        await deliver(notification, conversationId: conversation.id)
        return .sent(slot)
    }

    // MARK: - Gates (testable)

    func isDuplicate(slot: CoachNotificationSlot, now: Date) -> Bool {
        let key = CoachNotificationRecord.dateKey(for: now)
        let raw = slot.rawValue
        let descriptor = FetchDescriptor<CoachNotificationRecord>(
            predicate: #Predicate { $0.dateKey == key && $0.slotRaw == raw }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    func hasRecentData(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-freshnessWindow)
        if let lastSync = DeviceRepository.current(context: modelContext)?.lastSyncAt, lastSync >= cutoff { return true }
        if let latest = latestMeasurementTimestamp(), latest >= cutoff { return true }
        return false
    }

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

    private func forcedSlot(now: Date) -> CoachNotificationSlot {
        Calendar.current.component(.hour, from: now) < 14 ? .morning : .evening
    }

    private func latestMeasurementTimestamp() -> Date? {
        [MetricsRepository.latestMeasurement(kind: .heartRate, context: modelContext)?.timestamp,
         MetricsRepository.latestMeasurement(kind: .spo2, context: modelContext)?.timestamp]
            .compactMap { $0 }.max()
    }

    private func attemptSync() async {
        guard let coordinator else { return }
        await coordinator.pullToRefresh()
        for _ in 0..<5 {  // ~10s, within the background budget
            if hasRecentData(now: Date()) { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Record + deliver

    /// Persist the check-in and seed a *fresh* conversation for it. Each
    /// notification is independent — tapping it opens its own thread instead of
    /// piling into one shared "Daily check-ins" log (which made earlier check
    /// -ins masquerade as prior turns and confused the coach on follow-ups).
    @discardableResult
    func record(_ notification: CoachNotification, slot: CoachNotificationSlot, now: Date) -> CoachConversation {
        modelContext.insert(CoachNotificationRecord(
            slot: slot, dateKey: CoachNotificationRecord.dateKey(for: now),
            title: notification.title, body: notification.body
        ))
        let convo = CoachConversation(title: notificationConversationTitle(notification, slot: slot, at: now))
        modelContext.insert(convo)
        // Render as a structured card so the chip + card UI matches the rest of the coach.
        let response = CoachResponse(responseType: .insight, title: notification.title,
                                     summary: notification.body, confidence: .medium)
        modelContext.insert(CoachMessage(
            conversationId: convo.id, role: "assistant",
            body: "\(notification.title)\n\n\(notification.body)",
            cardsJSON: response.encodedJSON(), createdAt: now
        ))
        convo.updatedAt = now
        try? modelContext.save()
        return convo
    }

    private func notificationConversationTitle(_ notification: CoachNotification, slot: CoachNotificationSlot, at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(slot.label) check-in · \(f.string(from: date))"
    }

    static let dailyCheckinsTitle = "Daily check-ins"

    private func deliver(_ notification: CoachNotification, conversationId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = [CoachNotificationService.conversationIdKey: conversationId.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// userInfo key the app delegate reads to deep-link a tap to the coach thread.
    static let conversationIdKey = "coach_conversation_id"
}
