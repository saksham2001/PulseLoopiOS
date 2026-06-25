import Foundation
@preconcurrency import CoreBluetooth

/// Thin write seam so a driver / sync engine can enqueue commands without holding `RingBLEClient`.
/// `RingBLEClient` conforms to this and applies `WearableDriver.frame(_:)` inside `enqueueWrite`,
/// so engines deal in *logical* (unframed) commands and never think about checksums or padding.
@MainActor
protocol RingCommandWriter: AnyObject {
    func enqueue(_ command: Data)
}

/// Connection + protocol handler for one wearable family — the "how do we talk to it" half of the
/// Coordinator/Driver split. The driver owns BLE topology, outbound framing/checksum, inbound
/// decoding (incl. any multi-packet reassembly), and it builds the per-device `RingSyncEngine`.
///
/// `RingBLEClient` stays device-agnostic by reading topology from the active driver and routing every
/// notify frame through `ingest`. The jring driver is a thin wrapper over the existing
/// `RingDecoder`/`RingEncoder`; the Colmi driver adds checksum framing + big-data reassembly.
@MainActor
protocol WearableDriver: AnyObject {
    // BLE topology
    var serviceUUIDs: [CBUUID] { get }
    var writeUUID: CBUUID { get }
    var notifyUUIDs: [CBUUID] { get }          // jring: 1; Colmi: 2 (V1 normal + V2 big-data)

    /// Optional second write characteristic for out-of-band / big-data requests. Colmi sends `0xbc`
    /// big-data requests (SpO2/sleep/temperature) here (`de5bf72a`), with replies on the V2 notify
    /// char. `nil` ⇒ the device has a single write characteristic (jring).
    var commandUUID: CBUUID? { get }

    /// GATT battery, when the device exposes it. `nil` ⇒ battery arrives in-band as a decoded event
    /// (Colmi reports battery via command `0x03` / notification, not a GATT characteristic).
    var batteryServiceUUID: CBUUID? { get }
    var batteryCharUUID: CBUUID? { get }

    /// Apply outbound framing. jring: identity (already 20 bytes). Colmi: pad to 15 content bytes +
    /// append the trailing-sum checksum byte (16 total).
    func frame(_ command: Data) -> Data

    /// Whether an outbound frame must go to the `commandUUID` characteristic instead of `writeUUID`.
    /// Colmi: true for `0xbc` big-data requests. Default: false.
    func usesCommandChannel(for frame: Data) -> Bool

    /// Decode one inbound notify frame, tagged with the characteristic it arrived on. Returns 0..n
    /// fully-decoded events (0 while a multi-packet big-data frame is still being reassembled). All
    /// checksum verification and reassembly is hidden here.
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent]

    /// The stateful brain: startup sequence + (for Colmi) the response-driven history machine.
    func makeSyncEngine() -> RingSyncEngine
}

extension WearableDriver {
    /// Most devices have a single write characteristic.
    var commandUUID: CBUUID? { nil }
    func usesCommandChannel(for frame: Data) -> Bool { false }
}

/// User-chosen all-day measurement configuration, passed as a plain value from the app layer into a
/// sync engine (the engine never reads SwiftData itself). Devices that support `.measurementInterval`
/// (Colmi) translate this into the relevant ring commands; others ignore it.
struct MeasurementSettings: Sendable, Equatable {
    var hrEnabled: Bool
    /// All-day HR sampling interval in minutes (Colmi clamps to 5…60 in 5-min steps).
    var hrIntervalMinutes: Int
    var spo2Enabled: Bool
    var stressEnabled: Bool
    var hrvEnabled: Bool
    var temperatureEnabled: Bool

    /// The current firmware default (matches the previous hard-coded Colmi startup behaviour).
    static let allOnDefault = MeasurementSettings(
        hrEnabled: true, hrIntervalMinutes: 5,
        spo2Enabled: true, stressEnabled: true, hrvEnabled: true, temperatureEnabled: true
    )
}

/// The user's profile, projected to the byte-ish shape a ring's user-preferences command expects.
/// Passed as a plain value from the app layer (the engine never reads SwiftData). Devices that don't
/// take a profile ignore it.
struct UserProfileValues: Sendable, Equatable {
    var metric: Bool
    /// Ring gender byte: 0x00 female, 0x01 male, 0x02 unspecified/other (Colmi convention).
    var gender: UInt8
    var age: UInt8
    var heightCm: UInt8
    var weightKg: UInt8

    /// Build from stored profile fields, clamping to byte ranges with neutral fallbacks.
    init(metric: Bool, sex: String?, age: Int?, heightCm: Double?, weightKg: Double?) {
        self.metric = metric
        switch sex?.lowercased() {
        case "female": gender = 0x00
        case "male": gender = 0x01
        default: gender = 0x02
        }
        self.age = UInt8(clamping: age ?? 25)
        self.heightCm = UInt8(clamping: Int((heightCm ?? 175).rounded()))
        self.weightKg = UInt8(clamping: Int((weightKg ?? 70).rounded()))
    }
}

/// Per-device orchestration of command flows. The jring engine is fire-and-forget (`handle` is a
/// no-op); the Colmi engine advances a 7-stage response-driven history machine inside `handle`.
/// Lives behind the driver so `RingBLEClient` / `RingSyncCoordinator` stay clean.
@MainActor
protocol RingSyncEngine: AnyObject {
    /// Run the connect-time sequence (status/time/locale/etc. for jring; phone-name/time/prefs +
    /// settings reads for Colmi).
    func runStartup()

    /// Advance any response-driven state machine. Called synchronously for every decoded event.
    func handle(_ event: RingDecodedEvent)

    // App-facing actions (the façade `RingSyncCoordinator` drives these).

    /// Start the *live/workout* HR stream (jring: 0x14; Colmi: realtime 0x1e + keepalive).
    func startHeartRate()
    func stopHeartRate()
    /// One-shot *spot* HR measurement (jring: same as start; Colmi: manual 0x69). Defaults to the
    /// live start/stop for engines that don't distinguish.
    func measureHeartRateSpot()
    func startSpO2()
    func stopSpO2()
    func findDevice()
    func setGoal(steps: Int)

    /// Store the user's all-day measurement configuration *without* sending anything — used just before
    /// `runStartup`, which emits the relevant commands as part of the connect handshake (so we don't
    /// double-send). Devices without a configurable interval ignore it (default no-op below).
    func setMeasurementSettings(_ settings: MeasurementSettings)

    /// Apply the user's all-day measurement configuration *now* (store + send) — the live "Save" path
    /// while connected, so changes take effect without waiting for a reconnect. Devices without a
    /// configurable interval ignore it (default no-op below).
    func applyMeasurementSettings(_ settings: MeasurementSettings)

    /// Store the user's profile *without* sending — used just before `runStartup`, which sends the
    /// user-preferences command as part of the handshake. Devices that don't take a profile ignore it.
    func setUserProfile(_ profile: UserProfileValues)

    /// Apply the user's profile *now* (store + send) — the live path when the profile screen saves.
    func applyUserProfile(_ profile: UserProfileValues)
}

extension RingSyncEngine {
    /// Default: a spot measurement is just the live start (jring has no separate manual command).
    func measureHeartRateSpot() { startHeartRate() }

    /// Default: devices that don't expose a configurable interval (e.g. the generic jring) ignore
    /// measurement settings entirely.
    func setMeasurementSettings(_ settings: MeasurementSettings) {}
    func applyMeasurementSettings(_ settings: MeasurementSettings) {}

    /// Default: devices that don't accept a user profile ignore it.
    func setUserProfile(_ profile: UserProfileValues) {}
    func applyUserProfile(_ profile: UserProfileValues) {}
}
