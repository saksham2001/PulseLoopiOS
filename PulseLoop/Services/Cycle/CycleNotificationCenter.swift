import Foundation
import SwiftData
import UserNotifications

/// Schedules the period-prediction notifications and handles their one-tap actions. The
/// "has it started?" prompt with a **Yes, log it** action *is* the feature's one-tap UX:
/// day 1 gets logged from the lock screen without opening the app.
///
/// Notification copy is deliberately discreet — a lock screen should not broadcast cycle
/// details beyond what the prompt needs.
@MainActor
final class CycleNotificationCenter {
    static let shared = CycleNotificationCenter()

    static let categoryIdentifier = "pulseloop.cycle.periodPrompt"
    static let actionStarted = "pulseloop.cycle.periodStarted"
    static let actionNotYet = "pulseloop.cycle.periodNotYet"
    private static let dueRequestIdentifier = "pulseloop.cycle.periodDue"
    private static let preAlertRequestIdentifier = "pulseloop.cycle.periodPreAlert"

    /// Set once at app start; the notification delegate has no other path to the store.
    private var contextProvider: (() -> ModelContext)?

    func register(contextProvider: @escaping () -> ModelContext) {
        self.contextProvider = contextProvider
        registerCategory()
    }

    private func registerCategory() {
        let started = UNNotificationAction(identifier: Self.actionStarted, title: "Yes — log day 1", options: [])
        let notYet = UNNotificationAction(identifier: Self.actionNotYet, title: "Not yet", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [started, notYet],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            UNUserNotificationCenter.current().setNotificationCategories(existing.union([category]))
        }
    }

    /// Re-derive the prediction and (re)schedule the prompt(s). Called on app-active and
    /// after any cycle edit; always replaces what was previously pending so a changed
    /// prediction never leaves a stale notification behind.
    func scheduleNext() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.dueRequestIdentifier, Self.preAlertRequestIdentifier])

        let store = CycleSettingsStore.shared
        guard store.isActive, store.settings.periodPromptEnabled, let context = contextProvider?() else { return }
        guard CycleService.isAvailable(context: context) else { return }
        let overview = CycleService.overview(context: context)
        guard let prediction = overview.analysis?.nextPeriod else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if prediction.expected >= today {
            schedule(
                identifier: Self.dueRequestIdentifier,
                on: prediction.expected,
                body: "Your period is due around today — has it started?",
                withActions: true,
                calendar: calendar
            )
        }
        if store.settings.preAlertEnabled,
           let preAlertDay = calendar.date(byAdding: .day, value: -2, to: prediction.expected),
           preAlertDay >= today {
            schedule(
                identifier: Self.preAlertRequestIdentifier,
                on: preAlertDay,
                body: "Your period is likely in about 2 days.",
                withActions: false,
                calendar: calendar
            )
        }
    }

    func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dueRequestIdentifier, Self.preAlertRequestIdentifier])
    }

    private func schedule(identifier: String, on day: Date, body: String, withActions: Bool, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = "PulseLoop"
        content.body = body
        content.sound = .default
        if withActions { content.categoryIdentifier = Self.categoryIdentifier }

        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Route a notification action. "Yes" writes today's period day straight into the store —
    /// the app never needs to open.
    func handleAction(identifier: String) {
        guard identifier == Self.actionStarted, let context = contextProvider?() else { return }
        let day = CycleRepository.dayOrNew(for: Date(), context: context)
        day.isPeriod = true
        CycleRepository.save(day, context: context)
        scheduleNext()
    }
}
