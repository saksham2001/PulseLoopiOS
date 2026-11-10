import Foundation

/// Response-driven history transfer. Each modern page is consumed only after a durable save;
/// sleep pages are journaled because a single session can span multiple ring pages.
@MainActor
final class RWfitHistorySync {
    nonisolated deinit {}
    static let catalog: [RWfitHistoryType] = [
        .todaySteps, .steps, .sleep, .heartRate, .bloodPressure, .spo2, .temperature,
        .breathe, .hrv, .stress, .bloodSugar,
    ]
    static let vitalsTypes: [RWfitHistoryType] = [.heartRate, .spo2]

    private let gate: RWfitCommandGate
    private let decoder: RWfitDecoder
    private let encoder = RWfitEncoder()
    private let progressSink: ((PulseEvent) -> Void)?
    private let settleSeconds: TimeInterval
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var legacyFrames: [[UInt8]] = []
    private var lastLegacyFrameAt = Date.distantPast
    private var importedRecords = 0
    private var currentType: RWfitHistoryType?
    private var atBoundary = true
    var isPaused = false
    var framing: RWfitFraming = .legacy
    private(set) var isRunning = false
    var deviceIdentifier: String?
    var persist: ([RingDecodedEvent]) throws -> Void = { events in
        guard let save = RWfitHistoryPersistence.save else { throw RWfitSessionError.persistence }
        try save(events)
    }

    init(gate: RWfitCommandGate, clock: RWfitClock = RWfitClock(),
         settleSeconds: TimeInterval = 1.5, stallSeconds: TimeInterval = 6,
         progressSink: ((PulseEvent) -> Void)? = nil) {
        self.gate = gate
        self.decoder = RWfitDecoder(clock: clock)
        self.settleSeconds = settleSeconds
        self.progressSink = progressSink
    }

    private func publish(_ event: PulseEvent) {
        if let progressSink { progressSink(event) }
        else { Task { await PulseEventBus.shared.publish(event) } }
    }

    func start(types: [RWfitHistoryType]) {
        guard !isRunning else { return }
        task = Task { [weak self] in _ = await self?.run(types: types) }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        isRunning = false
        isPaused = false
        atBoundary = true
        currentType = nil
        legacyFrames.removeAll()
    }

    func noteReceived(type: RWfitHistoryType, payload: [UInt8] = []) {
        guard framing == .legacy, currentType == type else { return }
        legacyFrames.append(payload)
        lastLegacyFrameAt = Date()
    }

    func waitUntilPaused() async throws {
        while isRunning && !atBoundary {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func boundary(_ token: UUID) async throws {
        atBoundary = true
        while isPaused {
            try check(token)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try check(token)
        atBoundary = false
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    @discardableResult
    func run(types: [RWfitHistoryType]) async -> RWfitSyncOutcome {
        guard !isRunning else { return .cancelled }
        isRunning = true
        let token = UUID()
        generation = token
        importedRecords = 0
        let outcome: RWfitSyncOutcome
        var failures: [String] = []
        do {
            for type in types {
                guard encoder.historyRequest(framing: framing, type: type) != nil else { continue }
                try await boundary(token)
                currentType = type
                publish(.syncProgress(stage: "Syncing \(type.label)…"))
                do {
                    if framing == .jieli {
                        _ = try await modern(type: type, token: token)
                    } else {
                        _ = try await legacy(type: type, token: token)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failures.append("\(type.label): \(error.localizedDescription)")
                    rwfitDiagnostic("History stream incomplete", ["type": type.label, "reason": error.localizedDescription])
                }
            }
            try check(token)
            if failures.isEmpty { outcome = .success(records: importedRecords) }
            else if importedRecords > 0 { outcome = .partial(records: importedRecords, reason: failures.joined(separator: " ")) }
            else { outcome = .failed(reason: failures.joined(separator: " ")) }
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = importedRecords > 0 ? .partial(records: importedRecords, reason: error.localizedDescription)
                : .failed(reason: error.localizedDescription)
        }
        if generation == token {
            isRunning = false
            atBoundary = true
            currentType = nil
            publish(.rwfitSyncOutcome(outcome))
        }
        return outcome
    }

    /// Mirrors the vendor pager (`blesdk/service/p.java:62-79` HR; `v.java` steps, `t.java` sleep,
    /// `o.java` BP, `n.java` SpO2, `x.java` temperature, `q.java` HRV, `s.java` stress, `m.java`
    /// blood sugar, `w.java:96-118` today's steps): request `05 xx 10`; a page with records is
    /// consumed with `05 xx 30` before the next request; a page without records ends the stream and
    /// is never deleted. Unlike the vendor, which deletes before handing the page to its listeners,
    /// every page is durable (saved, or journaled for sleep) before its delete is sent.
    private func modern(type: RWfitHistoryType, token: UUID) async throws -> Int {
        guard let key = type.jlType, let request = encoder.historyRequest(framing: .jieli, type: type),
              let deviceIdentifier else { throw RWfitSessionError.unavailable }
        var pages = 0
        var saved = 0
        let deadline = Date().addingTimeInterval(180)
        while true {
            try await boundary(token)
            guard Date() < deadline else { throw RWfitSessionError.timeout }
            let payload = try await gate.execute(request)
            try check(token)
            guard payload.count >= 3 else { throw RWfitSessionError.invalidResponse }
            pages += 1
            // A broken device must not keep the UI alive by replaying pages forever.
            guard pages <= 4096 else { throw RWfitSessionError.invalidResponse }
            // `051A`'s first page leads with the 16-byte daily total; one carrying no hourly records
            // is the vendor's empty list too (`x5/b.java:3514-3571`, `w.java:66-92`): import the
            // total, but end the stream without consuming it.
            let terminal = payload.count == 3 || (key == 0x1a && pages == 1 && payload.count == 3 + 16)
            if type == .sleep {
                if !terminal {
                    try RWfitDecoder.validateJieliSleepPage(payload)
                    // A session can span pages, so the raw page is journaled rather than imported;
                    // the journal survives disconnection, failed saves, and app restart.
                    try RWfitHistoryPersistence.stageSleepPage(payload, deviceID: deviceIdentifier, pageID: UUID())
                }
            } else if payload.count > 3 {
                let events = try decoder.validatedJieliHistory(key: key, payload: payload, continuation: pages > 1)
                try persist(events)
                importedRecords += events.count
                saved += events.count
                try check(token)
            }
            if !terminal {
                // Deleting advances the stream. A lost reply fails the type (the gate never repeats
                // a delete); the ring then re-sends at most this already-saved page next sync.
                _ = try await gate.execute(encoder.historyDelete(type: key), needsPayload: false)
                try check(token)
            }
            publish(.syncProgress(stage: "Syncing \(type.label)…"))
            rwfitDiagnostic("History page received", ["type": type.label, "page": String(pages), "bytes": String(payload.count)])
            if terminal { break }
        }
        if type == .sleep {
            let payload = try RWfitHistoryPersistence.sleepPayload(deviceID: deviceIdentifier)
            let events = payload.isEmpty ? [] : try decoder.validatedJieliHistory(key: key, payload: payload)
            try persist(events)
            importedRecords += events.count
            saved = events.count
            try check(token)
            try RWfitHistoryPersistence.clearSleepPages(deviceID: deviceIdentifier)
        }
        rwfitDiagnostic("History saved", ["type": type.label, "records": String(saved)])
        return saved
    }

    private func legacy(type: RWfitHistoryType, token: UUID) async throws -> Int {
        guard let command = type.legacyCommand,
              let request = encoder.historyRequest(framing: .legacy, type: type) else { return 0 }
        legacyFrames.removeAll()
        _ = try await gate.execute(request)
        // Legacy streams push subsequent frames. Silence after an actual response is a settle
        // boundary; silence before any response is a failed transaction, never empty history.
        let deadline = Date().addingTimeInterval(60)
        repeat {
            try await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
            try check(token)
            guard Date() < deadline else { throw RWfitSessionError.timeout }
        } while Date().timeIntervalSince(lastLegacyFrameAt) < settleSeconds
        let events = legacyFrames.flatMap { decoder.decodeLegacy(cmd: command, payload: $0) }
            .filter { if case .commandAck = $0 { return false }; return true }
        guard !events.contains(where: { if case .unknown = $0 { return true }; return false }) else {
            throw RWfitSessionError.invalidResponse
        }
        try persist(events)
        importedRecords += events.count
        return events.count
    }
}
