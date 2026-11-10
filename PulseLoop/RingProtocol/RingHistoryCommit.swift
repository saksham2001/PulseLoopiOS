import Foundation

/// Durable-commit barrier for destructive history consumption.
///
/// Vendor apps erase a ring's stored history once it has been imported (SmartHealth/YCBT deletes each
/// type only after its database insert succeeds; RWfit deletes page by page). PulseLoop's normal
/// history path is asynchronous — decoded events hop through `PulseEventBus` and are saved by
/// `EventPersistenceSubscriber` on a debounce — so the moment a transfer completes, nothing is on disk
/// yet. Erasing then would lose the data on a crash or a failed save.
///
/// A barrier closes that gap: the writer publishes `.historyCommitBarrier(id)` on the same ordered path
/// as the history events it follows, the persistence subscriber reaches it only after applying every
/// earlier event, performs a throwing `context.save()`, and resolves the waiter with the outcome. The
/// caller erases ring history only on `true`. Every failure mode — no subscriber running, a failed save,
/// the timeout — resolves `false`, so the ring keeps its data and the next sync simply re-imports it
/// (history rows are upserted, so the replay is harmless).
@MainActor
enum RingHistoryCommit {
    /// Generous: the subscriber normally answers within one main-actor turn, but a large sync burst can
    /// queue thousands of events ahead of the barrier.
    nonisolated static let timeoutNanoseconds: UInt64 = 20_000_000_000

    private static var waiters: [UUID: @MainActor (Bool) -> Void] = [:]

    /// Register a waiter and return the barrier id to publish. The completion runs exactly once.
    static func register(timeoutNanoseconds: UInt64 = timeoutNanoseconds,
                         _ completion: @escaping @MainActor (Bool) -> Void) -> UUID {
        let id = UUID()
        waiters[id] = completion
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            resolve(id, committed: false)
        }
        return id
    }

    /// Called by the persistence subscriber once everything published before the barrier is saved (or
    /// the save failed). A no-op for an unknown or already-resolved id.
    static func resolve(_ id: UUID, committed: Bool) {
        waiters.removeValue(forKey: id)?(committed)
    }
}
