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
        /// The model decided there was nothing worth interrupting the user for.
        case skippedAdaptive
        /// A proactive alert fired for a detected anomaly.
        case alerted(CoachAnomaly)
        /// Proactive check ran but found nothing notable (or was rate-limited).
        case noAnomaly
    }

    private let modelContext: ModelContext
    private let coordinator: RingSyncCoordinator?
    private let keyStore: APIKeyStore
    private let geminiKeyStore: APIKeyStore
    private let openRouterKeyStore: APIKeyStore
    private let minimaxKeyStore: APIKeyStore
    private let settingsStore: CoachSettingsStore
    private let clientFactory: (String) -> ResponsesClient

    /// Data is "recent" if synced/measured within this window.
    private let freshnessWindow: TimeInterval = 3 * 3600

    init(
        modelContext: ModelContext,
        coordinator: RingSyncCoordinator? = nil,
        keyStore: APIKeyStore = OpenAIKeychainStore(),
        geminiKeyStore: APIKeyStore = GeminiKeychainStore(),
        openRouterKeyStore: APIKeyStore = OpenRouterKeychainStore(),
        minimaxKeyStore: APIKeyStore = MiniMaxKeychainStore(),
        settingsStore: CoachSettingsStore = .shared,
        clientFactory: @escaping (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) {
        self.modelContext = modelContext
        self.coordinator = coordinator
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.openRouterKeyStore = openRouterKeyStore
        self.minimaxKeyStore = minimaxKeyStore
        self.settingsStore = settingsStore
        self.clientFactory = clientFactory
    }

    /// Run the due slot. `force` bypasses the slot-window, dedupe, enabled, and
    /// freshness gates (used by the Settings test button).
    @discardableResult
    func runDueSlot(force: Bool = false, now: Date = Date()) async -> Outcome {
        let settings = settingsStore.settings

        let resolved = CoachNotificationSlot.current(
            for: now, morningHour: settings.morningHour,
            middayHour: settings.middayHour, eveningHour: settings.eveningHour
        )
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
        // Adaptive skip: when the model says there's nothing useful to add, stay
        // quiet (but the test button still forces a delivery).
        if !force, notification.skip { return .skippedAdaptive }

        let conversation = record(notification, slot: slot, now: now)
        await deliver(notification, conversationId: conversation.id)
        return .sent(slot)
    }

    /// Proactive, event-driven alert path. Detects a notable pattern in recent
    /// data and, when on-device coaching is active, delivers a calm heads-up.
    /// Gated to on-device specifically so we never fire paid cloud calls on every
    /// data event; deduped to once per anomaly kind per day.
    @discardableResult
    func runProactiveAlertIfNeeded(force: Bool = false, now: Date = Date()) async -> Outcome {
        let settings = settingsStore.settings
        guard force || (settings.coachMasterEnabled
                        && settings.notificationsEnabled
                        && settings.proactiveAlertsEnabled
                        && settings.providerMode == .appleOnDevice
                        && AppleOnDeviceAvailability.current.isAvailable) else {
            return .skippedDisabled
        }

        let slot = forcedSlot(now: now)  // only for building the context packet
        let packet = NotificationContextBuilder.build(slot: slot, context: modelContext, now: now)
        guard let anomaly = CoachAnomalyDetector.detect(packet) else { return .noAnomaly }

        if !force, isAnomalyDuplicate(anomaly, now: now) { return .noAnomaly }

        let (apiKey, activeClient) = resolveClient()
        let flags = CoachFeatureFlags(settings: settings, hasAPIKey: apiKey != nil)
        let notification = await CoachNotificationGenerator.generateAnomaly(
            anomaly: anomaly, packet: packet, flags: flags, client: activeClient
        )
        let conversation = recordAnomaly(notification, anomaly: anomaly, now: now)
        await deliver(notification, conversationId: conversation.id)
        return .alerted(anomaly)
    }

    func isAnomalyDuplicate(_ anomaly: CoachAnomaly, now: Date) -> Bool {
        let key = CoachNotificationRecord.dateKey(for: now)
        let raw = anomaly.dedupeKey
        let descriptor = FetchDescriptor<CoachNotificationRecord>(
            predicate: #Predicate { $0.dateKey == key && $0.slotRaw == raw }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
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
        CoachClientResolver.resolve(
            settings: settingsStore.settings,
            openAIKeyStore: keyStore,
            geminiKeyStore: geminiKeyStore,
            openRouterKeyStore: openRouterKeyStore,
            minimaxKeyStore: minimaxKeyStore,
            openAIClientFactory: clientFactory
        )
    }

    private func forcedSlot(now: Date) -> CoachNotificationSlot {
        let hour = Calendar.current.component(.hour, from: now)
        if hour < 11 { return .morning }
        if hour < 16 { return .midday }
        return .evening
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
        // Render as a structured card so the chip + card UI matches the rest of the
        // coach. The richer tip/follow-up land in the chat thread (not the terse push).
        let summary = chatSummary(for: notification)
        let response = CoachResponse(responseType: .insight, title: notification.title,
                                     summary: summary, confidence: .medium)
        modelContext.insert(CoachMessage(
            conversationId: convo.id, role: "assistant",
            body: "\(notification.title)\n\n\(summary)",
            cardsJSON: response.encodedJSON(), createdAt: now
        ))
        convo.updatedAt = now
        try? modelContext.save()
        return convo
    }

    /// Persist a proactive alert (deduped by `anomaly.dedupeKey`) and seed a
    /// fresh conversation, mirroring `record` for daily check-ins.
    @discardableResult
    func recordAnomaly(_ notification: CoachNotification, anomaly: CoachAnomaly, now: Date) -> CoachConversation {
        modelContext.insert(CoachNotificationRecord(
            slotRaw: anomaly.dedupeKey, dateKey: CoachNotificationRecord.dateKey(for: now),
            title: notification.title, body: notification.body
        ))
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let convo = CoachConversation(title: "Heads-up · \(f.string(from: now))")
        modelContext.insert(convo)
        let summary = chatSummary(for: notification)
        let response = CoachResponse(responseType: .insight, title: notification.title,
                                     summary: summary, confidence: .medium)
        modelContext.insert(CoachMessage(
            conversationId: convo.id, role: "assistant",
            body: "\(notification.title)\n\n\(summary)",
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

    /// The richer body for the in-app chat card: the check-in plus the actionable
    /// tip and a tappable follow-up question when present.
    private func chatSummary(for n: CoachNotification) -> String {
        var parts = [n.body]
        if !n.tip.isEmpty { parts.append("💡 \(n.tip)") }
        if !n.followUp.isEmpty { parts.append(n.followUp) }
        return parts.joined(separator: "\n\n")
    }

    private func deliver(_ notification: CoachNotification, conversationId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        // Keep the push terse: body, plus the tip if it stays within a glanceable
        // length. The full tip + follow-up live in the chat thread.
        var pushBody = notification.body
        if !notification.tip.isEmpty, pushBody.count + notification.tip.count < 150 {
            pushBody += " \(notification.tip)"
        }
        content.body = pushBody
        content.sound = .default
        content.userInfo = [CoachNotificationService.conversationIdKey: conversationId.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// userInfo key the app delegate reads to deep-link a tap to the coach thread.
    static let conversationIdKey = "coach_conversation_id"
}
