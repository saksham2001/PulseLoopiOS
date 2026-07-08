import Foundation
@preconcurrency import CoreBluetooth

/// Device-agnostic CoreBluetooth client for any supported wearable.
///
/// The client owns only the CoreBluetooth plumbing — scanning, connecting, discovering
/// services/characteristics, serializing writes, and fanning out notifications. Every
/// protocol-specific decision (which service/characteristics to use, how to frame a command, how to
/// decode a notification, what the startup/history flow is) is delegated to the `WearableDriver` and
/// `RingSyncEngine` selected at connect time from the coordinator registry.
///
/// Discovery walks `Self.coordinators` and the first coordinator whose `matches` claims a
/// peripheral wins; its driver is instantiated per connection (so per-connection state — big-data
/// buffers, sync-machine state — never leaks across reconnects). Adding a new wearable is "append a
/// coordinator to the registry."
///
/// Every outgoing and incoming frame is still published as `PulseEvent.rawPacket` (for the hidden
/// debug feed), and decoded notifications are fanned out to typed `PulseEvent`s via `RingEventBridge`.
///
/// The central manager is created with `queue: nil`, so all delegate callbacks arrive on the main
/// thread; the class is `@MainActor` and the delegate methods use `MainActor.assumeIsolated`. Writes
/// are serialized (one outstanding `withResponse` write at a time) to keep framed responses in order.
@MainActor
@Observable
final class RingBLEClient: NSObject {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Registry of supported wearables. First coordinator whose `matches` claims a peripheral wins.
    /// **Adding a wearable = append one entry here.**
    static let coordinators: [WearableCoordinator.Type] = [
        JringCoordinator.self,
        ColmiCoordinator.self,
    ]

    struct DiscoveredRing: Identifiable, Equatable {
        let id: UUID          // CBPeripheral.identifier
        let name: String
        let rssi: Int
        /// True when the advertisement matches a known wearable signature. Non-matching named
        /// peripherals are still listed (sorted below) so the user can always find their device.
        let isLikelyRing: Bool
        /// The wearable family this advertisement matched, if any (drives the device card + icon).
        let deviceType: RingDeviceType?
        /// Exact catalog model inferred from the Bluetooth local name, when recognizable.
        let wearableModelID: String?
    }

    // MARK: Observable state (read by SwiftUI)
    private(set) var state: RingConnectionState = .idle
    private(set) var discovered: [DiscoveredRing] = []
    private(set) var batteryPercent: Int?
    private(set) var isBluetoothReady = false
    private(set) var lastError: String?

    /// The wearable family of the active connection (nil until a driver is selected).
    private(set) var activeDeviceType: RingDeviceType?
    private(set) var activeWearableModelID: String?
    var activeWearableModel: WearableModel? { WearableModel.model(id: activeWearableModelID) }
    /// What the active device can do — the single source the capability-gated UI consults.
    private(set) var activeCapabilities: Set<WearableCapability> = []

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
    /// Optional second write characteristic for big-data requests (Colmi `de5bf72a`).
    private var commandChar: CBCharacteristic?
    private var notifyChars: [CBUUID: CBCharacteristic] = [:]
    private var batteryCharacteristic: CBCharacteristic?

    // MARK: Active driver / engine (selected per connection)
    private var activeCoordinator: WearableCoordinator?
    private var activeDriver: WearableDriver?
    private var activeSyncEngine: RingSyncEngine?
    private var activeAdvertisedName: String?

    // MARK: Write serialization
    /// Each queued write carries its already-framed bytes and which characteristic to send it to.
    private var writeQueue: [(data: Data, useCommandChannel: Bool)] = []
    private var writeInFlight = false
    /// Monotonic id for the in-flight write, so a timeout task only unblocks *its* write (not a newer
    /// one that has since started). Mirrors the Android write-ACK timeout guard.
    private var writeSeq: UInt64 = 0

    /// When true, an unexpected disconnect triggers an automatic reconnect attempt.
    private var autoReconnect = true

    // MARK: Connection reliability (mirrors the Android RingBLEClient hardening)
    private let encoder = RingEncoder()
    /// Wall-clock of the last proof the link is alive (notification, write ACK, or read). Drives the
    /// watchdog's zombie-link detection.
    private var lastActivityAt: Date?
    private var keepaliveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Keepalive cadence — 15s, comfortably inside the ring's ~20s idle timeout.
    private let keepaliveInterval: UInt64 = 15_000_000_000
    /// Watchdog tick + the "no activity ⇒ zombie link" threshold. The threshold is loosened from
    /// Android's 50s because iOS hands background apps shorter, less predictable execution windows.
    private let watchdogInterval: UInt64 = 15_000_000_000
    private let linkStaleSeconds: TimeInterval = 60
    /// Write-ACK timeout: if CoreBluetooth never reports the write completing, unblock the queue so a
    /// single dropped ACK can't wedge it.
    private let writeAckTimeout: UInt64 = 4_000_000_000

    private static let lastPeripheralKey = "ring.lastPeripheralIdentifier"
    private static let lastDeviceTypeKey = "ring.lastDeviceType"
    private static let lastWearableModelKey = "ring.lastWearableModel"

    /// The 0x180F battery service, used only when the active driver exposes GATT battery.
    private let batteryServiceCBUUID = CBUUID(string: "180F")

    /// Standard Device Information Service + its firmware/software revision characteristics. The 56ff
    /// ring exposes these even without advertising 0x180A, so we scan for them across all services
    /// (Android firmware-discovery parity).
    private let disServiceCBUUID = CBUUID(string: "180A")
    private let firmwareCharUUIDs: Set<CBUUID> = [CBUUID(string: "2A26"), CBUUID(string: "2A28")]

    override convenience init() {
        self.init(startManager: true)
    }

    /// `startManager: false` skips creating the `CBCentralManager`, used by the app host under
    /// XCTest where CoreBluetooth's XPC service is unavailable (headless CI simulator) and would
    /// otherwise log "XPC connection invalid" and hang. No BLE method is called in that mode.
    init(startManager: Bool) {
        super.init()
        if startManager {
            // State restoration: if iOS kills the app mid-workout, a BLE event (e.g. the ring's HR
            // stream notifying) relaunches us and `willRestoreState` re-adopts the connection.
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "pulseloop.ring.central"]
            )
        }
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
        // Scan with no service filter so we also catch firmwares that don't advertise their service
        // UUID; matching is done in didDiscover via the coordinator registry.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(to id: UUID, selectedModelID: String? = nil) {
        // Prefer the freshly-scanned object; fall back to the system cache (paired/known).
        guard let target = discoveredPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "Ring no longer available; scan again."
            return
        }
        // Use the matched device type from discovery if we have it.
        let discoveredRing = discovered.first { $0.id == id }
        beginConnect(
            to: target,
            deviceType: discoveredRing?.deviceType,
            selectedModelID: discoveredRing?.wearableModelID ?? selectedModelID,
            advertisedName: discoveredRing?.name
        )
    }

    /// Silently reconnect to the last paired ring (used on launch). Falls back to scanning.
    func connectLastKnown() {
        guard isBluetoothReady, let id = lastKnownIdentifier else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            beginConnect(
                to: known,
                deviceType: lastKnownDeviceType,
                selectedModelID: lastKnownWearableModelID,
                advertisedName: known.name
            )
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

    /// Forget the active/last ring: release it (jring sends the 0x4B UNBOND so the ring re-advertises
    /// for other apps), then disconnect and clear the remembered identifier + device type so the app no
    /// longer auto-reconnects to it. The unbind is best-effort — we give the write a short window to
    /// flush before tearing the link down, but never block Forget on it.
    func forget() {
        if state == .connected, let engine = activeSyncEngine {
            engine.unbind()
            // Let the UNBOND write flush (and the ring ACK) before we drop the link.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                finalizeForget()
            }
        } else {
            finalizeForget()
        }
    }

    private func finalizeForget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceTypeKey)
        UserDefaults.standard.removeObject(forKey: Self.lastWearableModelKey)
        activeDeviceType = nil
        activeWearableModelID = nil
        activeCapabilities = []
        activeAdvertisedName = nil
        publish(.deviceForgotten)
    }

    /// Queue a logical command for writing. The active driver's framing (padding/checksum) is applied
    /// here, so callers/engines deal in unframed commands. The driver also decides whether the frame
    /// goes to the normal write char or the big-data command char. Writes are serialized.
    func enqueueWrite(_ data: Data) {
        let framed = activeDriver?.frame(data) ?? data
        let useCommand = activeDriver?.usesCommandChannel(for: framed) ?? false
        writeQueue.append((data: framed, useCommandChannel: useCommand))
        pumpWrites()
    }

    func readBattery() {
        guard let peripheral, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    var lastKnownIdentifier: UUID? {
        UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init)
    }

    var lastKnownDeviceType: RingDeviceType? {
        UserDefaults.standard.string(forKey: Self.lastDeviceTypeKey).flatMap(RingDeviceType.init)
    }

    var lastKnownWearableModelID: String? {
        UserDefaults.standard.string(forKey: Self.lastWearableModelKey)
    }

    var hasLastKnownRing: Bool { lastKnownIdentifier != nil }

    /// The active sync engine, exposed so the `RingSyncCoordinator` façade can drive command flows.
    var syncEngine: RingSyncEngine? { activeSyncEngine }

    // MARK: - Internal

    private func beginConnect(
        to target: CBPeripheral,
        deviceType: RingDeviceType?,
        selectedModelID: String?,
        advertisedName: String?
    ) {
        central.stopScan()
        autoReconnect = true
        // Force-close any stale connection (incl. a different peripheral) before opening a new one, so
        // a reconnect after an idle drop can't collide with an orphaned handle. iOS analogue of
        // Android's gatt.disconnect()+close(). Reset the per-connection write state too.
        stopReliabilityTimers()
        if let old = peripheral, old.identifier != target.identifier || old.state != .disconnected {
            central.cancelPeripheralConnection(old)
        }
        writeChar = nil; commandChar = nil; notifyChars = [:]; batteryCharacteristic = nil
        writeInFlight = false; writeQueue = []
        peripheral = target
        target.delegate = self
        // Select the coordinator/driver for this connection. Default to jring if discovery didn't
        // tag a type (e.g. reconnect to an unknown cached peripheral) — preserves prior behavior.
        let coordinatorType = Self.coordinators.first { $0.deviceType == deviceType } ?? JringCoordinator.self
        activeAdvertisedName = advertisedName
        activeWearableModelID = WearableModel.resolve(
            advertisedName: advertisedName,
            selectedModelID: selectedModelID,
            family: coordinatorType.deviceType
        )?.id
        installDriver(coordinatorType)
        state = .connecting
        central.connect(target, options: nil)
    }

    /// Instantiate the coordinator's driver + sync engine for the upcoming connection. A fresh driver
    /// per connection keeps per-connection state from leaking across reconnects.
    private func installDriver(_ coordinatorType: WearableCoordinator.Type) {
        let coordinator = coordinatorType.init()
        let driver = coordinator.makeDriver(writer: self)
        activeCoordinator = coordinator
        activeDriver = driver
        activeSyncEngine = driver.makeSyncEngine()
        activeDeviceType = coordinatorType.deviceType
        activeCapabilities = coordinator.capabilities
    }

    private func pumpWrites() {
        guard !writeInFlight,
              let peripheral,
              let writeChar,
              !writeQueue.isEmpty else { return }
        let item = writeQueue.removeFirst()
        // Big-data requests go to the command char (`de5bf72a`); fall back to the write char if the
        // device/firmware didn't expose a separate one.
        let target = (item.useCommandChannel ? commandChar : writeChar) ?? writeChar
        writeInFlight = true
        writeSeq &+= 1
        let seq = writeSeq
        publishRawPacket(direction: .outgoing, data: item.data)
        peripheral.writeValue(item.data, for: target, type: .withResponse)
        // Guard against a missed `didWriteValueFor`: if this write is still in flight after the
        // timeout, unblock the queue so one dropped ACK can't wedge it (Android write-ACK timeout).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: writeAckTimeout)
            if writeInFlight, seq == writeSeq {
                writeInFlight = false
                pumpWrites()
            }
        }
    }

    // MARK: - Connection reliability

    /// Record that the link just proved itself alive (notification / write ACK / read).
    private func noteActivity() { lastActivityAt = Date() }

    /// Start the periodic keepalive ping. jring-only: Colmi runs its own keepalive inside its sync
    /// engine, so pinging here would double up. The ring's ~20s idle timeout means a missed ping is
    /// recoverable on the next tick.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        guard activeDeviceType == .jring else { return }
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.keepaliveInterval ?? 15_000_000_000)
                guard let self, !Task.isCancelled, self.state == .connected else { return }
                self.enqueueWrite(self.encoder.makeKeepaliveCommand())
            }
        }
    }

    /// Watchdog: CoreBluetooth doesn't always deliver a disconnect when the OS tears the link down in
    /// the background, leaving a "zombie" peripheral that's `.connected` but silent. If we've gone
    /// `linkStaleSeconds` with no inbound activity, force a reconnect. Also catches a hung connect.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.watchdogInterval ?? 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard isBluetoothReady, state == .connected, let last = lastActivityAt else { return }
        if Date().timeIntervalSince(last) > linkStaleSeconds {
            // Zombie link: drop it and let the disconnect handler's auto-reconnect re-link.
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
    }

    private func stopReliabilityTimers() {
        keepaliveTask?.cancel(); keepaliveTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
    }

    private func publishRawPacket(direction: PacketDirection, data: Data) {
        // Outgoing frames are logged raw for the debug feed. We do NOT route them through the
        // driver's `ingest` (that is the inbound path and, for big-data devices, would corrupt the
        // reassembly buffer). The command id is enough annotation for the trace.
        let decoded = RingDecodedEvent.commandAck(commandId: data.first ?? 0)
        publish(.rawPacket(direction: direction, data: data, decoded: decoded))
    }

    private func publish(_ event: PulseEvent) {
        Task { await PulseEventBus.shared.publish(event) }
    }

    /// Walk the coordinator registry to claim a discovered peripheral. Returns the first matching
    /// device type, or nil if no coordinator recognizes it.
    private func matchDeviceType(name: String?, advertisementData: [String: Any]) -> RingDeviceType? {
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let info = AdvertisementInfo(serviceUUIDs: serviceUUIDs, manufacturerData: mfg)
        for coordinatorType in Self.coordinators where coordinatorType.matches(name: name, advertisement: info) {
            return coordinatorType.deviceType
        }
        return nil
    }
}

// MARK: - RingCommandWriter

extension RingBLEClient: RingCommandWriter {
    /// Drivers / sync engines enqueue logical commands through this seam; framing is applied in
    /// `enqueueWrite`.
    func enqueue(_ command: Data) {
        enqueueWrite(command)
    }
}

// MARK: - CBCentralManagerDelegate

extension RingBLEClient: CBCentralManagerDelegate {
    /// iOS relaunched us to service a preserved BLE session (e.g. the ring's HR stream notified
    /// while we were dead). Re-adopt the peripheral and remembered driver here; the actual
    /// connect/discovery is deferred to `centralManagerDidUpdateState` — restoration fires before
    /// power-on completes, and issuing `connect` that early is API misuse.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
            guard peripheral == nil, let target = restored.first else { return }
            autoReconnect = true
            peripheral = target
            target.delegate = self
            let coordinatorType = Self.coordinators.first { $0.deviceType == lastKnownDeviceType } ?? JringCoordinator.self
            installDriver(coordinatorType)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            isBluetoothReady = (central.state == .poweredOn)
            switch central.state {
            case .poweredOn:
                if let restored = peripheral, state != .connected {
                    // Adopted in willRestoreState — resume from wherever the link actually is.
                    if restored.state == .connected {
                        state = .connecting
                        restored.discoverServices(nil)
                    } else {
                        state = .reconnecting
                        central.connect(restored, options: nil)
                    }
                } else if autoReconnect, hasLastKnownRing, peripheral == nil {
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
            let matchedType = matchDeviceType(name: name, advertisementData: advertisementData)
            let matchedModel = WearableModel.model(advertisedName: name)
            // List any *named* peripheral so the user can always find their ring, even if its
            // advertisement omits the service UUID / manufacturer bytes; recognized rings sort first.
            guard let displayName = name, !displayName.isEmpty else { return }
            discoveredPeripherals[peripheral.identifier] = peripheral
            let ring = DiscoveredRing(
                id: peripheral.identifier,
                name: displayName,
                rssi: RSSI.intValue,
                isLikelyRing: matchedType != nil,
                deviceType: matchedType,
                wearableModelID: matchedModel?.family == matchedType ? matchedModel?.id : nil
            )
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
            // Discover ALL services so we also find a Device Information Service the ring exposes
            // without advertising it (firmware revision lives there). Characteristic discovery below
            // filters to the driver's chars + battery + firmware.
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            lastError = error?.localizedDescription ?? "Failed to connect."
            // Don't dead-end at .failed during a workout: keep a pending reconnect alive so iOS
            // re-links the ring as soon as it's back in range.
            if autoReconnect, let peripheral = self.peripheral {
                state = .reconnecting
                publish(.deviceStateChanged(state: .reconnecting, address: nil))
                central.connect(peripheral, options: nil)
            } else {
                state = .failed
                publish(.deviceStateChanged(state: .failed, address: nil))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            stopReliabilityTimers()
            lastActivityAt = nil
            writeChar = nil
            commandChar = nil
            notifyChars = [:]
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
            guard let driver = activeDriver else { return }
            for service in peripheral.services ?? [] {
                if driver.serviceUUIDs.contains(service.uuid) {
                    var chars = driver.notifyUUIDs
                    chars.append(driver.writeUUID)
                    if let command = driver.commandUUID { chars.append(command) }
                    peripheral.discoverCharacteristics(chars, for: service)
                } else if service.uuid == driver.batteryServiceUUID {
                    if let batteryChar = driver.batteryCharUUID {
                        peripheral.discoverCharacteristics([batteryChar], for: service)
                    }
                } else if service.uuid == disServiceCBUUID {
                    // Standard Device Information Service — read firmware/software revision.
                    peripheral.discoverCharacteristics(Array(firmwareCharUUIDs), for: service)
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
            guard let driver = activeDriver else { return }
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == driver.writeUUID {
                    writeChar = characteristic
                } else if characteristic.uuid == driver.commandUUID {
                    commandChar = characteristic
                } else if driver.notifyUUIDs.contains(characteristic.uuid) {
                    notifyChars[characteristic.uuid] = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == driver.batteryCharUUID {
                    batteryCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                } else if firmwareCharUUIDs.contains(characteristic.uuid) {
                    peripheral.readValue(for: characteristic)
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
            guard let driver = activeDriver,
                  driver.notifyUUIDs.contains(characteristic.uuid),
                  characteristic.isNotifying else { return }
            // Fully connected once at least one notify char is live. (Multi-notify devices may fire
            // this twice; guard against re-running startup.)
            guard state != .connected else { return }
            state = .connected
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
            if let type = activeDeviceType {
                UserDefaults.standard.set(type.rawValue, forKey: Self.lastDeviceTypeKey)
            }
            if let modelID = activeWearableModelID {
                UserDefaults.standard.set(modelID, forKey: Self.lastWearableModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastWearableModelKey)
            }
            publish(.deviceStateChanged(state: .connected, address: nil))
            if let type = activeDeviceType {
                publish(.deviceIdentified(
                    deviceType: type,
                    wearableModelID: activeWearableModelID,
                    advertisedName: activeAdvertisedName,
                    capabilities: activeCapabilities
                ))
            }
            noteActivity()
            startKeepalive()
            startWatchdog()
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
            noteActivity()
            if characteristic.uuid == activeDriver?.batteryCharUUID {
                if let first = value.first {
                    batteryPercent = Int(first)
                    publish(.batteryLevel(percent: Int(first)))
                }
                return
            }
            // Firmware revision read from a standard DIS characteristic (0x2A26/0x2A28) — surface it.
            if firmwareCharUUIDs.contains(characteristic.uuid) {
                if let fw = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !fw.isEmpty {
                    publish(.firmwareVersion(fw))
                }
                return
            }
            guard let driver = activeDriver, driver.notifyUUIDs.contains(characteristic.uuid) else { return }
            for decoded in driver.ingest(value, from: characteristic.uuid) {
                publish(.rawPacket(direction: .incoming, data: value, decoded: decoded))
                for event in RingEventBridge.events(for: decoded) {
                    publish(event)
                }
                // Advance any response-driven sync machine (no-op for jring).
                activeSyncEngine?.handle(decoded)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            noteActivity()
            writeInFlight = false
            pumpWrites()
        }
    }
}
