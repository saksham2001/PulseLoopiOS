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
        // Kick off a full history sync after the settings handshake.
        startHistorySync()
    }

    private func startHistorySync() {
        daysAgo = 0
        stage = .activity
        requestActivity()
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
        return events
    }

    /// A reassembled big-data frame completed (`type` = 0x25/0x27/0x2a). Advance to the next stage.
    func handleBigDataComplete(type: UInt8) {
        switch type {
        case ColmiCommandID.bigDataSpo2:
            stage = .sleep
            requestSleep()
        case ColmiCommandID.bigDataSleep:
            stage = .hrv
            daysAgo = 0
            requestHRV()
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
        guard realtimeHRActive else { return }
        realtimeHRActive = false
        writer?.enqueue(Data(encoder.realtimeHeartRate(enable: false)))
    }

    // Colmi all-day SpO2 is a background setting, not an on-demand stream; a manual single HR is the
    // closest analog for a one-shot vitals read. SpO2 start/stop map to enabling the pref + a sync.
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
