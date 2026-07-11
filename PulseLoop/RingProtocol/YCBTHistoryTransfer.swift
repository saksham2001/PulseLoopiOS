import Foundation

/// The YCBT history state machine — protocol-driven, not timer-driven.
///
/// Per type the ring answers a `05 <queryKey>` request with:
///   header  `05 <queryKey>`  payload ≥ 10 → `[recordCount:u16][totalPackets:u32][totalBytes:u32]`
///                            payload ≤  9 → nothing stored for this type
///   data    `05 <ackKey>`    N frames whose payloads **concatenate** into one buffer (records straddle
///                            frame boundaries, which is why nothing may be decoded per-frame)
///   terminal `05 80`         `[totalPackets:u16][totalBytes:u16][crc16:u16]` over that buffer
///
/// and then **waits for an ACK** (`05 80 {00}` accepted / `{04}` CRC failure) before releasing the next
/// type. `YCBTClientImpl.packetHealthHandle` sends the ACK *before* it parses; we do the same, so a
/// slow decode can't stall the ring.
///
/// **Completion is the ring's terminal block, never a timer.** The watchdog below is a *safety net
/// only*: it never ACKs (an ACK without a verified terminal block claims data we don't hold) and is
/// never a completion signal — it just abandons a type the ring has gone silent on.
///
/// Full spec, with a byte-level example: `docs/YCBT-Protocol.md` §4.
@MainActor
final class YCBTHistoryTransfer {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private enum State: Equatable {
        case idle
        /// Query written; waiting for the header (or a "no data" / error reply).
        case requestSent(YCBTHistoryType)
        /// Header seen; accumulating data frames until the terminal block.
        case receiving(YCBTHistoryType)

        var type: YCBTHistoryType? {
            switch self {
            case .idle: return nil
            case let .requestSent(type), let .receiving(type): return type
            }
        }
    }

    private weak var writer: RingCommandWriter?

    private var state: State = .idle
    private var queue: [YCBTHistoryType] = []
    private var buffer: [UInt8] = []
    /// A CRC mismatch buys the type exactly one re-request; a second failure gives up on it.
    private var retriedCurrentType = false
    /// Types the firmware answered `0xFB`/`0xFC` for — never asked again this session.
    private var unsupported: Set<UInt8> = []

    /// Ceiling on the reassembled buffer. Sized from the header when we have one so a desynced stream
    /// (data frames with no header, or a type that never terminates) can't grow it without bound.
    private static let defaultBufferCap = 64 * 1024
    private var bufferCap = YCBTHistoryTransfer.defaultBufferCap

    /// Timeouts are injectable purely so tests can exercise the stall path without sleeping for 10s.
    init(
        writer: RingCommandWriter?,
        inactivitySeconds: TimeInterval = 10,
        absoluteCapSeconds: TimeInterval = 30
    ) {
        self.writer = writer
        self.inactivitySeconds = inactivitySeconds
        self.absoluteCapSeconds = absoluteCapSeconds
    }

    // MARK: - Driving the queue

    /// True while a type is being requested or received.
    var isActive: Bool { state != .idle }

    /// Seed the queue and request the first type. Types the ring already rejected this session are
    /// skipped.
    ///
    /// **A transfer already in flight wins.** There are now three callers (the connect handshake, the
    /// post-workout vitals backfill, the 30-minute periodic pass), and a second `start` would abandon the
    /// in-flight type mid-dump: the ring keeps streaming its data frames regardless, so they would land in
    /// the *new* type's buffer and fail its terminal CRC. Deferring costs nothing — the watchdog
    /// guarantees an in-flight transfer always completes or is abandoned.
    func start(types: [YCBTHistoryType]) {
        guard !isActive else { return }
        queue = types.filter { !unsupported.contains($0.queryKey) }
        publishOutOfBand(advance())
    }

    /// Abandon any in-flight transfer (disconnect / teardown).
    func cancel() {
        cancelWatchdog()
        state = .idle
        queue.removeAll()
        buffer.removeAll()
    }

    /// Request the next type, or report completion when the queue drains. Returns the events the
    /// caller should surface (only ever the completion signal — progress comes from the header).
    @discardableResult
    private func advance() -> [RingDecodedEvent] {
        cancelWatchdog()
        buffer.removeAll(keepingCapacity: false)
        bufferCap = Self.defaultBufferCap
        retriedCurrentType = false
        guard !queue.isEmpty else {
            state = .idle
            return [.historySyncFinished]
        }
        sendQuery(queue.removeFirst())
        return []
    }

    /// Write `05 <queryKey>` and arm the stall watchdog. Also used for the single CRC retry, so it must
    /// not touch `retriedCurrentType`.
    private func sendQuery(_ type: YCBTHistoryType) {
        state = .requestSent(type)
        typeDeadline = Date().addingTimeInterval(absoluteCapSeconds)
        writer?.enqueue(Data(YCBTHealthCommand.historyRequest(type)))
        armWatchdog(for: type)
    }

    // MARK: - Inbound

    /// Feed every validated Health-group (`type == 0x05`) frame here. Frames arriving while idle are
    /// ignored — the ring occasionally trails a stray block after we've moved on.
    func handle(cmd: UInt8, payload: [UInt8]) -> [RingDecodedEvent] {
        guard let type = state.type else { return [] }

        // A 1-byte 0xFB…0xFF payload is a rejection, not data — check before anything reads offsets.
        if let error = YCBTFrameError.detect(in: payload) {
            if error.isPermanent { unsupported.insert(type.queryKey) }
            return advance()
        }

        switch cmd {
        case type.queryKey:
            return handleHeader(type, payload: payload)
        case type.ackKey:
            appendData(payload)
            armWatchdog(for: type)
            return []
        case YCBTHealth.terminalBlock:
            return handleTerminal(type, payload: payload)
        default:
            return []   // a frame for some other type — not ours to interpret
        }
    }

    /// Header: `[recordCount:u16][totalPackets:u32][totalBytes:u32]`. A payload of 9 bytes or fewer is
    /// the SDK's "no stored data" reply — there is no transfer to ACK, so we simply move on.
    private func handleHeader(_ type: YCBTHistoryType, payload: [UInt8]) -> [RingDecodedEvent] {
        guard payload.count >= YCBTHealth.headerPayloadLength else { return advance() }
        let totalBytes = YCBTBytes.u32(payload, 6)
        buffer.removeAll(keepingCapacity: true)
        bufferCap = max(totalBytes, Self.defaultBufferCap)
        state = .receiving(type)
        armWatchdog(for: type)
        return [.historySyncProgress(stage: "Syncing \(type.label)…")]
    }

    /// Data frames concatenate. We accept them even if the header was missed (a lost first
    /// notification): the terminal CRC is the real integrity check, and it will fail us into the retry
    /// path rather than persisting a misaligned buffer.
    private func appendData(_ payload: [UInt8]) {
        guard buffer.count + payload.count <= bufferCap else { return }
        buffer.append(contentsOf: payload)
    }

    /// Terminal: verify the CRC16 over everything we accumulated, ACK, then decode. Order matters — the
    /// SDK ACKs first, and the ring gates the next type on it.
    ///
    /// A `05 80` carries no type identity, so it is always attributed to whatever type is current — and
    /// after a watchdog skip (or the CRC retry), the *previous* type's late terminal lands here. That is
    /// not inert: its CRC can't match a buffer it wasn't computed over, so it would NACK the ring into
    /// re-dumping a type we didn't lose *and* spend the current type's one retry. A terminal that arrives
    /// before this type's header, with nothing accumulated, is therefore stale by construction — a
    /// genuinely empty type never reaches a terminal at all, because the SDK signals "no data" with the
    /// ≤9-byte header that `handleHeader` already advances on.
    private func handleTerminal(_ type: YCBTHistoryType, payload: [UInt8]) -> [RingDecodedEvent] {
        if case .requestSent = state, buffer.isEmpty { return [] }
        guard payload.count >= YCBTHealth.terminalPayloadLength else { return advance() }
        let expected = UInt16(YCBTBytes.u16(payload, 4))
        let matches = YCBTFrame.crc16(buffer) == expected

        writer?.enqueue(Data(YCBTHealthCommand.historyBlockAck(
            status: matches ? YCBTHealth.ackAccepted : YCBTHealth.ackCrcFailure
        )))

        guard matches else { return retryOrSkip(type) }
        return YCBTHealthRecords.decode(buffer, type: type) + advance()
    }

    /// One re-request per type on a corrupt transfer; if that also fails, drop the type rather than
    /// looping the ring forever.
    private func retryOrSkip(_ type: YCBTHistoryType) -> [RingDecodedEvent] {
        guard !retriedCurrentType else { return advance() }
        retriedCurrentType = true
        buffer.removeAll(keepingCapacity: true)
        sendQuery(type)
        return []
    }

    // MARK: - Stall watchdog (safety net)

    /// Inactivity window, re-armed by every history frame for the in-flight type.
    private let inactivitySeconds: TimeInterval
    /// Hard ceiling per type, so a ring that dribbles frames forever still can't wedge the queue.
    private let absoluteCapSeconds: TimeInterval

    private var watchdog: Task<Void, Never>?
    private var typeDeadline: Date?

    /// Fires only on silence: the type is declared stalled and skipped. It must never ACK (an ACK
    /// without a verified terminal block tells the ring we accepted data we don't have) and must never
    /// stand in for completion.
    private func armWatchdog(for type: YCBTHistoryType) {
        watchdog?.cancel()
        let deadline = typeDeadline ?? Date().addingTimeInterval(absoluteCapSeconds)
        let fireAt = min(Date().addingTimeInterval(inactivitySeconds), deadline)
        let delay = max(0, fireAt.timeIntervalSinceNow)
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.type == type else { return }
            self.publishOutOfBand(self.advance())
        }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        typeDeadline = nil
    }

    /// `handle` returns its events to the driver, which publishes them. `start` and the watchdog have no
    /// such return channel, so the one event they can produce — completion — is published here.
    private func publishOutOfBand(_ events: [RingDecodedEvent]) {
        guard events.contains(where: { if case .historySyncFinished = $0 { return true } else { return false } })
        else { return }
        Task { await PulseEventBus.shared.publish(.syncProgress(stage: "done")) }
    }
}
