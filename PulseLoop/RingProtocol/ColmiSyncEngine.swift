import Foundation

/// Colmi R02 sync engine: the response-driven history state machine + realtime-HR keepalive +
/// measurement actions. Unlike the fire-and-forget jring, Colmi history is a chain where each reply
/// triggers the next request.
///
/// Stage order (per `docs/ColmiR02-Protocol.md` §5):
///   activity(0..7) → HR(0..7) → stress → spo2(bigdata) → sleep(bigdata) → hrv(0..6)
///   → temperature(bigdata) → done.
///
/// **UNVERIFIED (GadgetBridge-derived):** exact reply→stage transitions, per-day iteration counts,
/// and paged terminal conditions. These are the spots to re-check against a real ring.
@MainActor
final class ColmiSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder: ColmiDecoder
    private let encoder = ColmiEncoder()
    private let calendar = Calendar.current

    init(writer: RingCommandWriter?, decoder: ColmiDecoder) {
        self.writer = writer
        self.decoder = decoder
    }

    // MARK: History state machine

    private enum Stage {
        case idle
        case activity
        case heartRate
        case stress
        case spo2
        case sleep
        case hrv
        case temperature
        case done
    }

    private var stage: Stage = .idle
    private var daysAgo = 0
    /// The midnight of the day currently being synced (for HR/stress/HRV sample timestamps).
    private var syncDay = Calendar.current.startOfDay(for: Date())

    static func isHistoryOpcode(_ op: UInt8) -> Bool {
        op == ColmiCommandID.syncActivity
            || op == ColmiCommandID.syncHeartRate
            || op == ColmiCommandID.syncStress
            || op == ColmiCommandID.syncHRV
    }

    func runStartup() {
        // Connect-time settings handshake (no history yet — history is on-demand via startHistorySync).
        writer?.enqueue(Data(encoder.phoneName()))
        writer?.enqueue(Data(encoder.setDateTime()))
        writer?.enqueue(Data(encoder.userPreferences()))
        writer?.enqueue(Data(encoder.battery()))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoHRPref)))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoStressPref)))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoSpo2Pref)))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoHRVPref)))
        writer?.enqueue(Data(encoder.readTempPref()))
        writer?.enqueue(Data(encoder.readGoals()))
        // Enable all-day measurement so the ring actually accumulates data the big-data history can
        // return (without these, SpO2/stress/HRV/temp history come back empty — e.g. spot SpO2 fails).
        writer?.enqueue(Data(encoder.writePref(ColmiCommandID.autoSpo2Pref, enabled: true)))
        writer?.enqueue(Data(encoder.writePref(ColmiCommandID.autoStressPref, enabled: true)))
        writer?.enqueue(Data(encoder.writePref(ColmiCommandID.autoHRVPref, enabled: true)))
        // Kick off a full history sync after the settings handshake.
        startHistorySync()
    }

    private func startHistorySync() {
        daysAgo = 0
        stage = .activity
        // Zero the ring-history activity days we're about to re-sum, so re-syncs stay idempotent.
        Task { await PulseEventBus.shared.publish(.activitySyncReset(sinceDaysAgo: 7)) }
        requestActivity()
        armWatchdog()
    }

    // MARK: History-sync watchdog

    /// If a stage's expected reply never arrives (empty history / non-replying firmware), advance to
    /// the next stage instead of stalling the whole chain. Re-armed on every stage request; cancelled
    /// on each advance and on disconnect/finish.
    private var watchdog: Task<Void, Never>?
    private let watchdogTimeout: UInt64 = 10_000_000_000          // 10s for most stages
    private let activityWatchdogTimeout: UInt64 = 20_000_000_000  // 20s — activity spans 8 days, can be slow

    private func armWatchdog() {
        watchdog?.cancel()
        let expected = stage
        // Activity is the one destructive stage (its days are reset on first bucket), so be extra
        // lenient: give it longer, and re-arm on every bucket so a brief ring pause can't skip days.
        let timeout = (expected == .activity) ? activityWatchdogTimeout : watchdogTimeout
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let self, self.stage == expected else { return }
            self.forceAdvanceStage(from: expected)
        }
    }

    /// Skip a stuck stage and request the next one. Mirrors the normal stage order.
    private func forceAdvanceStage(from stuck: Stage) {
        switch stuck {
        case .activity:
            daysAgo = 0; stage = .heartRate; requestHeartRate()
        case .heartRate:
            stage = .stress; requestStress()
        case .stress:
            stage = .spo2; requestSpo2()
        case .spo2:
            stage = .sleep; requestSleep()
        case .sleep:
            daysAgo = 0; stage = .hrv; requestHRV()
        case .hrv:
            stage = .temperature; requestTemperature()
        case .temperature:
            finishSync()
        case .idle, .done:
            break
        }
        if stage != .done { armWatchdog() }
    }

    /// Generic `RingSyncEngine.handle` — for Colmi, big-data completion and history paging are driven
    /// through the driver's dedicated hooks, so this only needs to react to nothing here.
    func handle(_ event: RingDecodedEvent) {}

    // MARK: Stage requests

    private func requestActivity() {
        syncDay = dayStart(daysAgo)
        writer?.enqueue(Data(encoder.syncActivity(daysAgo: daysAgo)))
    }

    private func requestHeartRate() {
        syncDay = dayStart(daysAgo)
        let unix = Int(syncDay.timeIntervalSince1970)
        writer?.enqueue(Data(encoder.syncHeartRate(fromUnix: unix)))
    }

    private func requestStress() {
        syncDay = calendar.startOfDay(for: Date())
        writer?.enqueue(Data(encoder.syncStress()))
    }

    private func requestHRV() {
        syncDay = dayStart(daysAgo)
        writer?.enqueue(Data(encoder.syncHRV(daysAgo: daysAgo)))
    }

    private func requestSpo2() { writer?.enqueue(encoder.bigDataSpo2()) }
    private func requestSleep() { writer?.enqueue(encoder.bigDataSleep()) }
    private func requestTemperature() { writer?.enqueue(encoder.bigDataTemperature()) }

    private func dayStart(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    // MARK: Driver hooks (called from ColmiDriver.ingest)

    /// Decode a paged history frame for the current sync-day and advance the machine. Returns the
    /// decoded sample events for the bus.
    func handleHistoryFrame(_ data: Data) -> [RingDecodedEvent] {
        let events = decoder.decodeHistory(data, day: syncDay, calendar: calendar)
        advanceAfterPagedFrame(data)
        armWatchdog()   // progress made — reset the stall timer
        return events
    }

    /// A reassembled big-data frame completed (`type` = 0x25/0x27/0x2a). Advance to the next stage.
    func handleBigDataComplete(type: UInt8) {
        switch type {
        case ColmiCommandID.bigDataSpo2:
            stage = .sleep
            requestSleep()
            armWatchdog()
        case ColmiCommandID.bigDataSleep:
            stage = .hrv
            daysAgo = 0
            requestHRV()
            armWatchdog()
        case ColmiCommandID.bigDataTemperature:
            finishSync()
        default:
            break
        }
    }

    /// Observe a realtime-HR reply: maintain the keepalive cadence.
    func observedRealtimeHeartRate() {
        guard realtimeHRActive else { return }
        realtimeHRPacketCount = (realtimeHRPacketCount + 1) % 30
        if realtimeHRPacketCount == 0 {
            writer?.enqueue(Data(encoder.realtimeHeartRateContinue()))
        }
    }

    /// Paged stages (activity/HR/stress/HRV) advance day-by-day, then to the next stage. We treat an
    /// empty marker (0xff) OR the final packet as "this day done".
    private func advanceAfterPagedFrame(_ data: Data) {
        let packetNr = ColmiDecoder.historyPacketNumber(data)
        let isEmpty = packetNr == 0xff
        // For paged HR/stress/HRV, byte[2] in packet 0 carries the total; we conservatively treat any
        // empty/terminal as "advance". A header packet (0) just waits for data packets.
        let dayComplete = isEmpty || isTerminalPacket(data)

        guard dayComplete else { return }

        switch stage {
        case .activity:
            if daysAgo < 7 { daysAgo += 1; requestActivity() }
            else { daysAgo = 0; stage = .heartRate; requestHeartRate() }
        case .heartRate:
            if daysAgo < 7 { daysAgo += 1; requestHeartRate() }
            else { stage = .stress; requestStress() }
        case .stress:
            stage = .spo2; requestSpo2()
        case .hrv:
            if daysAgo < 6 { daysAgo += 1; requestHRV() }
            else { stage = .temperature; requestTemperature() }
        default:
            break
        }
    }

    /// Terminal packet heuristic for paged stages: stress/HRV finish at packet 4 (GadgetBridge);
    /// activity finishes when `currentPacket == totalPackets - 1` (bytes 5/6).
    private func isTerminalPacket(_ data: Data) -> Bool {
        let v = [UInt8](data)
        guard v.count >= 7 else { return false }
        switch v[0] {
        case ColmiCommandID.syncStress, ColmiCommandID.syncHRV:
            return Int(v[1]) == 4
        case ColmiCommandID.syncActivity:
            return Int(v[5]) == Int(v[6]) - 1
        case ColmiCommandID.syncHeartRate:
            // packet 0 carries total in byte[2]; treat last packet as terminal.
            return false   // UNVERIFIED: rely on emptiness / next-day request cadence
        default:
            return false
        }
    }

    private func finishSync() {
        stage = .done
        watchdog?.cancel()
        watchdog = nil
        Task { await PulseEventBus.shared.publish(.syncProgress(stage: "done")) }
    }

    // MARK: Realtime HR keepalive

    private var realtimeHRActive = false
    private var realtimeHRPacketCount = 0

    func startHeartRate() {
        realtimeHRActive = true
        realtimeHRPacketCount = 0
        writer?.enqueue(Data(encoder.realtimeHeartRate(enable: true)))
    }

    func stopHeartRate() {
        // Stop whichever HR mode is active. Spot uses the manual 0x69 stream; workout uses realtime 0x1e.
        if manualHRActive {
            manualHRActive = false
            writer?.enqueue(Data(encoder.manualHeartRate(enable: false)))
        }
        guard realtimeHRActive else { return }
        realtimeHRActive = false
        writer?.enqueue(Data(encoder.realtimeHeartRate(enable: false)))
    }

    /// Spot HR uses the ring's manual single measurement (0x69) — a *continuous* stream that warms up
    /// from 0 to a real bpm. The decoder maps each reply to a sample or `.heartRateComplete`
    /// (no-reading). Realtime 0x1e is reserved for the workout live stream. The coordinator settles
    /// over a short window then calls `stopHeartRate()`, which sends `0x69 02` to stop the stream.
    private var manualHRActive = false
    func measureHeartRateSpot() {
        manualHRActive = true
        writer?.enqueue(Data(encoder.manualHeartRate(enable: true)))
    }

    // Colmi has no instant single-SpO2 reading; SpO2 is an all-day background metric. A "spot" SpO2
    // fetches the all-day history (enabled on connect) so the latest sample surfaces.
    func startSpO2() {
        writer?.enqueue(encoder.bigDataSpo2())
    }

    func stopSpO2() {}

    func findDevice() {
        writer?.enqueue(Data(encoder.findDevice()))
    }

    func setGoal(steps: Int) {
        // Colmi goals (0x21) write — left minimal; PulseLoop persists the goal regardless.
        // UNVERIFIED: exact goal-write payload; using read-back form is unsafe, so we skip the write.
    }
}
