import Foundation
import SwiftData

/// Subscribes to `PulseEventBus` and runs a proactive anomaly check when fresh
/// SpO₂ or sleep data lands, debounced so a burst of streamed packets coalesces
/// into one check. The service self-gates (on-device only, enabled, deduped), so
/// this just nudges it. Lives for the app lifetime, like `CoachSummaryCoordinator`.
@MainActor
final class CoachAnomalyMonitor {
    private let service: CoachNotificationService
    private var streamTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    /// Debounce window — long enough for an SpO₂ batch / sleep download to settle.
    private let debounceSeconds: UInt64 = 20

    init(context: ModelContext) {
        self.service = CoachNotificationService(modelContext: context)
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
        switch event {
        case .spo2Result, .sleepTimeline, .historyMeasurement:
            scheduleCheck()
        default:
            break
        }
    }

    private func scheduleCheck() {
        // Cheap pre-gate so we don't spin up a debounce when the feature is off.
        let settings = CoachSettingsStore.shared.settings
        guard settings.coachMasterEnabled, settings.proactiveAlertsEnabled,
              settings.providerMode == .appleOnDevice else { return }

        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceSeconds ?? 20) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await service.runProactiveAlertIfNeeded()
        }
    }
}
