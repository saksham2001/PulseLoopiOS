import XCTest
import SwiftData
@testable import PulseLoop

/// What `RingBLEClient` remembers about a ring *between* connections: its family, its exact catalog
/// model, and what its own capability bitmap claimed.
///
/// All three have to be re-adopted before a new session publishes its first `.deviceIdentified`, because
/// that event overwrites the persisted `Device` row wholesale — anything the client can't name at that
/// moment is not merely missing from the UI, it is erased from the store.
@MainActor
final class RingIdentityMemoryTests: XCTestCase {
    private let deviceTypeKey = "ring.lastDeviceType"
    private let modelKey = "ring.lastWearableModel"
    private let capabilitiesKey = "ring.lastCapabilities"

    /// An R09 whose `02 01` bitmap claimed a temperature sensor on a previous connect.
    private var rememberedSmartHealthCapabilities: Set<WearableCapability> {
        ColmiSmartHealthCoordinator().capabilities.union([.temperature])
    }

    /// Seed (and, on teardown, clear) the client's cross-connection memory. Starts from a clean slate so
    /// a test never inherits another's — or a previous run's — remembered ring.
    private func remember(deviceType: String? = nil, model: String? = nil, capabilities: Set<WearableCapability>? = nil) {
        let defaults = UserDefaults.standard
        let keys = [deviceTypeKey, modelKey, capabilitiesKey]
        keys.forEach { defaults.removeObject(forKey: $0) }
        addTeardownBlock {
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        deviceType.map { defaults.set($0, forKey: deviceTypeKey) }
        model.map { defaults.set($0, forKey: modelKey) }
        capabilities.map { defaults.set($0.csv, forKey: capabilitiesKey) }
    }

    /// iOS killed the app mid-session and relaunched it for a BLE event. `willRestoreState` has no
    /// advertisement to re-derive anything from, so it re-adopts what was remembered. Before it did, the
    /// restored session reached `.connected` with a nil model id and nulled `Device.wearableModelID` —
    /// the device card lost its name and product art until some later reconnect happened to carry a
    /// resolvable GAP name.
    func testRestoredSessionReadoptsFamilyModelAndClaimedCapabilities() {
        remember(deviceType: "colmiSmartHealth", model: "colmi-r09", capabilities: rememberedSmartHealthCapabilities)
        let client = RingBLEClient(startManager: false)

        client.adoptRememberedIdentity()

        XCTAssertEqual(client.activeDeviceType, .colmiSmartHealth)
        XCTAssertEqual(client.activeWearableModelID, "colmi-r09")
        XCTAssertTrue(client.activeCapabilities.contains(.temperature))
    }

    /// The bitmap arrives partway into a handshake; `Device.capabilitiesRaw` is overwritten at the start
    /// of one. So a connect that never gets an answer — a dropped `02 01` reply, or firmware that answers
    /// with a short array — must not be able to strip a capability the ring already told us it has: the
    /// Vitals/Today cards for it would vanish for the whole session *and* while offline afterwards.
    func testAConnectWhoseBitmapNeverArrivesKeepsWhatTheRingAlreadyClaimed() {
        remember(capabilities: rememberedSmartHealthCapabilities)
        let client = RingBLEClient(startManager: false)

        client.installDriver(ColmiSmartHealthCoordinator.self)   // no `.supportFunctions` follows

        XCTAssertEqual(client.activeCapabilities, rememberedSmartHealthCapabilities)
    }

    /// The seed is fed through the same additive-only refinement as the bitmap itself, so it can only
    /// re-grant what *this* family gates. A set remembered from another ring can't leak a sensor into a
    /// family that has none — which is also why jring and QRing-Colmi (which gate nothing) are provably
    /// untouched by any of this.
    func testRememberedCapabilitiesCannotLeakIntoAFamilyThatGatesNothing() {
        remember(capabilities: TK5Coordinator().capabilities)
        let client = RingBLEClient(startManager: false)

        client.installDriver(JringCoordinator.self)
        XCTAssertEqual(client.activeCapabilities, JringCoordinator().capabilities)

        client.installDriver(ColmiCoordinator.self)
        XCTAssertEqual(client.activeCapabilities, ColmiCoordinator().capabilities)
    }

    /// Nothing remembered (a first-ever pairing): the family baseline, exactly as before.
    func testAFirstConnectStartsFromTheFamilyBaseline() {
        remember()
        let client = RingBLEClient(startManager: false)
        client.installDriver(ColmiSmartHealthCoordinator.self)
        XCTAssertEqual(client.activeCapabilities, ColmiSmartHealthCoordinator().capabilities)
        XCTAssertFalse(client.activeCapabilities.contains(.temperature))
    }

    /// The TK5 gates its sensors now, so it needs the same two guarantees the R99 got — and this is the
    /// one that protects an existing owner.
    ///
    /// **A TK5 whose bitmap already told us about a sensor keeps it**, even on a connect whose `02 01`
    /// reply is lost or answered short: `installDriver` seeds from the remembered *refined* set, through
    /// the same additive-only refinement, so a temperature card the ring earned does not blink out and
    /// come back a second later on every launch.
    ///
    /// **And a first-ever TK5 connect that never sees a bitmap degrades to the baseline, not to nothing**
    /// — HR, SpO₂, HRV, sleep and steps still work; only the unconfirmed sensors are withheld.
    func testTK5CapabilityMemorySurvivesAConnectWithNoBitmap() {
        let earnedTemperature = TK5Coordinator().capabilities.union([.temperature])
        remember(capabilities: earnedTemperature)
        let client = RingBLEClient(startManager: false)

        client.installDriver(TK5Coordinator.self)   // no `.supportFunctions` follows

        XCTAssertEqual(client.activeCapabilities, earnedTemperature)
        XCTAssertTrue(client.activeCapabilities.contains(.temperature))
    }

    func testAFirstTK5ConnectWithNoBitmapDegradesToTheBaselineNotToNothing() {
        remember()
        let client = RingBLEClient(startManager: false)

        client.installDriver(TK5Coordinator.self)

        XCTAssertEqual(client.activeCapabilities, TK5Coordinator().capabilities)
        XCTAssertTrue(client.activeCapabilities.isSuperset(of: [.heartRate, .spo2, .hrv, .sleep, .steps]))
        for withheld: WearableCapability in [.temperature, .stress, .fatigue, .bloodSugar, .bloodPressure] {
            XCTAssertFalse(client.activeCapabilities.contains(withheld))
        }
    }

    // MARK: - The name that reaches the store

    private func identified(_ advertisedName: String?) -> PulseEvent {
        .deviceIdentified(
            deviceType: .colmiSmartHealth,
            wearableModelID: "colmi-r99",
            advertisedName: advertisedName,
            capabilities: []
        )
    }

    /// `Device.name` is what the human-facing surfaces read — the coach's device context, and the
    /// diagnostics export's `wearableName` — and nothing ever wrote it. It kept the `Device()` default,
    /// `"SMART_RING"` (the *jring's* name), so the owner's diagnostics for a Colmi R99 reported a jring:
    /// the one field in the export a human reads first, naming the wrong ring.
    func testTheAdvertisedNameBecomesTheDeviceName() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        subscriber.persist(identified("R99 54DC"))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "R99 54DC")
        XCTAssertEqual(device.advertisedName, "R99 54DC")
    }

    /// A name a *user* chose survives. `.deviceIdentified` is re-published on every handshake (and again
    /// whenever the capability bitmap refines the set), so anything that overwrites `name` unconditionally
    /// would undo a rename on the next connect — seconds later. Only a placeholder is ever replaced.
    func testAUserChosenNameIsNotClobberedByAReconnect() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("R99 54DC"))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        device.name = "Left hand"

        subscriber.persist(identified("R99 54DC"))   // the reconnect's re-published identity

        XCTAssertEqual(device.name, "Left hand")
        XCTAssertEqual(device.advertisedName, "R99 54DC", "the advertised name is still recorded")
    }

    /// A connect with no advertised name to offer (state restoration, a cached peripheral) leaves the
    /// name alone rather than blanking it.
    func testAConnectWithNoAdvertisedNameLeavesTheNameAlone() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("R99 54DC"))

        subscriber.persist(identified(nil))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "R99 54DC")
    }

    /// **A ring swap must not leave the previous ring's name behind.** There is one `Device` row and it is
    /// *reused* across pairings (`fetchDevices(context).first ?? Device()`), so an adopted name outlives
    /// the ring it came from unless Forget clears it — and an adopted name is neither empty nor a
    /// placeholder, so the "don't clobber a name the user chose" guard would then defend it against the new
    /// ring's own advertisement forever.
    ///
    /// Pair an R99, forget it, pair a TK5, and `Device.name` stayed "R99 54DC" while `deviceType`,
    /// `advertisedName` and `capabilities` all said TK5. The coach's `device_name` and the diagnostics
    /// export's `wearableName` then confidently named the ring that was *gone* — strictly worse than the
    /// old `SMART_RING` placeholder, because a real name reads as authoritative.
    func testForgettingARingReleasesItsNameForTheNextOne() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("R99 54DC"))

        subscriber.persist(.deviceForgotten)
        subscriber.persist(.deviceIdentified(
            deviceType: .tk5, wearableModelID: "tk5", advertisedName: "TK5 1A2B", capabilities: []
        ))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "TK5 1A2B", "the row must name the ring on the other end of the link")
        XCTAssertEqual(device.advertisedName, "TK5 1A2B")
        XCTAssertEqual(device.deviceType, .tk5)
    }

    /// Forget alone: nothing may keep naming a ring that is no longer paired, so the export taken between
    /// Forget and the next pairing names nothing rather than the ring the user just removed.
    func testForgettingARingLeavesNothingNamingIt() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("R99 54DC"))

        subscriber.persist(.deviceForgotten)

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "")
        XCTAssertNil(device.advertisedName)
        XCTAssertNil(device.wearableModelID)
    }

    /// The new ring may not advertise a name at all (state restoration, a cached peripheral). It must then
    /// fall back to *its own* family's placeholder — never inherit the forgotten ring's identity.
    func testARingThatAdvertisesNoNameFallsBackToItsOwnFamily() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("R99 54DC"))
        subscriber.persist(.deviceForgotten)

        subscriber.persist(.deviceIdentified(
            deviceType: .tk5, wearableModelID: "tk5", advertisedName: nil, capabilities: []
        ))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, RingDeviceType.tk5.displayName)
    }
}
