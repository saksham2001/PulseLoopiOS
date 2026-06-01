import Foundation
@preconcurrency import CoreBluetooth

/// CoreBluetooth client for the SMART_RING.
///
/// Scans for the ring, connects to service `000056ff…`, writes 20-byte commands to
/// `000033f3…`, subscribes to notifications on `000033f4…`, and reads battery from
/// `00002a19…`. Every outgoing and incoming frame is published as a `PulseEvent.rawPacket`
/// (so the Debug feed and `RawPacketRow` table capture all traffic), and decoded
/// notifications are fanned out to typed `PulseEvent`s via `RingEventBridge`.
///
/// The central manager is created with `queue: nil`, so all delegate callbacks arrive on the
/// main thread; the class is `@MainActor` and the delegate methods use
/// `MainActor.assumeIsolated` to satisfy the compiler while staying on that thread. Writes are
/// serialized (one outstanding `withResponse` write at a time) to mirror the Python client's
/// write lock and keep the ring's framed responses in order.
///
/// The app runs fine with no ring present: nothing happens until `startScanning()`/`connect`
/// is called, and `centralManagerDidUpdateState` simply parks at `.idle` when Bluetooth is off.
@MainActor
@Observable
final class RingBLEClient: NSObject {
    struct DiscoveredRing: Identifiable, Equatable {
        let id: UUID          // CBPeripheral.identifier
        let name: String
        let rssi: Int
        /// True when the advertisement matches the SMART_RING name / service / manufacturer
        /// signature. Non-ring named peripherals are still listed (sorted below) so the user
        /// can always find their device even if its advertisement is sparse.
        let isLikelyRing: Bool
    }

    // MARK: Observable state (read by SwiftUI)
    private(set) var state: RingConnectionState = .idle
    private(set) var discovered: [DiscoveredRing] = []
    private(set) var batteryPercent: Int?
    private(set) var isBluetoothReady = false
    private(set) var lastError: String?

    /// Invoked once, on the main actor, after a connection is fully established (notifications
    /// enabled). The sync coordinator hooks this to run the startup command sequence.
    var onConnected: (@MainActor () -> Void)?

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Strong references to scanned peripherals, keyed by identifier. Required because
    /// `connect(_:)` needs the actual `CBPeripheral` object — `retrievePeripherals` returns
    /// nothing for a device the system has never connected to before.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?

    // MARK: Write serialization
    private var writeQueue: [Data] = []
    private var writeInFlight = false

    /// When true, an unexpected disconnect triggers an automatic reconnect attempt.
    private var autoReconnect = true

    private let decoder = RingDecoder()

    private let serviceCBUUID = CBUUID(string: RingUUIDs.service)
    private let writeCBUUID = CBUUID(string: RingUUIDs.write)
    private let notifyCBUUID = CBUUID(string: RingUUIDs.notify)
    private let batteryServiceCBUUID = CBUUID(string: "180F")
    private let batteryCBUUID = CBUUID(string: RingUUIDs.battery)

    private static let advertisedName = "SMART_RING"
    private static let manufacturerHexNeedle = "41422ec75b6a"
    private static let lastPeripheralKey = "ring.lastPeripheralIdentifier"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScanning() {
        guard isBluetoothReady else {
            lastError = "Bluetooth is not powered on."
            return
        }
        discovered = []
        discoveredPeripherals = [:]
        lastError = nil
        autoReconnect = true
        state = .scanning
        // Scan with no service filter so we also catch firmwares that don't advertise the
        // 0x56ff service UUID; matching is done in didDiscover.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(to id: UUID) {
        // Prefer the freshly-scanned object; fall back to the system cache (paired/known).
        guard let target = discoveredPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "Ring no longer available; scan again."
            return
        }
        beginConnect(to: target)
    }

    /// Silently reconnect to the last paired ring (used on launch). Falls back to scanning.
    func connectLastKnown() {
        guard isBluetoothReady, let id = lastKnownIdentifier else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            beginConnect(to: known)
        } else {
            startScanning()
        }
    }

    func disconnect() {
        autoReconnect = false
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            state = .idle
        }
    }

    /// Queue a 20-byte command for writing. Writes are serialized.
    func enqueueWrite(_ data: Data) {
        writeQueue.append(data)
        pumpWrites()
    }

    func readBattery() {
        guard let peripheral, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    var lastKnownIdentifier: UUID? {
        UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init)
    }

    var hasLastKnownRing: Bool { lastKnownIdentifier != nil }

    // MARK: - Internal

    private func beginConnect(to target: CBPeripheral) {
        central.stopScan()
        autoReconnect = true
        peripheral = target
        target.delegate = self
        state = .connecting
        central.connect(target, options: nil)
    }

    private func pumpWrites() {
        guard !writeInFlight,
              let peripheral,
              let writeChar,
              !writeQueue.isEmpty else { return }
        let data = writeQueue.removeFirst()
        writeInFlight = true
        publishRawPacket(direction: .outgoing, data: data)
        peripheral.writeValue(data, for: writeChar, type: .withResponse)
    }

    private func publishRawPacket(direction: PacketDirection, data: Data) {
        let decoded = decoder.decode(data)
        publish(.rawPacket(direction: direction, data: data, decoded: decoded))
    }

    private func publish(_ event: PulseEvent) {
        Task { await PulseEventBus.shared.publish(event) }
    }

    private func matchesRing(name: String?, advertisementData: [String: Any]) -> Bool {
        if let name, name == Self.advertisedName { return true }
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(serviceCBUUID) {
            return true
        }
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.hexString.contains(Self.manufacturerHexNeedle) {
            return true
        }
        return false
    }
}

// MARK: - CBCentralManagerDelegate

extension RingBLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            isBluetoothReady = (central.state == .poweredOn)
            switch central.state {
            case .poweredOn:
                if autoReconnect, hasLastKnownRing, peripheral == nil {
                    connectLastKnown()
                }
            case .poweredOff, .unauthorized, .unsupported:
                state = .idle
                lastError = "Bluetooth unavailable (\(central.state.rawValue))."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            let isRing = matchesRing(name: name, advertisementData: advertisementData)
            // List any *named* peripheral so the user can always find their ring, even if its
            // advertisement omits the service UUID / manufacturer bytes; ring matches sort first.
            guard let displayName = name, !displayName.isEmpty else { return }
            discoveredPeripherals[peripheral.identifier] = peripheral
            let ring = DiscoveredRing(id: peripheral.identifier, name: displayName, rssi: RSSI.intValue, isLikelyRing: isRing)
            if let index = discovered.firstIndex(where: { $0.id == ring.id }) {
                discovered[index] = ring
            } else {
                discovered.append(ring)
            }
            discovered.sort { ($0.isLikelyRing ? 0 : 1, -$0.rssi) < ($1.isLikelyRing ? 0 : 1, -$1.rssi) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            peripheral.discoverServices([serviceCBUUID, batteryServiceCBUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            state = .failed
            lastError = error?.localizedDescription ?? "Failed to connect."
            publish(.deviceStateChanged(state: .failed, address: nil))
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            writeChar = nil
            notifyChar = nil
            batteryCharacteristic = nil
            writeInFlight = false
            writeQueue = []
            publish(.deviceStateChanged(state: .disconnected, address: nil))
            if autoReconnect {
                state = .reconnecting
                central.connect(peripheral, options: nil)
            } else {
                state = .disconnected
                self.peripheral = nil
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingBLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                if service.uuid == serviceCBUUID {
                    peripheral.discoverCharacteristics([writeCBUUID, notifyCBUUID], for: service)
                } else if service.uuid == batteryServiceCBUUID {
                    peripheral.discoverCharacteristics([batteryCBUUID], for: service)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case writeCBUUID:
                    writeChar = characteristic
                case notifyCBUUID:
                    notifyChar = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case batteryCBUUID:
                    batteryCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == notifyCBUUID, characteristic.isNotifying else { return }
            // Fully connected once notifications are live.
            state = .connected
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
            publish(.deviceStateChanged(state: .connected, address: nil))
            readBattery()
            onConnected?()
            pumpWrites()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let value = characteristic.value else { return }
            switch characteristic.uuid {
            case batteryCBUUID:
                if let first = value.first {
                    batteryPercent = Int(first)
                    publish(.batteryLevel(percent: Int(first)))
                }
            case notifyCBUUID:
                let decoded = decoder.decode(value)
                publish(.rawPacket(direction: .incoming, data: value, decoded: decoded))
                for event in RingEventBridge.events(for: decoded) {
                    publish(event)
                }
            default:
                break
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            writeInFlight = false
            pumpWrites()
        }
    }
}
