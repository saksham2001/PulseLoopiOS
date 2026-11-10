import Foundation
import os

private let transferLog = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "YCBTHistoryTransfer")

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
/// **Erase phase.** Like SmartHealth (`DataSyncUtils.setDBListener$lambda$4`, `DataSyncUtils.java:251-276`),
/// a type whose log was read successfully is then erased from the ring with `05 <deleteKey> {02}`, so the
/// next sync is small instead of a replay of the whole log. The vendor deletes once its database insert
/// succeeds; our equivalent is `RingCommandWriter.commitDeliveredHistory`, a throwing save of everything
/// delivered so far. The rules, each of which exists because the delete is irreversible:
///
///   • A type is *eligible* only when its transfer ended in a CRC-accepted terminal block **and** carried
///     at least one record. A no-data header, a rejection, a CRC failure or a watchdog skip earns nothing
///     — the same cases the vendor's `code == 0 && result != null` check excludes.
///   • Deletes go out only **after the last query** — where the vendor's land too: `syncData` queues every
///     query up front (`DataSyncUtils.java:99-143`) and each delete is issued later, from that type's
///     insert callback, onto the tail of the SDK's serial queue (`deleteWatchesHistoryData`, :356-372) —
///     and only after the commit completed `true`. `false` (a failed save, a missing persistence
///     subscriber, the barrier timeout) sends none.
///   • One at a time, in completion order: write, wait for the reply on that key (or a 1-byte error, or
///     the watchdog), move on. No retry — the vendor ignores the result too, and a type left undeleted
///     simply replays next sync, which every history sink already upserts.
///   • Nothing is erased before the ring's `02 01` capability bitmap has arrived on this connection. The
///     driver drops samples for sensors it doesn't yet believe the ring has, so a type decoded on the
///     baseline set may have been saved with fields missing; the bitmap re-queues those types (see
///     `YCBTSyncEngine.applySupportFunctions`), and a re-queued type loses its eligibility until the
///     re-run completes. The vendor never syncs without the bitmap at all.
///   • `.historySyncFinished` waits for the erase phase, so a `start` can't interleave a query with it,
///     and `cancel()` (disconnect) abandons it — a commit verdict from a dead link is ignored.
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
        /// Every query is done; waiting for `commitDeliveredHistory` to prove the walk is on disk.
        case awaitingCommit
        /// `05 <deleteKey> {02}` written for this type; waiting for the ring's reply.
        case deleting(YCBTHistoryType)

        /// The type being *fetched*. `nil` while committing or erasing, so no query-phase frame can be
        /// charged to anything then.
        var type: YCBTHistoryType? {
            switch self {
            case .idle, .awaitingCommit, .deleting: return nil
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
    /// What the header promised, kept for the terminal block to be checked against. See `handleTerminal`.
    private var expectedPackets = 0
    private var expectedBytes = 0
    /// Types the firmware answered `0xFB`/`0xFC` for — never asked again this session. Deliberately
    /// survives `cancel()`: an auto-reconnect keeps this driver, and a rejection is a firmware fact.
    private var unsupported: Set<UInt8> = []
    /// Types the watchdog skipped **without the ring sending anything at all** — no header, no frame on
    /// the type's keys — not asked again until the link drops.
    ///
    /// An R99 never answers the dedicated SpO₂ log (`05 1a`): no header, no `0xFB`/`0xFC`, nothing, in
    /// ~45 syncs. Without this, every 30-minute pass and every post-workout vitals backfill sat through
    /// the full inactivity watchdog for it. No `02 01` bit names that log (SmartHealth never queries it),
    /// so the ring's own silence is the only signal there is.
    ///
    /// Unlike `unsupported` this is cleared by `cancel()`. A silence is evidence, not a verdict: a fresh
    /// link — possibly to a different ring of the same family on the same driver — asks again, and a ring
    /// that does keep the log loses at most one connection's worth of reads (never data: a skipped type
    /// is never erased, so the next connection reads it in full).
    private var silent: Set<UInt8> = []
    /// Only the dedicated SpO₂ (`05 1a`) and temperature (`05 1e`) logs — the two SmartHealth itself never
    /// queries (`DataSyncUtils.syncData`, `DataSyncUtils.java:99-143`) — can be remembered as silent. A core
    /// log the vendor reads every sync (sport, sleep, heart, All, …) that misses one reply is retried on
    /// the next pass: rings stay connected for days, and skipping one until a reconnect would let its
    /// log fill up unread and un-erased — the very failure that froze the R99's automatic SpO₂.
    private static let mayGoSilent: Set<UInt8> = [YCBTHistoryType.spo2.queryKey, YCBTHistoryType.temperature.queryKey]
    /// Whether the ring has sent a header or a data frame for the in-flight type. Reset per type by
    /// `advance()`, not by the CRC retry — a type that earned a retry was plainly answered.
    private var currentTypeAnswered = false

    /// Types eligible for the erase phase, in completion order: CRC-accepted, ≥1 record, not re-queued
    /// since. See the type doc.
    private var pendingDeletes: [YCBTHistoryType] = []
    /// Whether the ring's `02 01` bitmap has arrived on this connection — the precondition for any erase.
    private var capabilityBitmapReceived = false
    /// Bumped by `cancel()`. The commit verdict is asynchronous; one captured on a link that has since
    /// dropped must not authorize an erase on the next.
    private var generation = 0

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

    /// True while a type is being requested or received, or the erase phase that follows the last one is
    /// running — the walk isn't over until its deletes are.
    var isActive: Bool { state != .idle }

    /// Seed the queue and request the first type. Types the ring already rejected this session, or left
    /// unanswered on this connection, are skipped.
    ///
    /// **A transfer already in flight wins.** There are now three callers (the connect handshake, the
    /// post-workout vitals backfill, the 30-minute periodic pass), and a second `start` would abandon the
    /// in-flight type mid-dump: the ring keeps streaming its data frames regardless, so they would land in
    /// the *new* type's buffer and fail its terminal CRC. Deferring costs nothing — the watchdog
    /// guarantees an in-flight transfer always completes or is abandoned, and the erase phase is bounded
    /// by the commit timeout plus one watchdog per delete. The erase phase counts as in flight: a query
    /// interleaved with a delete could be answered out of order against either.
    func start(types: [YCBTHistoryType]) {
        guard !isActive else { return }
        queue = types.filter(isWorthAsking)
        publishOutOfBand(advance())
    }

    private func isWorthAsking(_ type: YCBTHistoryType) -> Bool {
        !unsupported.contains(type.queryKey) && !silent.contains(type.queryKey)
    }

    /// Add types to the queue **without** disturbing whatever is in flight.
    ///
    /// `start` deliberately refuses while a transfer is running, which is right for a second full pass
    /// but wrong for the one case this exists for: the ring's `02 01` capability bitmap arrives *during*
    /// the startup history walk, and the types it unlocks would otherwise wait for the next sync. Appending
    /// leaves the current type's buffer and terminal untouched — the new keys are simply asked for when
    /// the queue reaches them.
    ///
    /// Duplicates are dropped rather than re-queued: asking twice would re-dump a log we already hold and
    /// re-upsert every record in it. Idle is handled too, so a late bitmap after a finished walk still
    /// pulls its types.
    ///
    /// A re-queued type loses any pending erase: it is re-fetched *because* the first read is suspect
    /// (decoded before the bitmap unlocked some of its fields), so only the re-run can earn it back. While
    /// the erase phase is running the additions simply wait; the phase hands over to them when it ends.
    func append(types: [YCBTHistoryType]) {
        let additions = types.filter { type in
            isWorthAsking(type)
                && !queue.contains(type)
                && state.type != type
        }
        guard !additions.isEmpty else { return }
        pendingDeletes.removeAll { additions.contains($0) }
        queue.append(contentsOf: additions)
        guard !isActive else { return }
        publishOutOfBand(advance())
    }

    /// Abandon any in-flight transfer (disconnect / teardown). Also forgets the erase phase, the bitmap
    /// and the silent types: all belong to one link, and a commit verdict still in flight is orphaned by
    /// `generation`. `unsupported` is kept (see its doc).
    func cancel() {
        cancelWatchdog()
        state = .idle
        queue.removeAll()
        buffer.removeAll()
        pendingDeletes.removeAll()
        silent.removeAll()
        capabilityBitmapReceived = false
        generation &+= 1
    }

    /// The driver saw this connection's `02 01` reply, so the capability set its sample filter uses is
    /// final. Until then nothing is erased (see the type doc).
    func noteCapabilityBitmapReceived() {
        capabilityBitmapReceived = true
    }

    /// Request the next type, or move to the erase phase when the queue drains. Returns the events the
    /// caller should surface (only ever the completion signal — progress comes from the header).
    @discardableResult
    private func advance() -> [RingDecodedEvent] {
        cancelWatchdog()
        buffer.removeAll(keepingCapacity: false)
        bufferCap = Self.defaultBufferCap
        retriedCurrentType = false
        currentTypeAnswered = false
        expectedPackets = 0
        expectedBytes = 0
        guard !queue.isEmpty else { return beginErasePhase() }
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
        if case let .deleting(type) = state { return handleDeleteReply(type, cmd: cmd, payload: payload) }
        guard let type = state.type else { return [] }

        // Only a frame on one of *this* type's keys can speak for it. The error check below used to run
        // on any Health frame, so a stray rejection — a late reply to a delete the watchdog gave up on —
        // would have advanced past a type mid-dump.
        guard cmd == type.queryKey || cmd == type.ackKey || cmd == YCBTHealth.terminalBlock else { return [] }

        // A 1-byte 0xFB…0xFF payload is a rejection, not data — check before anything reads offsets.
        if let error = YCBTFrameError.detect(in: payload) {
            if error.isPermanent { unsupported.insert(type.queryKey) }
            return advance()
        }

        // A terminal is deliberately not evidence of an answer: one that arrives before this type's header
        // or data is the previous type's, late (see `handleTerminal`), and says nothing about this one.
        switch cmd {
        case type.queryKey:
            currentTypeAnswered = true
            return handleHeader(type, payload: payload)
        case type.ackKey:
            currentTypeAnswered = true
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
        expectedPackets = YCBTBytes.u16(payload, 2)
        expectedBytes = totalBytes
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

        // Count check before CRC, because the CRC alone does not catch a *short* buffer. A dropped data
        // frame leaves us with fewer bytes than the ring sent, and the terminal's CRC was computed over
        // what the ring sent — so it fails, which looks the same as corruption but isn't. Worse is the
        // reverse: a transfer whose last frames never arrived can still terminate with a buffer whose CRC
        // happens to be checked over exactly what we hold if the ring recomputed it. Cross-checking the
        // packet and byte counts against *both* the header's promise and the buffer we actually built
        // turns "silently short" into a NAK and a retry.
        let packets = YCBTBytes.u16(payload, 0)
        let bytes = YCBTBytes.u16(payload, 2)
        let matchesHeader = packets == expectedPackets && bytes == expectedBytes
        let matchesBuffer = bytes == buffer.count
        guard matchesHeader, matchesBuffer else {
            writer?.enqueue(Data(YCBTHealthCommand.historyBlockAck(status: YCBTHealth.ackCrcFailure)))
            return retryOrSkip(type)
        }

        let expected = UInt16(YCBTBytes.u16(payload, 4))
        let matches = YCBTFrame.crc16(buffer) == expected

        writer?.enqueue(Data(YCBTHealthCommand.historyBlockAck(
            status: matches ? YCBTHealth.ackAccepted : YCBTHealth.ackCrcFailure
        )))

        guard matches else { return retryOrSkip(type) }
        let records = YCBTHealthRecords.decode(buffer, type: type)
        // Eligibility is judged on what the ring *sent*, not on what decoded: a log of unworn `hr == 0`
        // samples is still a log the vendor would erase, and keeping it only replays junk.
        if buffer.count >= (type.recordStride ?? 1), type.deleteKey != nil, !pendingDeletes.contains(type) {
            pendingDeletes.append(type)
        }
        return records + advance()
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

    // MARK: - Erase phase

    /// The queue has drained. With nothing eligible — or no bitmap yet — the walk is simply finished.
    /// Otherwise ask for the durable commit.
    ///
    /// The commit request is deferred to the next main-actor turn on purpose. This usually runs inside
    /// `handle`, whose return value carries the *last* type's decoded records back to the driver; they
    /// are published only after `handle` returns. Requesting the barrier synchronously would publish it
    /// ahead of them, and the commit would vouch for a save that didn't include them.
    private func beginErasePhase() -> [RingDecodedEvent] {
        guard capabilityBitmapReceived, !pendingDeletes.isEmpty, writer != nil else {
            pendingDeletes.removeAll()
            state = .idle
            return [.historySyncFinished]
        }
        state = .awaitingCommit
        let generation = self.generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation, self.state == .awaitingCommit else { return }
            guard let writer = self.writer else { return self.resolveCommit(false, generation: generation) }
            writer.commitDeliveredHistory { [weak self] committed in
                self?.resolveCommit(committed, generation: generation)
            }
        }
        return []
    }

    /// `true` releases the deletes; anything else drops them — the ring keeps its data and the next sync
    /// re-imports it. A verdict from a cancelled link (`generation` moved on) is ignored outright.
    private func resolveCommit(_ committed: Bool, generation: Int) {
        guard generation == self.generation, state == .awaitingCommit else { return }
        if !committed { pendingDeletes.removeAll() }
        publishOutOfBand(sendNextDelete())
    }

    /// Write the next eligible delete, or — when none remain — hand back to the queue: types appended
    /// during the phase (a late bitmap) are fetched now, and an empty queue finishes the walk.
    private func sendNextDelete() -> [RingDecodedEvent] {
        cancelWatchdog()
        while !pendingDeletes.isEmpty {
            let type = pendingDeletes.removeFirst()
            guard let command = YCBTHealthCommand.historyDelete(type) else { continue }
            state = .deleting(type)
            writer?.enqueue(Data(command))
            armDeleteWatchdog(for: type)
            return []
        }
        state = .idle
        return advance()
    }

    /// The ring answers a delete on the same key (`0x40…0x52` = done) or with a 1-byte `0xFB…0xFF`
    /// error. Either way the type is finished with: the vendor only logs the result
    /// (`DataSyncUtils.deleteWatchesHistoryData$lambda$5/6`), and an undeleted log just replays next sync.
    /// Frames on any other key are not ours to interpret.
    private func handleDeleteReply(_ type: YCBTHistoryType, cmd: UInt8, payload: [UInt8]) -> [RingDecodedEvent] {
        guard cmd == type.deleteKey else { return [] }
        if let error = YCBTFrameError.detect(in: payload) {
            transferLog.info("Delete of \(type.label, privacy: .public) rejected: 0x\(String(error.rawValue, radix: 16), privacy: .public)")
        } else {
            transferLog.info("Deleted \(type.label, privacy: .public) history from the ring")
        }
        return sendNextDelete()
    }

    /// A ring that never answers a delete must not hold the walk open. No retry: the type is simply left
    /// for the next sync to read (and erase) again.
    private func armDeleteWatchdog(for type: YCBTHistoryType) {
        watchdog?.cancel()
        let delay = inactivitySeconds
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .deleting(type) else { return }
            transferLog.info("Delete of \(type.label, privacy: .public) unanswered; moving on")
            self.publishOutOfBand(self.sendNextDelete())
        }
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
    ///
    /// A type the ring never answered at all is also remembered as `silent` for the rest of this
    /// connection. One that answered and *then* stalled is not: that is a transfer gone wrong, and the
    /// next pass should try it again.
    private func armWatchdog(for type: YCBTHistoryType) {
        watchdog?.cancel()
        let deadline = typeDeadline ?? Date().addingTimeInterval(absoluteCapSeconds)
        let fireAt = min(Date().addingTimeInterval(inactivitySeconds), deadline)
        let delay = max(0, fireAt.timeIntervalSinceNow)
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.type == type else { return }
            if !self.currentTypeAnswered, Self.mayGoSilent.contains(type.queryKey) {
                self.silent.insert(type.queryKey)
                transferLog.info("\(type.label, privacy: .public) history unanswered; not asked again on this connection")
            }
            self.publishOutOfBand(self.advance())
        }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        typeDeadline = nil
    }

    /// Set by `YCBTSyncEngine`, which needs to see a completion it did not cause. `handle`'s events reach
    /// the engine via the driver's return value; `start`, `append` and the watchdog have no such channel,
    /// and the engine acts on `.historySyncFinished` (it re-issues the live-status subscription), so a
    /// walk that the watchdog ended would otherwise leave today's steps stale until the next sync.
    var onOutOfBandEvents: (([RingDecodedEvent]) -> Void)?

    /// `handle` returns its events to the driver, which publishes them. `start`, the watchdogs and the
    /// commit verdict have no such return channel, so the one event they can produce — completion — is
    /// surfaced here.
    private func publishOutOfBand(_ events: [RingDecodedEvent]) {
        guard events.contains(where: { if case .historySyncFinished = $0 { return true } else { return false } })
        else { return }
        onOutOfBandEvents?(events)
        Task { await PulseEventBus.shared.publish(.syncProgress(stage: "done")) }
    }
}
