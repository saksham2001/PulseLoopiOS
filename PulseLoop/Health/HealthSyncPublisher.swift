import SwiftUI
import SwiftData
import HealthKit

/// Drives incremental Apple Health exports off the same coalesced `PulseDataChange` signal the widget
/// publisher rides. When ring data lands (or a scene-phase edge fires), it debounces briefly and then
/// asks `HealthSyncService` to export everything newer than each category's watermark. Retained for the
/// app's lifetime by `PulseLoopApp` (like `WidgetSnapshotPublisher`).
///
/// Refresh discipline mirrors the widget publisher: a history sync bumps the token once per batch, but
/// several batches can land in quick succession, so the publish is debounced. Scene-phase edges are also
/// caught (`kick()`) since some Settings-side changes don't bump the sync token.
///
/// Guards before every scheduled export — master toggle on, HealthKit available on this device, and share
/// access granted — so a disabled or unauthorized user never wakes the export path. `HealthSyncService`
/// re-checks the same guards, but short-circuiting here avoids arming a pointless debounce timer.
@MainActor
final class HealthSyncPublisher {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private let modelContext: ModelContext
    private var debounceTask: Task<Void, Never>?

    /// Longer than the widget's 2 s: Health writes are heavier and never user-visible, so we coalesce a
    /// full sync burst into one export.
    private static let debounceSeconds: Double = 15

    init(context: ModelContext) {
        self.modelContext = context
    }

    func start() {
        observeDataChange()
    }

    /// Scene-phase edge trigger — routes through the same debounce path as a data change.
    func kick() {
        scheduleExport()
    }

    /// `withObservationTracking` is one-shot: re-arm after every fire, then debounce the export so one
    /// burst of persistence batches produces one export run.
    private func observeDataChange() {
        withObservationTracking {
            _ = PulseDataChange.shared.token
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDataChange()
                self.scheduleExport()
            }
        }
    }

    private func scheduleExport() {
        guard shouldExport() else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            guard let self, self.shouldExport() else { return }
            // A `false` return means an export was already in flight and this trigger was dropped. Rows
            // that landed after that run took its fetch snapshot would otherwise wait for an unrelated
            // trigger, so re-arm a fresh debounce to pick them up once the in-flight run finishes.
            let ran = await HealthSyncService.shared.exportIncremental(context: self.modelContext)
            if !ran { self.scheduleExport() }
        }
    }

    private func shouldExport() -> Bool {
        AppleHealthPrefsStore.shared.prefs.masterEnabled
            && AppleHealthPrefsStore.shared.prefs.backfillChoice != .notAsked
            && HKHealthStore.isHealthDataAvailable()
            && HealthSyncService.shared.authState == .authorized
    }
}
