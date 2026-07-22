import BackgroundTasks
import Foundation

/// Schedules + handles the background wake that produces daily check-ins.
/// Best-effort: iOS runs the app-refresh task opportunistically within the next
/// slot window; we reschedule after every run.
@MainActor
final class CoachNotificationScheduler {
    static let shared = CoachNotificationScheduler()
    /// App-refresh task (short budget) — used for the lightweight cloud providers.
    static let taskIdentifier = "com.pulseloop.coach.refresh"
    /// Processing task (longer budget, no network required) — used for the
    /// on-device provider, whose local inference needs more CPU time than a
    /// network round-trip. Must also appear in Info.plist's
    /// `BGTaskSchedulerPermittedIdentifiers`.
    static let processingTaskIdentifier = "com.pulseloop.coach.process"

    /// Builds a service bound to the live model context + ring coordinator. The parameter is the
    /// sync-wait budget (seconds) — how long the service's pre-notification sync may run, sized to
    /// the wake that's driving it (short for an app-refresh task, longer for a processing task).
    private var serviceProvider: ((TimeInterval) -> CoachNotificationService)?
    /// Submitting a `BGTaskRequest` whose identifier wasn't registered is a hard
    /// assertion crash. Registration is skipped under XCTest (the live subsystems
    /// don't start), so gate scheduling on it — otherwise the test host app's
    /// scene-phase `scheduleNext()` crashes.
    private var isRegistered = false

    func register(serviceProvider: @escaping (TimeInterval) -> CoachNotificationService) {
        self.serviceProvider = serviceProvider
        isRegistered = true
        let handler: (BGTask) -> Void = { task in
            // `using: nil` runs the launch handler on a private background queue,
            // so hop to the main actor rather than asserting we're already on it.
            Task { @MainActor in Self.shared.handle(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil, launchHandler: handler)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil, launchHandler: handler)
    }

    /// Queue the next wake at the next check-in window. No-op when disabled
    /// (either the master switch or the per-feature notifications toggle is off).
    /// On-device uses a processing task (longer budget); cloud uses app-refresh.
    func scheduleNext(now: Date = Date()) {
        guard isRegistered else { return }
        let settings = CoachSettingsStore.shared.settings
        guard settings.coachMasterEnabled, settings.notificationsEnabled else { return }

        // Clear any pending request of the other kind so switching provider doesn't
        // leave a stale wake queued.
        cancel()

        let begin = CoachNotificationSlot.nextWindowStart(
            after: now, morningHour: settings.morningHour,
            middayHour: settings.middayHour, eveningHour: settings.eveningHour
        )

        let request: BGTaskRequest
        if settings.providerMode == .appleOnDevice {
            let processing = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
            processing.requiresNetworkConnectivity = false  // local inference, no network
            processing.requiresExternalPower = false
            request = processing
        } else {
            request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        }
        request.earliestBeginDate = begin
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        guard isRegistered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
    }

    private func handle(_ task: BGTask) {
        scheduleNext()  // always queue the following window first
        // A processing task's budget is minutes, not ~30s — give its pre-notification sync long
        // enough for a BLE connect + paged history transfer instead of the app-refresh 15s.
        let syncBudget: TimeInterval = task is BGProcessingTask ? 120 : 15
        guard let service = serviceProvider?(syncBudget) else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task {
            let outcome = await service.runDueSlot()
            // Skipped on missing/stale data (morning sleep not synced yet, or no completed sync in
            // the freshness window) — queue one short retry so we catch the check-in once the data
            // lands, instead of waiting for the next full window. The sync-completion data trigger
            // usually beats it; this covers a sync that completes while the app stays suspended.
            if outcome == .skippedNoSleepData || outcome == .skippedStaleData {
                submitShortRetry()
            }
            // Background is a good moment to also catch a proactive alert; the
            // call self-gates (on-device only, enabled, deduped).
            _ = await service.runProactiveAlertIfNeeded()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// One +45min app-refresh wake to retry a check-in that was skipped for
    /// missing/stale data. Best-effort; the foreground catch-up and the
    /// sync-completion data trigger cover the case where the retry doesn't run.
    private func submitShortRetry() {
        guard isRegistered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(45 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
