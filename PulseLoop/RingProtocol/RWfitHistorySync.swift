import Foundation

/// Response-driven history transfer. Modern history is consumed only after a durable save;
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

    private func modern(type: RWfitHistoryType, token: UUID) async throws -> Int {
        guard let key = type.jlType, let request = encoder.historyRequest(framing: .jieli, type: type),
              let deviceIdentifier else { throw RWfitSessionError.unavailable }
        var combined = RWfitJLTriple.historySync(type: key).bytes
        var pages = 0
        let deadline = Date().addingTimeInterval(180)
        while true {
            try await boundary(token)
            guard Date() < deadline else { throw RWfitSessionError.timeout }
            let payload = try await gate.execute(request)
            try check(token)
            guard payload.count >= 3 else { throw RWfitSessionError.invalidResponse }
            pages += 1
            // A broken device must not keep the UI alive by replaying pages forever.
            guard pages <= 4096, combined.count <= 8 * 1024 * 1024 else { throw RWfitSessionError.invalidResponse }
            let terminal = payload.count == 3
            if type == .sleep {
                if !terminal {
                    try RWfitDecoder.validateJieliSleepPage(payload)
                    try RWfitHistoryPersistence.stageSleepPage(payload, deviceID: deviceIdentifier, pageID: UUID())
                }
                // Deleting advances this stream. The raw page is durable even if the session has
                // not ended yet; the journal survives disconnection, failed saves, and app restart.
                _ = try await gate.execute(encoder.historyDelete(type: key), needsPayload: false)
                try check(token)
            } else if !terminal {
                _ = try decoder.validatedJieliHistory(key: key, payload: payload)
                combined.append(contentsOf: payload.dropFirst(3))
            }
            publish(.syncProgress(stage: "Syncing \(type.label)…"))
            rwfitDiagnostic("History page received", ["type": type.label, "page": String(pages), "bytes": String(payload.count)])
            if terminal { break }
        }
        let payload = type == .sleep ? try RWfitHistoryPersistence.sleepPayload(deviceID: deviceIdentifier) : combined
        let events = payload.isEmpty ? [] : try decoder.validatedJieliHistory(key: key, payload: payload)
        try persist(events)
        importedRecords += events.count
        try check(token)
        if type == .sleep {
            try RWfitHistoryPersistence.clearSleepPages(deviceID: deviceIdentifier)
        } else {
            _ = try await gate.execute(encoder.historyDelete(type: key), needsPayload: false)
        }
        rwfitDiagnostic("History saved", ["type": type.label, "records": String(events.count)])
        return events.count
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
