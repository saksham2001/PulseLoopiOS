import BackgroundTasks
import Foundation

/// Schedules + handles the background wake that produces daily check-ins.
/// Best-effort: iOS runs the app-refresh task opportunistically within the next
/// slot window; we reschedule after every run.
@MainActor
final class CoachNotificationScheduler {
    static let shared = CoachNotificationScheduler()
    static let taskIdentifier = "com.pulseloop.coach.refresh"

    /// Builds a service bound to the live model context + ring coordinator.
    private var serviceProvider: (() -> CoachNotificationService)?

    func register(serviceProvider: @escaping () -> CoachNotificationService) {
        self.serviceProvider = serviceProvider
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            // `using: nil` runs the launch handler on a private background queue,
            // so hop to the main actor rather than asserting we're already on it.
            Task { @MainActor in Self.shared.handle(task) }
        }
    }

    /// Queue the next wake at the next morning/evening window. No-op when disabled
    /// (either the master switch or the per-feature notifications toggle is off).
    func scheduleNext(now: Date = Date()) {
        let settings = CoachSettingsStore.shared.settings
        guard settings.coachMasterEnabled, settings.notificationsEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = CoachNotificationSlot.nextWindowStart(
            after: now, morningHour: settings.morningHour, eveningHour: settings.eveningHour
        )
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private func handle(_ task: BGTask) {
        scheduleNext()  // always queue the following window first
        guard let service = serviceProvider?() else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task {
            _ = await service.runDueSlot()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
