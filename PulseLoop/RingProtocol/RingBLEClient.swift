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
    ///
    /// The order is load-bearing at exactly one place: `ColmiSmartHealthCoordinator` must precede
    /// `ColmiCoordinator`. Both recognize the same Colmi local names, and the QRing matcher needs
    /// *only* the name — so behind it, no SmartHealth ring would ever be claimed. The SmartHealth
    /// matcher is a conjunction a QRing ring cannot satisfy, so it is safe in front.
    static let coordinators: [WearableCoordinator.Type] = [
        JringCoordinator.self,
        ColmiSmartHealthCoordinator.self,
        ColmiCoordinator.self,
        TK5Coordinator.self,
    ]

    /// Which coordinator serves a connection. Pure, so the pairing rules are testable without a
    /// `CBCentralManager`.
    ///
    /// **The user's explicit family outranks the scan's auto-match.** Two Colmi rings that speak
    /// different protocols can advertise the identical local name, so the advertisement is a hint and
    /// the pairing screen's app-type pick is the fact. Falls back to jring when neither is known (a
    /// reconnect to an unrecognized cached peripheral), preserving the original behavior.
    static func coordinatorType(
        preferredFamily: RingDeviceType?,
        autoMatched: RingDeviceType?
    ) -> WearableCoordinator.Type {
        let family = preferredFamily ?? autoMatched
        return coordinators.first { $0.deviceType == family } ?? JringCoordinator.self
    }

    /// Walk the registry to claim an advertisement; nil when no coordinator recognizes it.
    static func matchDeviceType(name: String?, advertisement: AdvertisementInfo) -> RingDeviceType? {
        coordinators.first { $0.matches(name: name, advertisement: advertisement) }?.deviceType
    }

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
    /// Watchdog tick counter, used to piggyback a periodic battery re-read on the existing 15s loop
    /// (no new timer). jring only reports battery on connect, so without this the level goes stale.
    private var watchdogTicks = 0
    /// Write-ACK timeout: if CoreBluetooth never reports the write completing, unblock the queue so a
    /// single dropped ACK can't wedge it.
    private let writeAckTimeout: UInt64 = 4_000_000_000

    /// Connect-attempt timeout, armed **only** for a connect the user asked for (see `beginConnect`).
    /// The watchdog above only guards a link that already reached `.connected`; nothing guarded the
    /// connect *phase*, which is where the wrong-driver failure lives: pick the wrong app variant for a
    /// Colmi and the installed driver hunts for service UUIDs the ring doesn't have — the BLE link
    /// opens, GATT discovery turns up nothing, `.connected` never arrives, and the pairing screen spins
    /// forever with no error. 20 s is slack, not a race: a healthy ring completes link + discovery +
    /// notify-enable in a few seconds.
    private var connectTimeoutTask: Task<Void, Never>?
    private let connectTimeout: UInt64 = 20_000_000_000

    private static let lastPeripheralKey = "ring.lastPeripheralIdentifier"
    private static let lastDeviceTypeKey = "ring.lastDeviceType"
    private static let lastWearableModelKey = "ring.lastWearableModel"
    private static let lastCapabilitiesKey = "ring.lastCapabilities"

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

    /// - Parameter preferredFamily: the family the *user* declared at pairing (the app-type picker on a
    ///   Colmi card). Non-nil wins over the scan's auto-match — see `coordinatorType(preferredFamily:autoMatched:)`.
    func connect(to id: UUID, selectedModelID: String? = nil, preferredFamily: RingDeviceType? = nil) {
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
            advertisedName: discoveredRing?.name,
            preferredFamily: preferredFamily,
            userInitiated: true
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
        cancelConnectTimeout()   // an explicit disconnect is not a failed connect attempt
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
        UserDefaults.standard.removeObject(forKey: Self.lastCapabilitiesKey)   // a new ring must not inherit the old one's claims
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

    /// What the last connected ring resolved to *after* its capability bitmap had spoken — the baseline
    /// plus whatever the unit itself claimed (`applySupportFunctions`).
    ///
    /// Remembered because the bitmap arrives partway into a handshake, while `Device.capabilitiesRaw` is
    /// overwritten wholesale at the *start* of one. Without this, every connect would first stamp the
    /// device back down to the family baseline — so a ring whose temperature sensor we already know about
    /// would drop its Vitals card on every launch and only get it back a second later, and a handshake
    /// whose `02 01` reply is lost (or answered by firmware with a short array) would leave it dropped
    /// for the whole session and while offline afterwards.
    var lastKnownCapabilities: Set<WearableCapability> {
        Set(csv: UserDefaults.standard.string(forKey: Self.lastCapabilitiesKey) ?? "")
    }

    var hasLastKnownRing: Bool { lastKnownIdentifier != nil }

    /// The active sync engine, exposed so the `RingSyncCoordinator` façade can drive command flows.
    var syncEngine: RingSyncEngine? { activeSyncEngine }

    // MARK: - Internal

    /// - Parameters:
    ///   - preferredFamily: an explicitly user-declared family; wins over `deviceType` (the auto-match).
    ///   - userInitiated: the user tapped a ring in the pairing screen, so a connect that never lands is
    ///     a dead end they need told about — arm the connect-attempt timeout. Background reconnects pass
    ///     false: a pending connect that waits forever is exactly what they're *for*.
    private func beginConnect(
        to target: CBPeripheral,
        deviceType: RingDeviceType?,
        selectedModelID: String?,
        advertisedName: String?,
        preferredFamily: RingDeviceType? = nil,
        userInitiated: Bool = false
    ) {
        central.stopScan()
        autoReconnect = true
        // Force-close any stale connection (incl. a different peripheral) before opening a new one, so
        // a reconnect after an idle drop can't collide with an orphaned handle. iOS analogue of
        // Android's gatt.disconnect()+close(). Reset the per-connection write state too.
        stopReliabilityTimers()
        cancelConnectTimeout()
        if let old = peripheral, old.identifier != target.identifier || old.state != .disconnected {
            central.cancelPeripheralConnection(old)
        }
        writeChar = nil; commandChar = nil; notifyChars = [:]; batteryCharacteristic = nil
        writeInFlight = false; writeQueue = []
        peripheral = target
        target.delegate = self
        // Select the coordinator/driver for this connection: the user's declared family if they made
        // one, else the auto-match, else jring (an unknown cached peripheral — prior behavior).
        let coordinatorType = Self.coordinatorType(preferredFamily: preferredFamily, autoMatched: deviceType)
        activeAdvertisedName = advertisedName
        activeWearableModelID = WearableModel.resolve(
            advertisedName: advertisedName,
            selectedModelID: selectedModelID,
            family: coordinatorType.deviceType
        )?.id
        installDriver(coordinatorType)
        state = .connecting
        if userInitiated { startConnectTimeout() }
        central.connect(target, options: nil)
    }

    /// Instantiate the coordinator's driver + sync engine for the upcoming connection. A fresh driver
    /// per connection keeps per-connection state from leaking across reconnects.
    ///
    /// Capabilities start from what we last *learned* about the ring, not from the bare family baseline:
    /// the remembered set is fed back through the same additive-only refinement (`refinedCapabilities`),
    /// so it can only re-grant capabilities this family gates on the bitmap — a set remembered from a
    /// different family, or one naming something this family never gates, cannot leak in. The ring's own
    /// bitmap still overrules it moments later (`applySupportFunctions`), downwards as well as upwards.
    func installDriver(_ coordinatorType: WearableCoordinator.Type) {
        let coordinator = coordinatorType.init()
        let driver = coordinator.makeDriver(writer: self)
        activeCoordinator = coordinator
        activeDriver = driver
        activeSyncEngine = driver.makeSyncEngine()
        activeDeviceType = coordinatorType.deviceType
        activeCapabilities = coordinator.refinedCapabilities(bitmapDerived: lastKnownCapabilities)
    }

    /// Re-adopt the remembered ring's identity: its family **and** the exact catalog model.
    ///
    /// State restoration is the one connect path with no advertisement to re-derive either from. The
    /// family was already remembered; the model id was not, and a restored session that reached
    /// `.connected` without it published `.deviceIdentified(wearableModelID: nil)` — which *erases*
    /// `Device.wearableModelID`, costing the device card its product name and art until some later
    /// reconnect happened to carry a resolvable GAP name.
    func adoptRememberedIdentity() {
        // The remembered family already *is* the user's choice — `beginConnect` persisted whichever
        // coordinator it selected — so a restored session re-adopts the right driver for free.
        installDriver(Self.coordinatorType(preferredFamily: nil, autoMatched: lastKnownDeviceType))
        activeWearableModelID = lastKnownWearableModelID
    }

    /// Fold the ring's self-reported capability bitmap into the active capability set.
    ///
    /// `installDriver` seeds `activeCapabilities` with the coordinator's baseline — what the *family*
    /// can do. This is where *this unit* gets a say, which is what makes one driver able to serve SKUs
    /// that differ on which sensors they physically have. The bitmap can only add capabilities the
    /// family pre-approved (`refinedCapabilities`), so a family that gates none is untouched.
    ///
    /// Re-publishing `.deviceIdentified` is what carries the refined set into `Device.capabilitiesRaw`;
    /// the equality guard keeps that idempotent, because the bitmap arrives on *every* handshake and a
    /// reconnect runs a fresh one — without it, each reconnect would re-publish an identical set and
    /// churn the bus and the store for nothing.
    private func applySupportFunctions(_ derived: Set<WearableCapability>) {
        guard let coordinator = activeCoordinator, let type = activeDeviceType else { return }
        let refined = coordinator.refinedCapabilities(bitmapDerived: derived)
        // Remember the answer even when it changes nothing right now: this is what seeds the *next*
        // connect, before that connect's own bitmap has arrived (see `lastKnownCapabilities`).
        UserDefaults.standard.set(refined.csv, forKey: Self.lastCapabilitiesKey)
        guard refined != activeCapabilities else { return }
        activeCapabilities = refined
        publish(.deviceIdentified(
            deviceType: type,
            wearableModelID: activeWearableModelID,
            advertisedName: activeAdvertisedName,
            capabilities: refined
        ))
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
        watchdogTicks = 0
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.watchdogInterval ?? 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        // Periodic battery re-read (~every 60 min at the 15s cadence): jring reports battery only on
        // connect, so refresh it here. Colmi's engine re-requests 0x03; both are harmless no-ops when
        // unsupported. Runs before the stale-link check (which may return early).
        watchdogTicks += 1
        if watchdogTicks >= 240, state == .connected {
            watchdogTicks = 0
            readBattery()                                // jring GATT; no-op when the characteristic is absent
            activeSyncEngine?.requestBattery()           // Colmi 0x03; protocol default no-op
        }
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

    // MARK: Connect-attempt timeout

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.connectTimeout ?? 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.connectAttemptTimedOut()
        }
    }

    /// Deliberately *not* folded into `stopReliabilityTimers`: that also runs on an unexpected disconnect,
    /// where the client re-dials and the attempt is still live — cancelling there would disarm the very
    /// case this guards.
    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    /// The user's connect never reached `.connected`. Give up, and say why in terms they can act on.
    private func connectAttemptTimedOut() {
        guard state == .connecting || state == .reconnecting else { return }
        connectTimeoutTask = nil
        // Order matters: `didDisconnectPeripheral` re-dials whenever `autoReconnect` is set, so clearing
        // it *before* the cancel is what stops the failure from instantly reconnecting itself.
        autoReconnect = false
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        stopReliabilityTimers()
        // Names the app variant we tried and the one to try instead — the whole point of failing loudly
        // here is that the wrong-app pick is recoverable in one tap (`PairingView`).
        lastError = RingConnectFailure.message(family: activeDeviceType)
        state = .failed
        publish(.deviceStateChanged(state: .failed, address: nil))
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

    /// Lift CoreBluetooth's raw advertisement dictionary into `AdvertisementInfo` and claim it against
    /// the registry.
    private func matchDeviceType(name: String?, advertisementData: [String: Any]) -> RingDeviceType? {
        Self.matchDeviceType(name: name, advertisement: AdvertisementInfo(
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [],
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        ))
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
            adoptRememberedIdentity()
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
            // Keep the model tag when the matched family is *any* the card can resolve to, not just its
            // default — a Colmi claimed as `.colmiSmartHealth` is still a "Colmi R09".
            let modelID: String? = {
                guard let matchedModel, let matchedType,
                      matchedModel.families.contains(matchedType) else { return nil }
                return matchedModel.id
            }()
            let ring = DiscoveredRing(
                id: peripheral.identifier,
                name: displayName,
                rssi: RSSI.intValue,
                isLikelyRing: matchedType != nil,
                deviceType: matchedType,
                wearableModelID: modelID
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
            // Auto-reconnect keeps the existing driver, so tell it the link is new: anything half-read
            // when the old link dropped (a partial frame, an in-flight history transfer) must go.
            activeDriver?.connectionDidStart()
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
            // Stop the driver's own state machines *now*, not on the next connect: a self-driving one
            // (the YCBT history transfer's stall watchdog) would otherwise keep stepping through the
            // reconnect gap and refill the queue we just cleared, and those stale queries would be the
            // first thing the new link writes — ahead of its handshake.
            activeDriver?.connectionDidEnd()
            publish(.deviceStateChanged(state: .disconnected, address: nil))
            if autoReconnect {
                state = .reconnecting
                central.connect(peripheral, options: nil)
            } else {
                // A connect-attempt timeout has already parked us in `.failed` with an explanatory
                // message, and the cancel *it* issued is what brought us here — it must not overwrite
                // that with a bland `.disconnected`.
                if state != .failed { state = .disconnected }
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
                let uuid = characteristic.uuid
                // Write / command / notify are checked independently (not mutually exclusive) because a
                // device can expose one characteristic that is *both* the write target and a notify
                // source — the YCBT families' `be940001` receives command replies on the same char it's written
                // to. jring/Colmi keep these on distinct UUIDs, so their behavior is unchanged.
                if uuid == driver.writeUUID { writeChar = characteristic }
                if uuid == driver.commandUUID { commandChar = characteristic }
                if driver.notifyUUIDs.contains(uuid) {
                    notifyChars[uuid] = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if uuid == driver.batteryCharUUID {
                    batteryCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                } else if firmwareCharUUIDs.contains(uuid) {
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
            cancelConnectTimeout()   // the attempt landed
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
                if case let .supportFunctions(derived) = decoded {
                    applySupportFunctions(derived)
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
