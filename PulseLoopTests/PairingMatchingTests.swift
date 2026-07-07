import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The pairing flow must recognize the whole Colmi/Yawell ring family by advertised name (they all
/// share `ColmiDriver`), without the jring coordinator wrongly claiming them.
@MainActor
final class PairingMatchingTests: XCTestCase {
    private let noAdv = AdvertisementInfo(serviceUUIDs: [], manufacturerData: nil)

    private func colmiMatches(_ name: String) -> Bool {
        ColmiCoordinator.matches(name: name, advertisement: noAdv)
    }

    func testColmiFamilyNamesMatch() {
        let names = [
            "R02_A1B2", "R03_1234", "R06_FFFF", "COLMI R07_9", "R09_00AA",
            "COLMI R10_xyz", "COLMI R12_x", "R05_1A2B", "R10_DEAD", "R11_BEEF",
            "R11C_BEEF", "H59_anything",
        ]
        for name in names {
            XCTAssertTrue(colmiMatches(name), "expected Colmi match for \(name)")
        }
    }

    func testNonColmiNamesDoNotMatch() {
        for name in ["SMART_RING", "Mi Band 5", "Galaxy Watch", "R0X_NOPE", "Random"] {
            XCTAssertFalse(colmiMatches(name), "did not expect Colmi match for \(name)")
        }
    }

    func testColmiMatchesByServiceUUID() {
        let adv = AdvertisementInfo(serviceUUIDs: [CBUUID(string: ColmiUUIDs.serviceV1)], manufacturerData: nil)
        XCTAssertTrue(ColmiCoordinator.matches(name: "Unlabeled", advertisement: adv))
    }

    func testJringDoesNotClaimColmiNames() {
        XCTAssertFalse(JringCoordinator.matches(name: "R02_A1B2", advertisement: noAdv))
        XCTAssertTrue(JringCoordinator.matches(name: "SMART_RING", advertisement: noAdv))
    }

    func testCatalogFamiliesAreRegistered() {
        // Every model in the carousel maps to a family that has a registered coordinator.
        let registeredTypes = Set(RingBLEClient.coordinators.map { $0.deviceType })
        for model in WearableModel.catalog {
            XCTAssertTrue(registeredTypes.contains(model.family), "no coordinator for \(model.displayName)")
        }
    }

    func testAdvertisedNamesResolveToExactModels() {
        let expected = [
            "SMART_RING": "jring",
            "R02_A1B2": "colmi-r02",
            "R03_1234": "colmi-r03",
            "R06_FFFF": "colmi-r06",
            "COLMI R07_9": "colmi-r07",
            "R09_00AA": "colmi-r09",
            "COLMI R10_xyz": "colmi-r10",
            "R11C_BEEF": "colmi-r11",
            "COLMI R12_x": "colmi-r12",
            "R05_1A2B": "yawell-r05",
            "R10_DEAD": "yawell-r10",
            "R11_BEEF": "yawell-r11",
            "H59_anything": "h59",
        ]
        for (name, modelID) in expected {
            XCTAssertEqual(WearableModel.model(advertisedName: name)?.id, modelID, name)
        }
    }

    func testDetectedModelOverridesCarouselSelection() {
        let model = WearableModel.resolve(
            advertisedName: "COLMI R10_xyz",
            selectedModelID: WearableModel.colmiR02.id,
            family: .colmiR02
        )
        XCTAssertEqual(model?.id, WearableModel.colmiR10.id)
    }

    func testCarouselSelectionIsFallbackForGenericAdvertisement() {
        let model = WearableModel.resolve(
            advertisedName: "Unlabeled",
            selectedModelID: WearableModel.colmiR12.id,
            family: .colmiR02
        )
        XCTAssertEqual(model?.id, WearableModel.colmiR12.id)
    }

    func testUnknownLegacyColmiHasNoExactModel() {
        XCTAssertNil(WearableModel.resolve(advertisedName: nil, selectedModelID: nil, family: .colmiR02))
        XCTAssertEqual(RingDeviceType.colmiR02.displayName, "Colmi / Yawell ring")
    }

    func testColmiR11ReusesYawellR11Image() {
        XCTAssertEqual(WearableModel.colmiR11.imageName, WearableModel.yawellR11.imageName)
    }
}
