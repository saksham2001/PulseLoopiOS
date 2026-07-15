import Foundation

/// The LuckRing history pager. Unlike the YCBT transfer (whose terminal block ends each type), the K6
/// history streams carry **no cursor and no end-of-transfer marker** — the ring just replays every stored
/// record of a type as one or more device-initiated data frames. So this is a simpler, *time-settled*
/// sequential pager: request a type, advance when its data frames stop arriving (a short settle window),
/// or skip it if none arrive at all (a stall timeout — an unsupported type answers with nothing).
///
/// Replays are safe: persistence upserts history by `(kind, timestamp)`, activity by bucket timestamp,
/// and sleep by night, so re-requesting a type it already saw never double-counts. The destructive
/// `cleanData` (207) opcode is deliberately never sent.
@MainActor
final class LuckRingHistorySync {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// The full catalog, in request order. `mixSport` (10 — workout records) is skipped in v1.
    static let catalog: [UInt8] = [
        LuckRingDataType.historySport,   // 5
        LuckRingDataType.sleep,          // 6
        LuckRingDataType.historyHeart,   // 8
        LuckRingDataType.historyO2,      // 40
        LuckRingDataType.historyBP,      // 41
        LuckRingDataType.historyHRV,     // 42
        LuckRingDataType.historyTemp,    // 47
        LuckRingDataType.stressHistory,  // 53
    ]

    /// The post-workout backfill subset — only the logs a session can have added to.
    static let vitalsTypes: [UInt8] = [LuckRingDataType.historyHeart, LuckRingDataType.historyO2]

    private weak var writer: RingCommandWriter?
    private let packetizer = LuckRingPacketizer()
    /// Progress sink. `nil` publishes to the shared bus (the production path); tests inject a spy.
    private let progressSink: ((PulseEvent) -> Void)?

    /// Re-armed on every data frame for the in-flight type; when it fires the type is "settled" and we
    /// advance. Short, because the ring streams a type's frames back-to-back.
    private let settleSeconds: TimeInterval
    /// Fires when a type produces no data at all (unsupported / empty) — skip it. Longer than settle.
    private let stallSeconds: TimeInterval

    private var queue: [UInt8] = []
    private var currentType: UInt8?
    private var seq: UInt8 = 0
    private var settleTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?

    init(
        writer: RingCommandWriter?,
        settleSeconds: TimeInterval = 1.5,
        stallSeconds: TimeInterval = 6,
        progressSink: ((PulseEvent) -> Void)? = nil
    ) {
        self.writer = writer
        self.settleSeconds = settleSeconds
        self.stallSeconds = stallSeconds
        self.progressSink = progressSink
    }

    /// Surface a sync-progress event — to the injected spy in tests, else the shared bus.
    private func publish(_ event: PulseEvent) {
        if let progressSink {
            progressSink(event)
        } else {
            Task { await PulseEventBus.shared.publish(event) }
        }
    }

    var isRunning: Bool { currentType != nil }

    /// Seed the queue and request the first type. A pass already in flight wins — a re-entrant `start`
    /// would abandon the in-flight type mid-stream and land its frames in the wrong bucket.
    func start(types: [UInt8]) {
        guard !isRunning else { return }
        queue = types
        advance()
    }

    /// Abandon any in-flight pass (disconnect / teardown).
    func cancel() {
        cancelTimers()
        currentType = nil
        queue.removeAll()
    }

    /// Called by the driver for every completed device-initiated data frame. A frame for the in-flight
    /// type re-arms the settle window; anything else is ignored.
    func noteReceived(dataType: UInt8) {
        guard let currentType, dataType == currentType else { return }
        stallTask?.cancel(); stallTask = nil
        armSettle()
    }

    // MARK: - Driving the queue

    private func advance() {
        cancelTimers()
        guard !queue.isEmpty else {
            currentType = nil
            publish(.syncProgress(stage: "done"))
            return
        }
        let type = queue.removeFirst()
        currentType = type
        publish(.syncProgress(stage: "Syncing \(Self.label(for: type))…"))
        sendRequest(type)
        armStall()
    }

    private func sendRequest(_ dataType: UInt8) {
        let frame = LuckRingFrame(cmdType: .request, dataType: dataType, payload: [], seq: seq)
        seq &+= 1
        for packet in packetizer.packets(for: frame) {
            writer?.enqueue(packet)
        }
    }

    private func armSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            let nanos = UInt64((self?.settleSeconds ?? 1.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.advance()
        }
    }

    private func armStall() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            let nanos = UInt64((self?.stallSeconds ?? 6) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.advance()   // no data ever arrived for this type — skip it
        }
    }

    private func cancelTimers() {
        settleTask?.cancel(); settleTask = nil
        stallTask?.cancel(); stallTask = nil
    }

    private static func label(for dataType: UInt8) -> String {
        switch dataType {
        case LuckRingDataType.historySport: return "activity"
        case LuckRingDataType.sleep: return "sleep"
        case LuckRingDataType.historyHeart: return "heart rate"
        case LuckRingDataType.historyO2: return "blood oxygen"
        case LuckRingDataType.historyBP: return "blood pressure"
        case LuckRingDataType.historyHRV: return "HRV"
        case LuckRingDataType.historyTemp: return "temperature"
        case LuckRingDataType.stressHistory: return "stress"
        default: return "history"
        }
    }
}
