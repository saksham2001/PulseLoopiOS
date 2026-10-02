import Foundation

/// Routes notifications independently of CoreBluetooth, preserving capture-before-decode ordering.
@MainActor
enum RingNotificationDelivery {
    static func receive(_ data: Data, decode: () -> [RingDecodedEvent],
                        publish: (PulseEvent) -> Void, deliver: (RingDecodedEvent) -> Void) {
        publish(.rawPacket(direction: .incoming, data: data,
                           decoded: .unknown(commandId: data.first ?? 0, raw: data)))
        for event in decode() { deliver(event) }
    }

    static func events(for decoded: RingDecodedEvent) -> [PulseEvent] {
        [.decodedPacket(decoded)] + RingEventBridge.events(for: decoded)
    }
}

/// Exactly-once completion with a transport deadline that includes time waiting for BLE backpressure.
/// Protocol response deadlines remain separate and begin only after a successful transport result.
@MainActor
final class RingTrackedWrite {
    private var callback: (@MainActor (Result<Void, Error>) -> Void)?
    private var deadline: Task<Void, Never>?

    init(timeoutNanoseconds: UInt64 = 10_000_000_000,
         timeoutError: Error,
         onTimeout: @escaping @MainActor () -> Void,
         completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        callback = completion
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            guard let self, self.callback != nil else { return }
            // Retire the transport before the callback is allowed to enqueue another command.
            onTimeout()
            self.finish(.failure(timeoutError))
        }
    }

    deinit { deadline?.cancel() }

    func finish(_ result: Result<Void, Error>) {
        guard let callback else { return }
        self.callback = nil
        deadline?.cancel()
        deadline = nil
        callback(result)
    }
}
