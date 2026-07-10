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
    /// Quiet period after the last inbound record before we call the dump complete. Matches the Colmi
    /// engine's per-stage timeout: a 4s window let a slow multi-frame sleep transfer time out and get
    /// acked away mid-record.
    private let historyQuietTimeout: UInt64 = 10_000_000_000

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
        let timeout = historyQuietTimeout
        historyWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
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
        // Every record a history frame can decode to. `.sleepTimeline` and `.bloodPressureSample` used
        // to fall through, so a night of sleep or a BP-only page never asked for the next page.
        // Deliberately *not* `.activityUpdate`: the ring's continuous live `06 00` status decodes to
        // that too, and treating it as history would keep the watchdog alive forever, so the dump
        // would never finish and `historyAck` would never be sent.
        case .historyMeasurement, .activityBucket, .bloodPressureSample, .sleepTimeline:
            writer?.enqueue(Data(encoder.historyPage()))
            armHistoryWatchdog()
        case .historySyncProgress:
            // `TK5Driver` announces every history frame with this, including a sleep continuation that
            // decodes to nothing and an all-unworn page that decodes to no records. Keep the dump
            // alive, but don't ask for the next page — the ring may still be streaming this one.
            armHistoryWatchdog()
        default:
            break
        }
    }

    // MARK: Live actions (proprietary 06-stream on be940003, mode-selected by 03 2f)
    //
    // The `03 2f` payload is [enable, mode]; the mode byte picks the sensor/LED (HR 0x00 → 06 01,
    // SpO₂ 0x02 → 06 02, HRV 0x0a → 06 03). Each metric must start its own mode — the shared stop is
    // mode-agnostic. Only one mode runs at a time, so start-then-stop per measurement is correct.

    func startHeartRate() {
        writer?.enqueue(Data(encoder.heartRateStart()))
    }

    func stopHeartRate() {
        writer?.enqueue(Data(encoder.liveStreamStop()))
    }

    func startSpO2() {
        writer?.enqueue(Data(encoder.spo2Start()))
    }

    func stopSpO2() {
        writer?.enqueue(Data(encoder.liveStreamStop()))
    }

    func startHRV() {
        writer?.enqueue(Data(encoder.hrvStart()))
    }

    func stopHRV() {
        writer?.enqueue(Data(encoder.liveStreamStop()))
    }

    func findDevice() {
        writer?.enqueue(Data(encoder.findDevice()))
    }

    func setGoal(steps: Int) {
        // No confirmed goal-write command in the capture; PulseLoop persists the goal regardless.
    }
}
