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

    /// What to do when a pre-notification sync can't produce fresh data in time. The user chose to
    /// send anyway with last-known data (guaranteed non-garbage by validation upstream); flipping to
    /// `.skip` restores the old "stay quiet" behaviour in one line.
    enum StaleDataPolicy { case sendWithLastKnown, skip }

    private let modelContext: ModelContext
    /// The ring-sync seam (real `RingSyncCoordinator` in the app; a fake in tests; nil when there's no
    /// coordinator to drive, e.g. a pure-generation call).
    private let syncGate: RingSyncGating?
    private let keyStore: APIKeyStore
    private let geminiKeyStore: APIKeyStore
    private let openRouterKeyStore: APIKeyStore
    private let minimaxKeyStore: APIKeyStore
    private let settingsStore: CoachSettingsStore
    private let clientFactory: (String) -> ResponsesClient

    /// Data is "recent" if synced/measured within this window.
    private let freshnessWindow: TimeInterval = 3 * 3600
    /// How long the pre-notification sync may run before we give up and fall back to last-known data.
    /// Bounded so the BGTask budget (~30s) is respected.
    private let syncWaitTimeout: TimeInterval
    /// Whether a stale-data result should still send (with last-known data) or skip.
    private let staleDataPolicy: StaleDataPolicy

    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    init(
        modelContext: ModelContext,
        coordinator: RingSyncGating? = nil,
        keyStore: APIKeyStore = OpenAIKeychainStore(),
        geminiKeyStore: APIKeyStore = GeminiKeychainStore(),
        openRouterKeyStore: APIKeyStore = OpenRouterKeychainStore(),
        minimaxKeyStore: APIKeyStore = MiniMaxKeychainStore(),
        settingsStore: CoachSettingsStore = .shared,
        syncWaitTimeout: TimeInterval = 15,
        staleDataPolicy: StaleDataPolicy = .sendWithLastKnown,
        clientFactory: @escaping (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) {
        self.modelContext = modelContext
        self.syncGate = coordinator
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.openRouterKeyStore = openRouterKeyStore
        self.minimaxKeyStore = minimaxKeyStore
        self.settingsStore = settingsStore
        self.syncWaitTimeout = syncWaitTimeout
        self.staleDataPolicy = staleDataPolicy
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

        if !force {
            let fresh = await ensureFreshData(now: now)
            if Task.isCancelled { return .skippedNoData }          // BGTask expired mid-wait
            if !fresh {
                if staleDataPolicy == .skip { return .skippedNoData }
                // sendWithLastKnown: proceed, but never with a totally empty store.
                if latestMeasurementTimestamp() == nil { return .skippedNoData }
            }
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
        // Gate on the last *completed history sync*, not `lastSyncAt` — the latter is re-stamped on
        // every CONNECT (before any data streams), which made this near-always true and let stale
        // check-ins fire mid-sync. `lastFullSyncAt` is stamped only on `.syncProgress("done")`.
        if let fullSync = DeviceRepository.current(context: modelContext)?.lastFullSyncAt, fullSync >= cutoff { return true }
        // Fallback: a recent live measurement is fresh data even without a full-sync stamp (covers
        // jring, which streams samples continuously rather than running a paged history sync).
        if let latest = latestMeasurementTimestamp(), latest >= cutoff { return true }
        return false
    }

    /// Whether a full history sync completed within `within` — used to skip a redundant re-sync when
    /// the ring is connected but we synced very recently.
    private func hasFreshFullSync(now: Date, within: TimeInterval) -> Bool {
        guard let fullSync = DeviceRepository.current(context: modelContext)?.lastFullSyncAt else { return false }
        return fullSync >= now.addingTimeInterval(-within)
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

    /// Best-effort: get the freshest possible data before building the notification context. Awaits an
    /// in-flight sync, or starts one when the ring is reachable, bounded by `syncWaitTimeout` so the
    /// BGTask budget (~30s) is respected. Returns whether the store now holds recent data.
    private func ensureFreshData(now: Date) async -> Bool {
        if let gate = syncGate {
            if gate.isSyncInFlight {
                // A sync is already running — just wait it out rather than kicking off a second one.
                _ = await gate.awaitSyncCompletion(timeout: syncWaitTimeout)
            } else if gate.isRingConnected {
                // Connected: run a fresh sync unless we already completed one very recently.
                if !hasFreshFullSync(now: now, within: 10 * 60) {
                    gate.beginSync()
                    _ = await gate.awaitSyncCompletion(timeout: syncWaitTimeout)
                }
            } else if !hasRecentData(now: now) {
                // Disconnected and stale: try to (re)connect and sync before falling back.
                await gate.connectAndSync()
                _ = await gate.awaitSyncCompletion(timeout: syncWaitTimeout)
            }
        }
        return hasRecentData(now: Date())
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
