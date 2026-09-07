import XCTest
@testable import PulseLoop

/// The HRV panel exists on exactly one record — the YCBT `05 33` body data — so it must be invisible
/// on every ring that can't produce it, and offered only when the ring itself claims the bit that
/// gates that record. These pin both directions across all six supported families.
@MainActor
final class HrvDetailCapabilityTests: XCTestCase {

    /// Every coordinator, and everything it could ever grant (baseline plus bitmap-gated).
    private var everyFamily: [(name: String, granted: Set<WearableCapability>)] {
        let coordinators: [any WearableCoordinator] = [
            JringCoordinator(), ColmiCoordinator(), LuckRingCoordinator(),
            ColmiSmartHealthCoordinator(), TK5Coordinator(), YCBTCoordinator(),
        ]
        return coordinators.map {
            ("\(type(of: $0))", $0.capabilities.union($0.bitmapGatedCapabilities))
        }
    }

    // MARK: - Which families can ever offer it

    /// The jring's `0x24` packet, the Colmi QRing's big-data channel and the LuckRing's K6 dataTypes
    /// carry a single HRV scalar and nothing to break it down. None of them may claim the panel by
    /// any route — the Autonomic screen is simply absent there.
    func testNonYCBTFamiliesNeverOfferTheHrvPanel() {
        let ycbtFamilies = ["ColmiSmartHealthCoordinator", "TK5Coordinator", "YCBTCoordinator"]
        for family in everyFamily where !ycbtFamilies.contains(family.name) {
            XCTAssertFalse(family.granted.contains(.hrvDetail),
                           "\(family.name) has no body-data record and must not claim .hrvDetail")
        }
    }

    /// …and all three YCBT families can, since they share one driver and one record.
    func testEveryYCBTFamilyCanOfferTheHrvPanel() {
        let coordinators: [any WearableCoordinator] = [
            ColmiSmartHealthCoordinator(), TK5Coordinator(), YCBTCoordinator(),
        ]
        for coordinator in coordinators {
            XCTAssertTrue(coordinator.bitmapGatedCapabilities.contains(.hrvDetail),
                          "\(type(of: coordinator)) should defer the panel to the ring's own bitmap")
            XCTAssertFalse(coordinator.capabilities.contains(.hrvDetail),
                           "\(type(of: coordinator)): a baseline entry would be an unconditional promise")
        }
    }

    // MARK: - The bit itself

    /// The panel rides `IS_HAS_PRESSURE` (byte 22, bit 6) — the bit the vendor app gates the whole
    /// `05 33` query on — so it is claimed exactly when stress and fatigue are.
    func testPanelIsClaimedWithStressAndFatigue() {
        var bitmap = [UInt8](repeating: 0, count: 32)
        bitmap[22] = 1 << 6
        let claimed = YCBTSupportFunction.capabilities(from: bitmap)

        XCTAssertTrue(claimed.contains(.hrvDetail))
        XCTAssertTrue(claimed.contains(.stress))
        XCTAssertTrue(claimed.contains(.fatigue))
    }

    /// `ISHASHRV` (byte 1, bit 1) governs the single HRV scalar, which reaches the app from the
    /// `05 09` combined record and the `06 03` live stream. A ring with HRV but no body-data record
    /// must get the scalar and *not* the panel — this is the distinction the separate capability exists
    /// to draw.
    func testHrvScalarBitAloneDoesNotGrantThePanel() {
        var bitmap = [UInt8](repeating: 0, count: 32)
        bitmap[1] = 1 << 1
        let claimed = YCBTSupportFunction.capabilities(from: bitmap)

        XCTAssertTrue(claimed.contains(.hrv), "the scalar is claimed")
        XCTAssertFalse(claimed.contains(.hrvDetail), "the breakdown is not")
    }

    /// The real R99 (firmware 2.32) leaves `IS_HAS_PRESSURE` clear — byte 22 is `0x20`, bit 5 not
    /// bit 6 — and NAKs `05 33` outright. It must resolve to no panel, exactly as it resolves to no
    /// stress and no fatigue.
    func testTheRealR99GetsNoPanel() {
        let claimed: [UInt8] = [
            0xf9, 0x09, 0x00, 0x00, 0x00, 0x00, 0x0c, 0xd8,
            0x10, 0x04, 0x01, 0xb2, 0xb6, 0x00, 0x40, 0x0f,
            0x00, 0x14, 0x50, 0x00, 0x00, 0x00, 0x20, 0x00,
        ]
        let bitmap = claimed + [UInt8](repeating: 0, count: 60 - claimed.count)
        let derived = YCBTSupportFunction.capabilities(from: bitmap)
        XCTAssertFalse(derived.contains(.hrvDetail))

        let refined = ColmiSmartHealthCoordinator().refinedCapabilities(bitmapDerived: derived)
        XCTAssertFalse(refined.contains(.hrvDetail),
                       "a ring that NAKs the body-data record must not offer its fields")
    }

    /// A truncated or garbage bitmap means "no opinion", so the family baseline stands — and since
    /// the panel is never a baseline entry, that resolves to no panel rather than to one granted by
    /// accident.
    func testATruncatedBitmapDoesNotGrantThePanel() {
        for length in [0, 5, 13] {
            let refined = TK5Coordinator().refinedCapabilities(
                bitmapDerived: YCBTSupportFunction.capabilities(from: [UInt8](repeating: 0xFF, count: length))
            )
            XCTAssertFalse(refined.contains(.hrvDetail), "length \(length)")
        }
    }

    // MARK: - Persistence round-trip

    /// Capabilities persist as a CSV on `Device`, so a newly appended case has to survive the trip —
    /// otherwise the panel would vanish whenever the set is read back from the store rather than the
    /// live connection.
    func testPanelCapabilitySurvivesTheCSVRoundTrip() {
        let original: Set<WearableCapability> = [.heartRate, .hrv, .hrvDetail, .stress]
        XCTAssertEqual(Set(csv: original.csv), original)
        XCTAssertTrue(original.csv.contains("hrvDetail"))
    }

    // MARK: - The kinds it gates

    /// The panel's `MeasurementKind`s deliberately have no `MetricKey`, which is what keeps them off
    /// Today and Vitals entirely — they are reachable only through the HRV detail screen.
    func testPanelKindsAreNotDashboardMetrics() {
        let dashboardKinds = Set(MetricKey.allCases.map(\.rawValue))
        for kind in MeasurementKind.autonomicKinds {
            XCTAssertFalse(dashboardKinds.contains(kind.rawValue),
                           "\(kind) must not be a dashboard card — it lives behind the HRV screen")
        }
    }
}
