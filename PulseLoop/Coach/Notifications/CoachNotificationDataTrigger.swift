import Foundation
import UIKit

/// Fires the coach check-in the moment fresh data actually lands, instead of only at the scheduled
/// wake. Subscribes to `PulseEventBus` and, when a full history sync completes, runs the due slot —
/// so a slot the BGTask skipped as `.skippedStaleData` (ring out of range, sync didn't finish in
/// budget) is delivered right after the pending connect re-links the ring and the background sync
/// finishes, while the numbers are minutes old.
///
/// Deliberately owns no slot/dedupe/freshness logic: `runDueSlot` gates everything. A sync that
/// completes outside a slot window is `.skippedNoSlot` (silence), an already-sent slot is
/// `.skippedDuplicate`, and the service's static in-flight guard covers a race with a concurrently
/// running BGTask. Lives for the app lifetime, like `CoachSummaryCoordinator`.
@MainActor
final class CoachNotificationDataTrigger {
    private let serviceProvider: () -> CoachNotificationService
    private var streamTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    /// Short settle window after the `"done"` event: bus fan-out order between subscribers isn't
    /// guaranteed, so this lets `EventPersistenceSubscriber` stamp `Device.lastFullSyncAt` (what
    /// `hasRecentData` reads) before the slot runs — and coalesces back-to-back completions.
    private let debounceSeconds: UInt64 = 3

    init(serviceProvider: @escaping () -> CoachNotificationService) {
        self.serviceProvider = serviceProvider
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: PulseEvent) {
        guard case let .syncProgress(stage) = event, stage == "done" else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceSeconds ?? 3) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.runAfterSync()
        }
    }

    private func runAfterSync() async {
        let settings = CoachSettingsStore.shared.settings
        guard settings.coachMasterEnabled, settings.notificationsEnabled else { return }
        // The BLE wake that delivered the sync's last packet grants only ~10s; ask for the standard
        // ~30s finite-task extension so LLM generation (on-device or one remote round-trip) can
        // finish. If iOS calls the expiration handler first, the work is simply cut short — the slot
        // stays unrecorded and the next trigger/BGTask/foreground catch-up picks it up.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "coach.dataTrigger") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        let service = serviceProvider()
        await service.runDueSlot()
        _ = await service.runProactiveAlertIfNeeded()
    }
}
