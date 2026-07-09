import Foundation
import SwiftData

/// Subscribes to `PulseEventBus` and triggers coach-summary regeneration on new
/// data, debounced so streaming packets coalesce into one refresh. The service
/// self-gates (signature + rate limit), so this just nudges it on relevant
/// events. Lives for the app lifetime, like `EventPersistenceSubscriber`.
@MainActor
final class CoachSummaryCoordinator {
    private let service: CoachSummaryService
    private var streamTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var pendingToday = false
    private var pendingSleep = false

    /// Debounce window — long enough for a sleep download / activity sync to settle.
    private let debounceSeconds: UInt64 = 30

    init(context: ModelContext) {
        self.service = CoachSummaryService(modelContext: context)
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
        case .activityUpdate, .heartRateSample, .spo2Result, .historyMeasurement:
            pendingToday = true
            scheduleRefresh()
        case .sleepTimeline:
            pendingSleep = true
            pendingToday = true
            scheduleRefresh()
        case let .syncProgress(stage) where stage == "done":
            // A full history sync just completed — the sleep gate may now pass, so
            // re-evaluate both cards (the service self-gates if there's nothing new).
            pendingSleep = true
            pendingToday = true
            scheduleRefresh()
        default:
            break
        }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceSeconds ?? 30) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // Skip background regeneration entirely when the user has turned the
            // coach off; the views won't render the summaries anyway.
            guard CoachSettingsStore.shared.settings.coachMasterEnabled else {
                pendingToday = false; pendingSleep = false; return
            }
            if pendingToday { pendingToday = false; await service.refreshTodayIfNeeded() }
            if pendingSleep { pendingSleep = false; await service.refreshSleepDayIfNeeded() }
        }
    }
}
