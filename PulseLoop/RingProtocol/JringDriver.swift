import Foundation
@preconcurrency import CoreBluetooth

/// Driver for the jring. A thin wrapper over the existing `RingUUIDs` / `RingDecoder` / `RingEncoder`
/// so the device-agnostic `RingBLEClient` can drive it identically to any other wearable.
///
/// jring framing is trivial: commands are already fixed 20-byte buffers with no checksum, so
/// `frame(_:)` is the identity. There is a single notify characteristic and GATT battery, and no
/// multi-packet reassembly, so `ingest` is a straight `RingDecoder.decode`.
@MainActor
final class JringDriver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    /// One clock per connection, shared by the decoder and the sync engine: the engine latches the
    /// UTC offset when it sends 0x01, and the decoder subtracts that same offset off every
    /// ring-stamped history timestamp. See `JringClock`.
    private let clock = JringClock()
    private let decoder: RingDecoder

    init(writer: RingCommandWriter) {
        self.writer = writer
        self.decoder = RingDecoder(clock: clock)
    }

    // MARK: BLE topology
    let serviceUUIDs: [CBUUID] = [CBUUID(string: RingUUIDs.service)]
    let writeUUID = CBUUID(string: RingUUIDs.write)
    let notifyUUIDs: [CBUUID] = [CBUUID(string: RingUUIDs.notify)]
    let batteryServiceUUID: CBUUID? = CBUUID(string: "180F")
    let batteryCharUUID: CBUUID? = CBUUID(string: RingUUIDs.battery)

    // MARK: Framing / decoding
    func frame(_ command: Data) -> Data { command }   // already 20 bytes, no checksum

    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        decoder.decodeAll(data)
    }

    func makeSyncEngine() -> RingSyncEngine {
        JringSyncEngine(writer: writer, clock: clock)
    }
}
