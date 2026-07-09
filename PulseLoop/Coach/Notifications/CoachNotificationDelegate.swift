import Foundation
import UserNotifications

/// Shared deep-link state. Setting `requestedConversationId` makes `MainTabView`
/// switch to the Coach tab and `CoachView` open that conversation. Used by both
/// daily-check-in notification taps and Today/Sleep summary-card taps.
@MainActor
@Observable
final class CoachNavigation {
    static let shared = CoachNavigation()
    var requestedConversationId: UUID?
    /// Drives the Coach sheet. Coach is no longer a tab, so all entry points
    /// (summary-card tap, notification deep-link, header button) set this true.
    var showCoach = false

    /// Open the coach on a specific conversation (deep link).
    func open(_ conversationId: UUID) {
        requestedConversationId = conversationId
        showCoach = true
    }

    /// Open the coach with no specific conversation (e.g. the floating bubble).
    /// Clears any prior deep-link id so it doesn't reopen a stale thread.
    func openRoot() {
        requestedConversationId = nil
        showCoach = true
    }
}

/// UNUserNotificationCenter delegate: shows check-ins while foreground and
/// deep-links a tap to the coach thread.
final class CoachNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let idString = info[CoachNotificationService.conversationIdKey] as? String,
           let id = UUID(uuidString: idString) {
            await MainActor.run { CoachNavigation.shared.open(id) }
        }
    }
}
