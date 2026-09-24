import Foundation

/// Serial protocol transactions. A GATT completion and a matching protocol response are separate
/// requirements; neither queue residence nor an unsolicited push counts as a response.
@MainActor
final class RWfitCommandGate {
    nonisolated deinit {}

    private struct Request {
        let id: UUID
        let command: RWfitOutbound
        let needsPayload: Bool
        let completion: (Result<[UInt8], Error>) -> Void
    }

    private weak var writer: RingCommandWriter?
    private let legacyCodec: RWfitLegacyCodec
    private let jlCodec: RWfitJLCodec
    private let responseTimeout: TimeInterval?
    var framing: RWfitFraming = .legacy
    private var queue: [Request] = []
    private var inFlight: Request?
    private var serial = 0
    private var attempts = 0
    private var writeConfirmed = false
    private var received: [UInt8]?
    private var timeoutTask: Task<Void, Never>?
    private var spacingTask: Task<Void, Never>?
    private var attemptID = UUID()

    init(writer: RingCommandWriter?, legacyCodec: RWfitLegacyCodec,
         jlCodec: RWfitJLCodec, responseTimeout: TimeInterval? = nil) {
        self.writer = writer
        self.legacyCodec = legacyCodec
        self.jlCodec = jlCodec
        self.responseTimeout = responseTimeout
    }

    var isIdle: Bool { inFlight == nil && queue.isEmpty }

    /// Fire-and-forget callers still receive failure diagnostics. State machines use execute.
    func submit(_ command: RWfitOutbound) {
        enqueue(command, needsPayload: false) { result in
            if case let .failure(error) = result { rwfitDiagnostic("Command failed", ["reason": error.localizedDescription]) }
        }
    }

    func execute(_ command: RWfitOutbound, needsPayload: Bool = true) async throws -> [UInt8] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(command, id: id, needsPayload: needsPayload) { continuation.resume(with: $0) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    private func enqueue(_ command: RWfitOutbound, id: UUID = UUID(), needsPayload: Bool,
                         completion: @escaping (Result<[UInt8], Error>) -> Void) {
        queue.append(Request(id: id, command: command, needsPayload: needsPayload, completion: completion))
        pump()
    }

    func cancel() {
        timeoutTask?.cancel(); timeoutTask = nil
        spacingTask?.cancel(); spacingTask = nil
        attemptID = UUID()
        let pending = queue + (inFlight.map { [$0] } ?? [])
        queue.removeAll()
        inFlight = nil
        received = nil
        for request in pending { request.completion(.failure(CancellationError())) }
    }

    private func cancel(id: UUID) {
        if inFlight?.id == id { finish(.failure(CancellationError())); return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).completion(.failure(CancellationError()))
        }
    }

    func noteLegacyAck(cmd: UInt8, serial: Int, status: UInt8 = 0) {
        guard case let .legacy(expected, _)? = inFlight?.command,
              expected == cmd, self.serial == serial else { return }
        guard status == 0 else { finish(.failure(RWfitSessionError.invalidResponse)); return }
        if inFlight?.needsPayload == false { receive([]) }
    }

    func noteLegacyFrame(cmd: UInt8, payload: [UInt8]) {
        guard case let .legacy(expected, _)? = inFlight?.command, expected == cmd else { return }
        receive(payload)
    }

    func noteJieliFrame(flag: UInt8, triple: RWfitJLTriple, payload: [UInt8]) {
        guard flag != 0x21, case let .jieli(expected)? = inFlight?.command,
              expected.count >= 3, expected[0] == triple.cmd, expected[1] == triple.key else { return }
        receive(payload)
    }

    func noteJieliAck(triple: RWfitJLTriple) {
        noteJieliFrame(flag: 0x11, triple: triple, payload: triple.bytes)
    }

    private func receive(_ payload: [UInt8]) {
        received = payload
        completeIfReady()
    }

    private func completeIfReady() {
        guard writeConfirmed, let received else { return }
        finish(.success(received))
    }

    private func pump() {
        guard inFlight == nil, spacingTask == nil, !queue.isEmpty else { return }
        inFlight = queue.removeFirst()
        attempts = 0
        send()
    }

    private func send() {
        guard let request = inFlight else { return }
        guard let writer else { finish(.failure(RWfitSessionError.unavailable)); return }
        attempts += 1
        writeConfirmed = false
        received = nil
        let token = UUID()
        attemptID = token
        let frame: Data
        switch request.command {
        case let .legacy(cmd, payload):
            let encoded = legacyCodec.encode(cmd: cmd, payload: payload)
            serial = encoded.serial
            frame = encoded.frame
        case let .jieli(payload): frame = jlCodec.encode(payload: payload)
        }
        writer.enqueueTracked(frame) { [weak self] result in
            guard let self, self.attemptID == token, self.inFlight?.id == request.id else { return }
            switch result {
            case .success:
                self.writeConfirmed = true
                if self.received != nil { self.completeIfReady() } else { self.armTimeout() }
            case let .failure(error): self.finish(.failure(error))
            }
        }
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        let seconds = responseTimeout ?? (framing == .jieli ? 5 : 2)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let maxAttempts: Int
            if case let .jieli(payload)? = self.inFlight?.command, payload.count >= 3, payload[2] == 0x30 {
                // A lost delete reply is ambiguous. Repeating a consume could erase the next page.
                maxAttempts = 1
            } else { maxAttempts = self.framing == .jieli ? 3 : 2 }
            if self.attempts < maxAttempts {
                rwfitDiagnostic("Retrying command", ["attempt": String(self.attempts + 1), "framing": self.framing.rawValue])
                self.send()
            } else { self.finish(.failure(RWfitSessionError.timeout)) }
        }
    }

    private func finish(_ result: Result<[UInt8], Error>) {
        guard let request = inFlight else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        inFlight = nil
        received = nil
        attemptID = UUID()
        let seconds = framing == .jieli ? 0.23 : 0.1
        spacingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.spacingTask = nil
            self.pump()
        }
        request.completion(result)
    }
}
