import XCTest
import CoreBluetooth
import UIKit
@testable import PulseLoop

/// The pairing flow must recognize the whole Colmi/Yawell ring family by advertised name (they all
/// share `ColmiDriver`), without the jring coordinator wrongly claiming them.
///
/// Since Phase B it must also do something strictly harder: separate the *two* Colmi families, which
/// speak entirely different protocols. That is why the advertisement is only a hint here and the user's
/// app-type pick is the authority — the cross-claim matrix below pins the hint's behavior, and
/// `testPreferredFamilyOverridesAutoMatch` pins the override that makes a wrong hint harmless.
///
/// The hint got a lot better once real hardware turned up: the owner's `R99 54DC` and the TK5 both name
/// themselves `<MODEL> <4 hex>`, while every QRing-Colmi uses an underscore. The tests below hold that
/// split in place from both sides — the R99 must land on the YCBT stack, and no QRing-Colmi may.
@MainActor
final class PairingMatchingTests: XCTestCase {
    private let noAdv = AdvertisementInfo(serviceUUIDs: [], manufacturerData: nil)

    private func bytes(_ hex: String) -> Data {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<n], radix: 16)!)
            i = n
        }
        return Data(out)
    }

    /// A SmartHealth-family advertisement: the `1078` Yucheng company ID in manufacturer data, no QRing
    /// service. Still PROVISIONAL — the `R99 54DC` capture logged GATT only, never a scan record — which
    /// is why the marker now only corroborates and the *name* decides.
    private var smartHealthAdv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [], manufacturerData: bytes("10780a01aabbccdd"))
    }

    /// A QRing-Colmi: advertises the Nordic-UART-style service, no SmartHealth marker.
    private var qringAdv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [CBUUID(string: ColmiUUIDs.serviceV1)], manufacturerData: nil)
    }

    /// The TK5's real capture: `10786501…` — note it *contains* `1078`, so only the name half of the
    /// SmartHealth conjunction keeps it out of the Colmi family.
    private var tk5Adv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [], manufacturerData: bytes("10786501000101120000000000"))
    }

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
        // `R99 54DC` is a Colmi *ring*, but not a QRing one: its card's family is `.colmiSmartHealth`, so
        // the GadgetBridge-derived coordinator must leave it alone.
        for name in ["SMART_RING", "Mi Band 5", "Galaxy Watch", "R0X_NOPE", "Random", "R99 54DC"] {
            XCTAssertFalse(colmiMatches(name), "did not expect Colmi match for \(name)")
        }
    }

    /// The owner's ring, claimed by exactly one coordinator — and not by the three it could plausibly be
    /// confused with.
    func testOnlyTheSmartHealthCoordinatorClaimsTheR99() {
        for advertisement in [noAdv, smartHealthAdv] {
            XCTAssertTrue(ColmiSmartHealthCoordinator.matches(name: "R99 54DC", advertisement: advertisement))
            XCTAssertFalse(ColmiCoordinator.matches(name: "R99 54DC", advertisement: advertisement))
            XCTAssertFalse(TK5Coordinator.matches(name: "R99 54DC", advertisement: advertisement))
            XCTAssertFalse(JringCoordinator.matches(name: "R99 54DC", advertisement: advertisement))
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
        // Every family every carousel card can resolve to — including via its app variants — must have a
        // registered coordinator, or picking that variant would silently fall back to the jring driver.
        let registeredTypes = Set(RingBLEClient.coordinators.map { $0.deviceType })
        for model in WearableModel.catalog {
            for family in model.families {
                XCTAssertTrue(registeredTypes.contains(family), "no coordinator for \(model.displayName) (\(family))")
            }
        }
    }

    // MARK: - Registry cross-claim matrix (B3)

    /// The one ordering constraint in the registry, stated as a test so a re-sort can't silently break
    /// it: behind `ColmiCoordinator` — whose matcher needs only the name — no SmartHealth ring would
    /// ever be claimed.
    func testSmartHealthColmiPrecedesQRingColmi() {
        let order = RingBLEClient.coordinators.map { $0.deviceType }
        guard let smartHealth = order.firstIndex(of: .colmiSmartHealth),
              let qring = order.firstIndex(of: .colmiR02) else {
            return XCTFail("both Colmi coordinators must be registered")
        }
        XCTAssertLessThan(smartHealth, qring)
    }

    /// Registry order + each coordinator's matcher, end to end: every ring lands on exactly one driver.
    ///
    /// The R99 rows are the point of the whole exercise: the owner's ring (`R99 54DC`) has to land on
    /// `.colmiSmartHealth` from its *name alone*, because its advertisement is the one thing the nRF
    /// capture didn't record.
    /// One row of the cross-claim matrix. A struct rather than a tuple: four anonymous members read as
    /// noise at the call site, and the labels are the whole point of the table.
    private struct ClaimCase {
        let label: String
        let name: String?
        let advertisement: AdvertisementInfo
        let expected: RingDeviceType?
    }

    func testRegistryCrossClaimMatrix() {
        let cases: [ClaimCase] = [
            ClaimCase(label: "jring", name: "SMART_RING", advertisement: noAdv, expected: .jring),
            ClaimCase(label: "QRing-Colmi advertising its service", name: "R09_00AA", advertisement: qringAdv, expected: .colmiR02),
            ClaimCase(label: "QRing-Colmi with a bare advertisement", name: "R09_00AA", advertisement: noAdv, expected: .colmiR02),
            // Underscore = QRing, and the marker no longer overrides that (it may well be on a QRing ring
            // too — every ring in this SDK family carries the Yucheng company ID).
            ClaimCase(label: "QRing-Colmi carrying the Yucheng company ID", name: "R09_00AA", advertisement: smartHealthAdv, expected: .colmiR02),
            ClaimCase(label: "QRing-Colmi (COLMI-prefixed name)", name: "COLMI R10_xyz", advertisement: smartHealthAdv, expected: .colmiR02),
            ClaimCase(label: "R99, name only — the capture we actually have", name: "R99 54DC", advertisement: noAdv, expected: .colmiSmartHealth),
            ClaimCase(label: "R99 with the Yucheng company ID", name: "R99 54DC", advertisement: smartHealthAdv, expected: .colmiSmartHealth),
            ClaimCase(label: "R99 lowercase hex suffix", name: "R99 54dc", advertisement: noAdv, expected: .colmiSmartHealth),
            ClaimCase(label: "TK5", name: "TK5 24AA", advertisement: tk5Adv, expected: .tk5),
            ClaimCase(label: "TK5, name only", name: "TK5 24AA", advertisement: noAdv, expected: .tk5),
            ClaimCase(label: "unknown peripheral", name: "Galaxy Watch", advertisement: noAdv, expected: nil),
        ]
        for ring in cases {
            XCTAssertEqual(
                RingBLEClient.matchDeviceType(name: ring.name, advertisement: ring.advertisement),
                ring.expected,
                ring.label
            )
        }
    }

    /// The TK5's own manufacturer data (`10786501…`) starts with the `1078` marker — every ring in this
    /// SDK family does, so the marker cannot separate them and the *name* is what does. `TK5 24AA` is a
    /// name the catalog resolves to a `.tk5`-only card, so this coordinator (registered *ahead* of
    /// `TK5Coordinator`) stands aside even though the name is space-separated like its own family's.
    func testSmartHealthColmiDoesNotClaimTheTK5() {
        XCTAssertTrue(tk5Adv.manufacturerData!.hexString.hasPrefix(
            ColmiSmartHealthCoordinator.Advertisement.manufacturerHexMarker
        ))
        // The TK5's name is in the SmartHealth *shape* — so only the catalog lookup keeps it out.
        XCTAssertTrue(ColmiSmartHealthCoordinator.Advertisement.isSmartHealthName("TK5 24AA"))
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "TK5 24AA", advertisement: tk5Adv))
        XCTAssertTrue(TK5Coordinator.matches(name: "TK5 24AA", advertisement: tk5Adv))
        // …and an *unnamed* ring carrying the TK5's fuller prefix stays the TK5's, too: the marker
        // fallback below must not steal it from a coordinator that comes after us in the registry.
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "Unlabeled", advertisement: tk5Adv))
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "Unlabeled", advertisement: tk5Adv), .tk5)
    }

    /// The marker lives in the manufacturer data's **company-ID slot**, so it is matched as a prefix. An
    /// unanchored substring test over the hex string is not even byte-aligned — mfr bytes `a1 07 8f`
    /// stringify to `"a1078f"` — and Colmi's manufacturer payload commonly embeds the MAC, so an unlucky
    /// ring would be tagged as the SmartHealth family, defaulting the picker (and the first connect) to a
    /// protocol its firmware doesn't speak.
    func testSmartHealthMarkerIsAnchoredToTheCompanyIDSlot() {
        let straddling = AdvertisementInfo(serviceUUIDs: [], manufacturerData: bytes("a1078fcc"))
        XCTAssertTrue(straddling.manufacturerData!.hexString.contains("1078"))   // the trap it must not fall into
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "Unlabeled", advertisement: straddling))
        XCTAssertNil(RingBLEClient.matchDeviceType(name: "Unlabeled", advertisement: straddling))
    }

    /// The rule, term by term: the name decides, the QRing service vetoes, and the marker only speaks
    /// when nothing else can.
    func testSmartHealthColmiMatchesOnTheNamingConvention() {
        // `<MODEL> <4 hex>` on a card that can be this family → claimed, with or without any manufacturer
        // data. This is the whole fix: the R99's advertisement is exactly what we do *not* have.
        XCTAssertTrue(ColmiSmartHealthCoordinator.matches(name: "R99 54DC", advertisement: noAdv))
        XCTAssertTrue(ColmiSmartHealthCoordinator.matches(name: "R99 54DC", advertisement: smartHealthAdv))
        // The underscore convention is the QRing line — the marker's presence must not promote it.
        for name in ["R02_ABCD", "COLMI R10_1234", "R11C_ABCD", "H59_1234", "R05_1A2B", "R11_BEEF"] {
            XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: name, advertisement: smartHealthAdv), name)
            XCTAssertEqual(RingBLEClient.matchDeviceType(name: name, advertisement: noAdv), .colmiR02, name)
        }
        // A jring is neither.
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "SMART_RING", advertisement: smartHealthAdv))
        // A QRing service disqualifies outright, however the ring names itself — the R99 included.
        for uuid in ColmiSmartHealthCoordinator.Advertisement.qringServiceUUIDs {
            for advertisement in [
                AdvertisementInfo(serviceUUIDs: [uuid], manufacturerData: nil),
                AdvertisementInfo(serviceUUIDs: [uuid], manufacturerData: smartHealthAdv.manufacturerData),
            ] {
                XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "R99 54DC", advertisement: advertisement))
                XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "R09_00AA", advertisement: advertisement))
                // It answers to the *other* driver, and `ColmiCoordinator` claims it by service UUID.
                XCTAssertEqual(
                    RingBLEClient.matchDeviceType(name: "R99 54DC", advertisement: advertisement), .colmiR02
                )
            }
        }
        // Nothing names it, but it carries the Yucheng company ID: a YCBT ring, and this family — whose
        // sensors are bitmap-gated rather than assumed — is the conservative home for one.
        XCTAssertTrue(ColmiSmartHealthCoordinator.matches(name: "Unlabeled", advertisement: smartHealthAdv))
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "Unlabeled", advertisement: noAdv))
    }

    // MARK: - The user's pick is authoritative (B4)

    /// The load-bearing rule of the whole variant design: an explicit family beats the auto-match. This
    /// is what makes the provisional advertisement heuristic safe to be wrong — in *either* direction.
    func testPreferredFamilyOverridesAutoMatch() {
        func family(preferred: RingDeviceType?, autoMatched: RingDeviceType?) -> RingDeviceType {
            RingBLEClient.coordinatorType(preferredFamily: preferred, autoMatched: autoMatched).deviceType
        }
        // The hint said QRing, the user says SmartHealth (and vice versa) — the user wins both ways.
        XCTAssertEqual(family(preferred: .colmiSmartHealth, autoMatched: .colmiR02), .colmiSmartHealth)
        XCTAssertEqual(family(preferred: .colmiR02, autoMatched: .colmiSmartHealth), .colmiR02)
        // A ring the scan recognized as nothing still gets the declared driver, not the jring fallback.
        XCTAssertEqual(family(preferred: .colmiSmartHealth, autoMatched: nil), .colmiSmartHealth)
        // No declaration → the auto-match still rules, unchanged.
        XCTAssertEqual(family(preferred: nil, autoMatched: .tk5), .tk5)
        XCTAssertEqual(family(preferred: nil, autoMatched: .colmiR02), .colmiR02)
        XCTAssertEqual(family(preferred: nil, autoMatched: .jring), .jring)
        // Neither → jring, preserving the pre-existing reconnect-to-unknown-peripheral behavior.
        XCTAssertEqual(family(preferred: nil, autoMatched: nil), .jring)
    }

    // MARK: - Which ring a tap actually connects (B4)

    /// The card-level hint is taken from whichever ring sorted first in the scan — which, with two Colmi
    /// rings in range, is not necessarily the one the user tapped. This user owns exactly that pair, so
    /// the tapped row's *own* scan tag has to outrank the hint: otherwise tapping the correctly-identified
    /// SmartHealth R09 while a nearer QRing ring set the hint would install `ColmiDriver` against a YCBT
    /// ring — the auto-match was right and we'd have overridden it with a hint from another peripheral.
    func testATappedRowOutranksAHintSourcedFromAnotherRing() {
        let card = WearableModel.colmiR09
        // Hint says QRing (from the other ring); the tapped row is the SmartHealth one.
        XCTAssertEqual(card.variant(picked: nil, rowFamily: .colmiSmartHealth, hinted: .qring), .smartHealth)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: .colmiSmartHealth, hinted: .qring), .colmiSmartHealth)
        // …and the mirror image: a SmartHealth hint must not drag a QRing-tagged row onto the YCBT stack.
        XCTAssertEqual(card.variant(picked: nil, rowFamily: .colmiR02, hinted: .smartHealth), .qring)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: .colmiR02, hinted: .smartHealth), .colmiR02)
    }

    /// The rule the whole design rests on, one level up from `testPreferredFamilyOverridesAutoMatch`: the
    /// user's pick beats even a row the scan claimed. Only the *scan* is a hint; the human is not.
    func testAnExplicitPickOutranksTheRowsOwnTag() {
        let card = WearableModel.colmiR09
        XCTAssertEqual(card.preferredFamily(picked: .smartHealth, rowFamily: .colmiR02, hinted: .qring), .colmiSmartHealth)
        XCTAssertEqual(card.preferredFamily(picked: .qring, rowFamily: .colmiSmartHealth, hinted: .smartHealth), .colmiR02)
    }

    /// A row the scan recognized as nothing is fair game for the card's hint/default — the alternative is
    /// the jring fallback, which is certainly wrong. A row it recognized as *another family* is not:
    /// forcing the carousel's family on it would hand a jring the Colmi driver merely because the user
    /// hadn't swiped away from the Colmi card.
    func testUnrecognizedRowsTakeTheCardDefaultAndUnrelatedRowsKeepTheirOwnDriver() {
        let card = WearableModel.colmiR09
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: nil, hinted: .smartHealth), .colmiSmartHealth)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: nil, hinted: nil), .colmiR02)   // card default
        XCTAssertNil(card.preferredFamily(picked: .smartHealth, rowFamily: .jring, hinted: .smartHealth))
        XCTAssertNil(card.preferredFamily(picked: .smartHealth, rowFamily: .tk5, hinted: nil))
        // Single-firmware cards never override anything: jring/TK5 pairing is auto-detection, as before.
        for model in [WearableModel.jring, WearableModel.tk5] {
            XCTAssertNil(model.variant(picked: .smartHealth, rowFamily: .colmiSmartHealth, hinted: .smartHealth))
            XCTAssertNil(model.preferredFamily(picked: .smartHealth, rowFamily: nil, hinted: .smartHealth))
        }
    }

    /// The R99 is the one card whose *default* is SmartHealth — its capture says so. It still offers both
    /// apps: a confirmed unit is not a confirmed SKU, and without the picker the connect-failure copy
    /// ("switch the app type and try again") would point at a control that doesn't exist.
    func testTheR99CardDefaultsToSmartHealthAndKeepsTheEscapeHatch() {
        let card = WearableModel.colmiR99
        XCTAssertEqual(card.family, .colmiSmartHealth)
        XCTAssertEqual(card.brand, WearableModel.colmiR09.brand)          // lives on the Colmi tab
        XCTAssertEqual(card.families, [.colmiSmartHealth, .colmiR02])
        XCTAssertEqual(card.appVariants.map(\.variant), [.qring, .smartHealth])
        // Untouched picker, unrecognized row, no hint → the card's own default, not the first segment.
        XCTAssertEqual(card.variant(picked: nil, rowFamily: nil, hinted: nil), .smartHealth)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: nil, hinted: nil), .colmiSmartHealth)
        // The scan tags the row itself, which is what a tap actually connects as.
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: .colmiSmartHealth, hinted: nil), .colmiSmartHealth)
        // …and a QRing hint borrowed from a neighbouring Colmi must not drag it onto the wrong driver.
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: .colmiSmartHealth, hinted: .qring), .colmiSmartHealth)
        // The user still outranks everything, in both directions.
        XCTAssertEqual(card.preferredFamily(picked: .qring, rowFamily: .colmiSmartHealth, hinted: nil), .colmiR02)
        XCTAssertEqual(card.otherVariant(than: .smartHealth), .qring)
        XCTAssertEqual(card.supportLevel, .limited)
        // No R99 art exists; nil is the only value `RingArtView` has a fallback for.
        XCTAssertNil(card.imageName)
    }

    func testColmiCardsOfferBothAppsAndTK5OffersNone() {
        for model in WearableModel.catalog where model.family == .colmiR02 {
            XCTAssertEqual(model.appVariants.map(\.variant), [.qring, .smartHealth], model.displayName)
            XCTAssertEqual(model.families, [.colmiR02, .colmiSmartHealth], model.displayName)
            XCTAssertEqual(model.family(for: .qring), .colmiR02)
            XCTAssertEqual(model.family(for: .smartHealth), .colmiSmartHealth)
            XCTAssertEqual(model.family(for: nil), .colmiR02)   // untouched picker = the card's default
            XCTAssertEqual(model.variant(for: .colmiSmartHealth), .smartHealth)
            XCTAssertEqual(model.otherVariant(than: .smartHealth), .qring)
            XCTAssertEqual(model.otherVariant(than: .qring), .smartHealth)
            XCTAssertNotEqual(model.blurb(for: .smartHealth), model.blurb(for: .qring))
        }
        // Single-firmware cards: no picker, no override, no behavior change anywhere.
        for model in [WearableModel.jring, WearableModel.tk5] {
            XCTAssertTrue(model.appVariants.isEmpty, model.displayName)
            XCTAssertEqual(model.families, [model.family], model.displayName)
            XCTAssertEqual(model.blurb(for: .smartHealth), model.blurb, model.displayName)
            XCTAssertEqual(model.family(for: .smartHealth), model.family, model.displayName)
            XCTAssertNil(model.otherVariant(than: .qring), model.displayName)
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
            "R99 54DC": "colmi-r99",
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

    /// A Colmi connecting as `.colmiSmartHealth` is still a "Colmi R09" — without variant-aware resolve
    /// it would identify as no model at all and the device card would lose its name and product art.
    func testResolveIsVariantAware() {
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: "R09_00AA", selectedModelID: nil, family: .colmiSmartHealth)?.id,
            "colmi-r09"
        )
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: "R09_00AA", selectedModelID: nil, family: .colmiR02)?.id,
            "colmi-r09"
        )
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: nil, selectedModelID: "colmi-r10", family: .colmiSmartHealth)?.id,
            "colmi-r10"
        )
        // The R99 connects as `.colmiSmartHealth` by default, and is still a "Colmi R99" if the user
        // overrides the picker to QRing.
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: "R99 54DC", selectedModelID: nil, family: .colmiSmartHealth)?.id,
            "colmi-r99"
        )
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: "R99 54DC", selectedModelID: nil, family: .colmiR02)?.id,
            "colmi-r99"
        )
        // A card that can't be this family still doesn't resolve to it.
        XCTAssertNil(WearableModel.resolve(advertisedName: "TK5 24AA", selectedModelID: nil, family: .colmiSmartHealth))
        XCTAssertNil(WearableModel.resolve(advertisedName: "R09_00AA", selectedModelID: nil, family: .tk5))
        XCTAssertNil(WearableModel.resolve(advertisedName: "R99 54DC", selectedModelID: nil, family: .tk5))
    }

    func testUnknownLegacyColmiHasNoExactModel() {
        XCTAssertNil(WearableModel.resolve(advertisedName: nil, selectedModelID: nil, family: .colmiR02))
        XCTAssertEqual(RingDeviceType.colmiR02.displayName, "Colmi / Yawell ring")
        XCTAssertEqual(RingDeviceType.colmiSmartHealth.displayName, "Colmi ring (SmartHealth)")
    }

    func testColmiR11ReusesYawellR11Image() {
        XCTAssertEqual(WearableModel.colmiR11.imageName, WearableModel.yawellR11.imageName)
    }

    // MARK: - SmartHealth-Colmi capabilities (B3)

    /// The two YCBT families drive one shared stack, so this family can only ever claim what the stack
    /// implements — i.e. a subset of everything the TK5 could ever resolve to. A capability outside that
    /// is a card that can never fill.
    ///
    /// "Could ever resolve to" is baseline ∪ gated on both sides now: the TK5 gates its own sensors too,
    /// so comparing against its *baseline* alone would say the shared stack cannot deliver temperature —
    /// which it plainly can, for either family, the moment a ring claims the bit.
    func testSmartHealthColmiClaimsNothingTheYCBTStackCannotDeliver() {
        let colmi = ColmiSmartHealthCoordinator()
        let tk5 = TK5Coordinator()
        let everythingItCouldClaim = colmi.capabilities.union(colmi.bitmapGatedCapabilities)
        let everythingTheStackDelivers = tk5.capabilities.union(tk5.bitmapGatedCapabilities)
        XCTAssertTrue(everythingItCouldClaim.isSubset(of: everythingTheStackDelivers))
        // It must not inherit jring-only or QRing-only actions the YCBT stack has no command for.
        for absent: WearableCapability in [.combinedVitalsMeasurement, .powerOff, .factoryReset] {
            XCTAssertFalse(everythingItCouldClaim.contains(absent), absent.rawValue)
        }
    }

    /// A gate no bit can ever satisfy is not a deferred decision — it is a dead promise: it reads as
    /// "supported if the ring says so" while being permanently unreachable. Every gated capability, in
    /// *either* YCBT family, must be derivable from the bitmap parser.
    ///
    /// This is the invariant that shaped the `.fatigue` decision: it has no bit of its own, so it could
    /// only be gated once `YCBTSupportFunction` derived it from the bit the vendor app actually gates its
    /// record on (`IS_HAS_PRESSURE` — the whole `05 33` body-data query). Baseline entries are exempt:
    /// they are promises we make on our own evidence, not deferrals to the ring.
    func testEveryGatedCapabilityIsDerivableFromTheBitmap() {
        let allOnes = [UInt8](repeating: 0xFF, count: 32)
        let derivable = YCBTSupportFunction.capabilities(from: allOnes)
        for coordinator in [ColmiSmartHealthCoordinator(), TK5Coordinator()] as [any WearableCoordinator] {
            let gated = coordinator.bitmapGatedCapabilities
            XCTAssertFalse(gated.isEmpty, "\(type(of: coordinator)) gates nothing")
            XCTAssertTrue(gated.isSubset(of: derivable), "\(type(of: coordinator)): \(gated.subtracting(derivable))")
            // A gated capability the baseline already grants would be a no-op wearing a gate's clothes.
            XCTAssertTrue(coordinator.capabilities.isDisjoint(with: gated), "\(type(of: coordinator))")
        }
    }

    /// The `02 01` bitmap the owner's `R99 54DC` (firmware 2.32) actually sent — 60 bytes, of which the
    /// first 24 are its reply **verbatim** and the tail is zero padding. No mapped bit lives past byte 23
    /// and every length gate the parser applies (14 / 18 / 23 / 24) is cleared either way, so the padding
    /// cannot change what this resolves to. It is the best fixture we will ever have: a real ring's answer.
    private var r99SupportBitmap: [UInt8] {
        let claimed: [UInt8] = [
            0xf9, 0x09, 0x00, 0x00, 0x00, 0x00, 0x0c, 0xd8,
            0x10, 0x04, 0x01, 0xb2, 0xb6, 0x00, 0x40, 0x0f,
            0x00, 0x14, 0x50, 0x00, 0x00, 0x00, 0x20, 0x00,
        ]
        return claimed + [UInt8](repeating: 0, count: 60 - claimed.count)
    }

    /// **The bug this family's gating exists to prevent, caught on real hardware.** The R99 does not have
    /// an HRV sensor: its bitmap leaves `ISHASHRV` clear, it NAKs the HRV monitor (`01 45`) and the
    /// body-data history (`05 33`) with `0xFC`, and it refuses the HRV measurement start outright
    /// (`03 2f` mode `0x0a` → status `0x01`). While `.hrv`/`.manualHrv` were *baseline*, none of that
    /// mattered — a baseline entry is an unconditional promise — so Vitals rendered a "Measure HRV"
    /// button that spun for 45 s and failed, every time.
    ///
    /// This pins the exact set the ring now resolves to, from its own bytes.
    func testTheRealR99BitmapResolvesToWhatTheRingActuallyHas() {
        let claimed = YCBTSupportFunction.capabilities(from: r99SupportBitmap)
        // What the ring itself claims — the four denials above start here, with a clear HRV bit.
        XCTAssertEqual(claimed, [
            .steps, .sleep, .heartRate, .bloodPressure, .spo2,
            .manualHeartRate, .manualBloodPressure, .manualSpo2,
        ])

        let refined = ColmiSmartHealthCoordinator().refinedCapabilities(bitmapDerived: claimed)
        XCTAssertEqual(refined, [
            .heartRate, .spo2, .spo2History, .steps, .sleep, .remSleep, .battery,
            .bloodPressure, .manualBloodPressure,
            .manualHeartRate, .manualSpo2,
            .realtimeHeartRate, .realtimeSteps,
            .findDevice, .measurementInterval,
        ])
        // The gate earning its keep in both directions: BP was claimed (and a spot BP measurement on this
        // ring returned 100/68), while nothing it stayed silent about is offered.
        for absent: WearableCapability in [.hrv, .manualHrv, .temperature, .stress, .bloodSugar, .fatigue] {
            XCTAssertFalse(refined.contains(absent), "the R99 does not claim \(absent.rawValue)")
        }
    }

    /// **The TK5 keeps its HRV — and only its HRV — through the R99 fix.**
    ///
    /// The R99 taught the TK5 the same lesson, but not the same conclusion, because the evidence points
    /// the other way. The TK5's HRV was *observed on the ring* (48 / 79 ms, cross-checked against the
    /// vendor app); the R99's was denied four independent ways. So HRV stays an unconditional baseline
    /// promise on the TK5 even when fed the R99's own HRV-denying bitmap — a bitmap can never remove a
    /// baseline capability, which is exactly what makes a baseline entry the place for something we have
    /// *seen work*. (It also could only lose: no TK5 `02 01` reply has ever been captured, and
    /// `.manualHrv` sits at byte 23 behind the SDK's 24-byte block gate.)
    ///
    /// What the TK5 no longer promises unconditionally is the sensors nobody has seen it use.
    func testTK5KeepsItsHRVThroughTheR99Fix() {
        let tk5 = TK5Coordinator()
        XCTAssertTrue(tk5.capabilities.isSuperset(of: [.hrv, .manualHrv]))
        XCTAssertTrue(tk5.bitmapGatedCapabilities.isDisjoint(with: [.hrv, .manualHrv]))

        let refined = tk5.refinedCapabilities(
            bitmapDerived: YCBTSupportFunction.capabilities(from: r99SupportBitmap)
        )
        XCTAssertTrue(refined.contains(.hrv))
        XCTAssertTrue(refined.contains(.manualHrv))
    }

    /// **A TK5 that claims nothing gets its baseline, and not one sensor more.** The bug this fixes: the
    /// TK5 baselined `.temperature`, `.stress`, `.fatigue` and `.bloodSugar` because the *SDK* defines
    /// their record types (`05 1E`, `05 33`, `05 2F`) — not because a TK5 was ever seen producing one. A
    /// baseline entry is an unconditional promise, so those four rendered cards, and "Measure now"
    /// buttons, that may never fill. The R99 is what that costs when the ring disagrees.
    ///
    /// A ring that claims nothing — an all-zero bitmap, a truncated reply, or no reply at all — now
    /// resolves to exactly the TK5's baseline, and not one sensor more.
    func testTK5WithASensorDenyingBitmapResolvesToItsBaselineOnly() {
        let tk5 = TK5Coordinator()
        let expectedBaseline: Set<WearableCapability> = [
            .heartRate, .spo2, .spo2History, .steps, .battery,
            .hrv, .manualHrv,
            .sleep, .remSleep,
            .manualHeartRate, .manualSpo2,
            .realtimeHeartRate, .realtimeSteps,
            .findDevice, .measurementInterval,
        ]
        XCTAssertEqual(tk5.capabilities, expectedBaseline)

        let claimsNothing = YCBTSupportFunction.capabilities(from: [UInt8](repeating: 0, count: 27))
        XCTAssertEqual(claimsNothing, [])
        for derived in [Set<WearableCapability>(), claimsNothing] {
            let refined = tk5.refinedCapabilities(bitmapDerived: derived)
            XCTAssertEqual(refined, expectedBaseline)
            for absent: WearableCapability in [
                .temperature, .stress, .fatigue, .bloodSugar, .bloodPressure, .manualBloodPressure,
            ] {
                XCTAssertFalse(refined.contains(absent), "an unclaimed \(absent.rawValue) must not be offered")
            }
        }
    }

    /// The gate is per-bit, not all-or-nothing — so a *partly* claiming ring gets exactly the parts it
    /// claimed. Fed the R99's real bytes (the only YCBT bitmap we have from hardware): it claims BP and
    /// on-demand BP — and a spot BP on that ring really did return 100/68 — while staying silent about
    /// temperature, stress, fatigue and blood sugar, which are therefore withheld.
    func testTK5WithThePartlyClaimingR99BitmapGetsOnlyWhatWasClaimed() {
        let tk5 = TK5Coordinator()
        let refined = tk5.refinedCapabilities(
            bitmapDerived: YCBTSupportFunction.capabilities(from: r99SupportBitmap)
        )
        XCTAssertEqual(refined, tk5.capabilities.union([.bloodPressure, .manualBloodPressure]))
        for absent: WearableCapability in [.temperature, .stress, .fatigue, .bloodSugar] {
            XCTAssertFalse(refined.contains(absent), "an unclaimed \(absent.rawValue) must not be offered")
        }
    }

    /// …and a TK5 whose bitmap claims the sensors gets them — every one of them, so nothing the ring
    /// really has was lost in the move. The union is the *old* unconditional set exactly.
    func testTK5WithASensorClaimingBitmapResolvesToTheFullSet() {
        let tk5 = TK5Coordinator()
        let claimsEverything = YCBTSupportFunction.capabilities(from: [UInt8](repeating: 0xFF, count: 27))
        let refined = tk5.refinedCapabilities(bitmapDerived: claimsEverything)

        XCTAssertEqual(refined, [
            .heartRate, .spo2, .spo2History, .steps, .battery,
            .hrv, .manualHrv, .bloodPressure, .manualBloodPressure,
            .temperature, .stress, .fatigue, .bloodSugar,
            .sleep, .remSleep,
            .manualHeartRate, .manualSpo2,
            .realtimeHeartRate, .realtimeSteps,
            .findDevice, .measurementInterval,
        ])
        XCTAssertEqual(refined, tk5.capabilities.union(tk5.bitmapGatedCapabilities))
    }

    /// **`.fatigue` is gated on the stress bit, because the ring gives them one switch.** There is no
    /// `ISHASFATIGUE` in the SDK; what there is, is `DataSyncUtils` gating the *entire* body-data query
    /// (`05 33` — the record that carries both scores, as its `pressure` and `body` fields) on
    /// `IS_HAS_PRESSURE`. A ring with that bit clear is never even asked for the record, so it can no more
    /// produce a fatigue score than a stress one. The two therefore arrive and depart together.
    func testFatigueAndStressAreClaimedTogetherOrNotAtAll() {
        let tk5 = TK5Coordinator()
        var bodyDataRing = [UInt8](repeating: 0, count: 27)
        bodyDataRing[22] = 1 << 6                                        // IS_HAS_PRESSURE

        let claimed = YCBTSupportFunction.capabilities(from: bodyDataRing)
        XCTAssertEqual(claimed, [.stress, .fatigue])

        let refined = tk5.refinedCapabilities(bitmapDerived: claimed)
        XCTAssertEqual(refined, tk5.capabilities.union([.stress, .fatigue]))
        // Never one without the other, whichever way the bit falls.
        XCTAssertEqual(refined.contains(.stress), refined.contains(.fatigue))
        let silent = tk5.refinedCapabilities(bitmapDerived: [])
        XCTAssertEqual(silent.contains(.stress), silent.contains(.fatigue))
    }

    /// The gated set resolves through B2's additive-only refinement formula: a silent ring keeps the
    /// baseline, a claiming ring gains exactly what it claimed, and nothing outside the pre-approved
    /// list can ever be added.
    func testBitmapRefinementForTheSmartHealthColmi() {
        let colmi = ColmiSmartHealthCoordinator()
        // Baseline and gated are disjoint — a gated capability the baseline already grants is a no-op.
        XCTAssertTrue(colmi.capabilities.isDisjoint(with: colmi.bitmapGatedCapabilities))
        // A ring that claims nothing (or answers with a truncated bitmap): the baseline stands.
        XCTAssertEqual(colmi.refinedCapabilities(bitmapDerived: []), colmi.capabilities)
        // A ring with a temperature + BP sensor gains exactly those two…
        XCTAssertEqual(
            colmi.refinedCapabilities(bitmapDerived: [.temperature, .bloodPressure]),
            colmi.capabilities.union([.temperature, .bloodPressure])
        )
        // …and a bitmap claiming something the family never pre-approved cannot conjure it up.
        XCTAssertEqual(colmi.refinedCapabilities(bitmapDerived: [.powerOff]), colmi.capabilities)
    }

    // MARK: - Support level

    func testSupportLevelIsPerFamily() {
        XCTAssertEqual(RingDeviceType.jring.supportLevel, .full)
        XCTAssertEqual(RingDeviceType.colmiR02.supportLevel, .full)
        XCTAssertEqual(RingDeviceType.tk5.supportLevel, .limited)
        XCTAssertEqual(RingDeviceType.colmiSmartHealth.supportLevel, .limited)
    }

    /// Both YCBT families are unproven, and only unproven families get a badge. The two cards that
    /// *default* to one — the TK5 and the R99 — therefore wear it as they sit; a two-app Colmi card wears
    /// it only while its picker is on SmartHealth (the same physical ring, a different driver's maturity).
    func testLimitedSupportFamiliesCarryTheBadge() {
        let limitedByDefault: Set<String> = [WearableModel.tk5.id, WearableModel.colmiR99.id]
        for model in WearableModel.catalog {
            let expected: WearableSupportLevel = limitedByDefault.contains(model.id) ? .limited : .full
            XCTAssertEqual(model.supportLevel, expected, model.displayName)
            XCTAssertEqual(
                model.supportLevel.badgeLabel,
                expected == .limited ? "Limited support" : nil,
                model.displayName
            )
        }
        for model in WearableModel.catalog where !model.appVariants.isEmpty {
            XCTAssertEqual(model.supportLevel(for: .qring), .full, model.displayName)
            XCTAssertEqual(model.supportLevel(for: .smartHealth), .limited, model.displayName)
        }
    }

    // MARK: - Wrong-choice failure path (B5)

    /// The message a stalled connect shows. It has to name both apps: the one we tried (so the user knows
    /// what was attempted) and the one to try instead (so the failure is actionable in one tap).
    func testConnectFailureMessageNamesBothApps() {
        for family: RingDeviceType in [.colmiSmartHealth, .colmiR02] {
            let message = RingConnectFailure.message(family: family)
            XCTAssertTrue(message.contains("QRing"), message)
            XCTAssertTrue(message.contains("SmartHealth"), message)
        }
        // The one we tried is named first — the sentence is "didn't answer as a <tried> ring".
        XCTAssertTrue(RingConnectFailure.message(family: .colmiSmartHealth)
            .hasPrefix("This ring didn't answer as a SmartHealth ring."))
        XCTAssertTrue(RingConnectFailure.message(family: .colmiR02)
            .hasPrefix("This ring didn't answer as a QRing ring."))
    }

    /// A single-firmware family has no other app to suggest, so it must not offer one.
    func testConnectFailureMessageIsGenericWithoutVariants() {
        for family: RingDeviceType? in [.jring, .tk5, nil] {
            let message = RingConnectFailure.message(family: family)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("QRing"), message)
            XCTAssertFalse(message.contains("SmartHealth"), message)
        }
    }

    func testAppVariantMapsToAndFromItsFamily() {
        XCTAssertEqual(RingAppVariant(family: .colmiR02), .qring)
        XCTAssertEqual(RingAppVariant(family: .colmiSmartHealth), .smartHealth)
        XCTAssertNil(RingAppVariant(family: .jring))
        XCTAssertNil(RingAppVariant(family: .tk5))
        XCTAssertEqual(RingAppVariant.qring.other, .smartHealth)
        XCTAssertEqual(RingAppVariant.smartHealth.other, .qring)
    }

    /// Every catalog model must name an imageset that exists, or `RingArtView` renders an empty
    /// platter (a non-nil `imageName` has no fallback path). Resolve against the app bundle rather
    /// than `.main` so this holds whether or not the test target is hosted.
    func testEveryCatalogImageNameResolvesToAnAsset() {
        let appBundle = Bundle(for: RingBLEClient.self)
        for model in WearableModel.catalog {
            guard let imageName = model.imageName else { continue }
            XCTAssertNotNil(
                UIImage(named: imageName, in: appBundle, compatibleWith: nil),
                "missing imageset '\(imageName)' for \(model.displayName)"
            )
        }
        XCTAssertEqual(WearableModel.tk5.imageName, "tk5")
        // The R99 ships no art of its own, so it takes the generic-ring path — which only a *nil*
        // `imageName` gets: an unregistered name renders an empty platter.
        XCTAssertNil(WearableModel.colmiR99.imageName)
        XCTAssertNotNil(UIImage(named: RingArtView.fallbackImage, in: appBundle, compatibleWith: nil))
    }
}
