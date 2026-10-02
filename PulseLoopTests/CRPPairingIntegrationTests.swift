import XCTest
@testable import PulseLoop

@MainActor
final class CRPPairingIntegrationTests: XCTestCase {
    /// The CRP card is a deliberately narrow exception to the single-firmware rule: `SMART_RING`
    /// scans as jring, while a service-bearing sibling scans as CRP. Both are safe to force onto the
    /// selected CRP driver; no unrelated family (or wholly unidentified row) is.
    func testCRPCardOverridesOnlyItsAmbiguousScanFamilies() {
        let card = WearableModel.colmiR11CRP
        XCTAssertEqual(card.forcedFamilyScanMatches, [.jring, .crp])

        for scanFamily in [RingDeviceType.jring, .crp] {
            XCTAssertTrue(card.acceptsScanFamily(scanFamily))
            XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: scanFamily, hinted: nil), .crp)
        }

        for scanFamily in [RingDeviceType.colmiR02, .colmiSmartHealth, .tk5, .luckRing, .ycbt, .rwfit] {
            XCTAssertFalse(card.acceptsScanFamily(scanFamily))
            XCTAssertNil(card.preferredFamily(picked: nil, rowFamily: scanFamily, hinted: nil))
        }
        XCTAssertFalse(card.acceptsScanFamily(nil))
        XCTAssertNil(card.preferredFamily(picked: nil, rowFamily: nil, hinted: nil))
    }

    /// A user-selected carousel model is stronger evidence than a name-derived scan identity. The CRP
    /// R11 is the concrete collision: its `SMART_RING` name infers jring even after the user chose CRP.
    func testExplicitModelIDOutranksScanInference() {
        XCTAssertEqual(
            RingBLEClient.modelIDForConnect(
                selectedModelID: WearableModel.colmiR11CRP.id,
                scanInferredModelID: WearableModel.jring.id
            ),
            WearableModel.colmiR11CRP.id
        )
        XCTAssertEqual(
            RingBLEClient.modelIDForConnect(selectedModelID: nil, scanInferredModelID: WearableModel.jring.id),
            WearableModel.jring.id
        )
    }

    /// End-to-end pure regression for the original failure: every helper previously looked correct in
    /// isolation, but their composition installed jring and discarded the user's CRP model selection.
    func testCRPSmartRingTapResolvesTheCRPDriverAndModel() {
        let card = WearableModel.colmiR11CRP
        let scanFamily = RingDeviceType.jring
        let preferredFamily = card.preferredFamily(picked: nil, rowFamily: scanFamily, hinted: nil)
        let coordinator = RingBLEClient.coordinatorType(
            preferredFamily: preferredFamily,
            autoMatched: scanFamily
        )
        let modelID = RingBLEClient.modelIDForConnect(
            selectedModelID: card.id,
            scanInferredModelID: WearableModel.jring.id
        )
        let resolved = WearableModel.resolve(
            advertisedName: "SMART_RING",
            selectedModelID: modelID,
            family: coordinator.deviceType
        )

        XCTAssertEqual(preferredFamily, .crp)
        XCTAssertEqual(coordinator.deviceType, .crp)
        XCTAssertEqual(modelID, card.id)
        XCTAssertEqual(resolved?.id, card.id)
    }

    /// Sleep is decoded and persisted for CRP, so it must pass the metric capability gate. Temperature
    /// history is not decoded yet and must not advertise an empty card.
    func testCRPCapabilitiesMatchDeliveredMetrics() {
        let capabilities = CRPCoordinator().capabilities
        XCTAssertTrue(capabilities.contains(.sleep))
        XCTAssertFalse(capabilities.contains(.temperature))
    }
}
