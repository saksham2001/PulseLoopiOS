import Foundation

/// TK5 sync engine. Connect is a faithful replay of the SmartHealth app's handshake, followed by an
/// on-connect history dump. Like the jring it's largely fire-and-forget; the one response-driven flow
/// is history paging, which mirrors the Colmi engine's watchdog pattern (page on each record, finish
/// when the record stream goes quiet).
///
/// The TK5 has no confirmed on-device profile / goal / measurement-interval commands in the capture,
/// so those `RingSyncEngine` hooks are intentional no-ops (defaults inherited from the protocol
/// extension). Live HR **and** SpO₂ share one proprietary stream toggled by `03 2f`.
@MainActor
final class TK5SyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let encoder = TK5Encoder()

    init(writer: RingCommandWriter?) {
        self.writer = writer
    }

    // MARK: Startup

    func runStartup() {
        for command in encoder.startupSequence() {
            writer?.enqueue(Data(command))
        }
        startHistorySync()
    }

    // MARK: History dump (watchdog-driven paging)

    private var historyActive = false
    private var historyWatchdog: Task<Void, Never>?
    private let historyQuietTimeout: UInt64 = 4_000_000_000   // 4s of no records ⇒ dump complete

    private func startHistorySync() {
        historyActive = true
        // Zero the ring-history activity days we're about to re-sum, so re-syncs stay idempotent
        // (same guard the Colmi engine uses before summing history buckets).
        Task { await PulseEventBus.shared.publish(.activitySyncReset(sinceDaysAgo: 7)) }
        writer?.enqueue(Data(encoder.historyStart()))
        armHistoryWatchdog()
    }

    private func armHistoryWatchdog() {
        historyWatchdog?.cancel()
        historyWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.historyQuietTimeout ?? 4_000_000_000)
            guard !Task.isCancelled, let self, self.historyActive else { return }
            self.finishHistorySync()
        }
    }

    private func finishHistorySync() {
        historyActive = false
        historyWatchdog?.cancel()
        historyWatchdog = nil
        writer?.enqueue(Data(encoder.historyAck()))
        Task { await PulseEventBus.shared.publish(.syncProgress(stage: "done")) }
    }

    func handle(_ event: RingDecodedEvent) {
        // While a dump is in flight, each history record pulls the next page and resets the quiet timer.
        guard historyActive else { return }
        switch event {
        case .historyMeasurement, .activityBucket:
            writer?.enqueue(Data(encoder.historyPage()))
            armHistoryWatchdog()
        default:
            break
        }
    }

    // MARK: Live actions (proprietary 06-stream, toggled by 03 2f)

    func startHeartRate() {
        writer?.enqueue(Data(encoder.liveStreamStart()))
    }

    func stopHeartRate() {
        writer?.enqueue(Data(encoder.liveStreamStop()))
    }

    func startSpO2() {
        // SpO₂ rides the same live stream as HR.
        writer?.enqueue(Data(encoder.liveStreamStart()))
    }

    func stopSpO2() {
        writer?.enqueue(Data(encoder.liveStreamStop()))
    }

    func findDevice() {
        writer?.enqueue(Data(encoder.findDevice()))
    }

    func setGoal(steps: Int) {
        // No confirmed goal-write command in the capture; PulseLoop persists the goal regardless.
    }
}
