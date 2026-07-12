import SwiftUI

/// A selectable ring model for the pairing carousel — purely presentational, layered over the
/// persisted `RingDeviceType` family. Several models (the whole Colmi/Yawell line) map to the same
/// `family`/driver; this catalog just gives each a name, tint, and one-line capability blurb so the
/// user can swipe and say "this is my ring."
///
/// `family` decides which coordinator/driver the scan should accept, and — via `supportLevel` — how
/// mature that driver is, which the pairing screen surfaces as a "Limited support" badge.
struct WearableModel: Identifiable {
    let id: String
    let displayName: String
    /// Marketing brand, used to group models under the pairing screen's brand tabs.
    let brand: String
    /// The family this card resolves to by default — i.e. when it has no `appVariants`, or before the
    /// user has picked one.
    let family: RingDeviceType
    let tint: Color
    let blurb: String
    /// Bluetooth local-name patterns that identify this exact product model. Protocol-family
    /// matching remains the coordinator's job; these patterns are only for user-facing identity.
    let advertisedNamePatterns: [String]
    /// Asset-catalog image name for this ring's product art. When nil, `RingArtView` falls back to a
    /// generic ring photo. Set this per model once real ring images are added to the catalog.
    var imageName: String? = nil
    /// The native apps this exact product is sold with, when there is more than one (the Colmi line).
    /// Empty for single-firmware models, which stay fully auto-detected and show no picker.
    var appVariants: [AppVariantOption] = []

    /// Maturity of this model's driver, mirrored from its `family` (the real source of truth).
    var supportLevel: WearableSupportLevel { family.supportLevel }
}

/// Which phone app a ring shipped with — and therefore which protocol its firmware speaks.
///
/// The Colmi line is sold with **two firmwares**: QRing's (the GadgetBridge-derived Yawell protocol)
/// and SmartHealth's (Yucheng YCBT — byte-identical to what the TK5 speaks). The local name is set by
/// the OEM, not by the app, so an R09 of either kind can advertise `R09_ABCD`: no part of the
/// advertisement reliably separates them. This is therefore a **user-declared** fact, asked for at
/// pairing, and the answer — not the scan — picks the driver.
///
/// Raw values are display copy; nothing persists them (the *family* is what's persisted).
enum RingAppVariant: String, CaseIterable, Identifiable, Sendable {
    case qring = "QRing"
    case smartHealth = "SmartHealth"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// The app whose driver serves this family, or nil for a family sold with only one app.
    /// Exhaustive on purpose: a new family must state whether it has a sibling.
    init?(family: RingDeviceType) {
        switch family {
        case .colmiR02: self = .qring
        case .colmiSmartHealth: self = .smartHealth
        case .jring, .tk5: return nil
        }
    }

    /// The sibling app — the one to offer after a wrong pick. There are exactly two.
    var other: RingAppVariant { self == .qring ? .smartHealth : .qring }
}

/// One entry in a model card's app-variant picker: the app, the driver family picking it selects, and
/// the capability blurb to show while it is picked (the two firmwares expose different metric sets).
struct AppVariantOption: Identifiable {
    let variant: RingAppVariant
    let family: RingDeviceType
    let blurb: String

    var id: String { variant.rawValue }
}

/// Copy for a user-initiated connect attempt that never completed. Pure, so the pairing screen's
/// recovery affordance and its tests reason about exactly the message `RingBLEClient` will show.
///
/// The wrong-app pick is the failure this exists for: choose SmartHealth for a QRing ring and the
/// installed driver looks for service UUIDs the ring does not have — the BLE link opens, GATT
/// discovery finds nothing, `.connected` never arrives. "Couldn't connect" would give the user nothing
/// to act on, so the message names the app we tried and the one to try instead.
enum RingConnectFailure {
    static func message(family: RingDeviceType?) -> String {
        guard let family, let variant = RingAppVariant(family: family) else {
            return "The ring didn't respond. Move it closer, wake it by tapping it, and try again."
        }
        return "This ring didn't answer as a \(variant.displayName) ring. If it came with the "
            + "\(variant.other.displayName) app, switch the app type and try again."
    }
}

/// How proven PulseLoop's driver for a wearable *family* is. Drives the "Limited support" badge in
/// pairing/onboarding/Settings. Families we've shipped and tested are `.full` and render no badge at
/// all; a family reconstructed from thin evidence is `.limited`.
enum WearableSupportLevel: Equatable {
    case full
    case limited

    /// Short pill text, or nil for `.full` so no badge renders.
    var badgeLabel: String? {
        switch self {
        case .full: return nil
        case .limited: return "Limited support"
        }
    }
}

extension RingDeviceType {
    /// How proven this family's driver is. Exhaustive on purpose: a new family must state its level.
    var supportLevel: WearableSupportLevel {
        switch self {
        case .jring, .colmiR02: return .full
        // Both YCBT families are unproven on hardware. The SmartHealth-Colmi has never been connected
        // at all — its advertisement, its capability bitmap and its history types are all still
        // predictions (plan B6 is what settles them).
        case .tk5, .colmiSmartHealth: return .limited
        }
    }
}

extension WearableModel {
    // "jring" is intentionally lowercase — that's how the brand styles its name (kept as-is in the tab).
    static let jring = WearableModel(
        id: "jring", displayName: "jring", brand: "jring", family: .jring,
        tint: PulseColors.accent, blurb: "HR · SpO₂ · Sleep",
        advertisedNamePatterns: ["^SMART_RING$"], imageName: "jring"
    )

    // Colmi line — all share the Colmi protocol/driver (family .colmiR02).
    static let colmiR02 = colmiFamily("colmi-r02", "Colmi R02", brand: "Colmi", pattern: "^R02_.*")
    static let colmiR03 = colmiFamily("colmi-r03", "Colmi R03", brand: "Colmi", pattern: "^R03_.*")
    static let colmiR06 = colmiFamily("colmi-r06", "Colmi R06", brand: "Colmi", pattern: "^R06_.*")
    static let colmiR07 = colmiFamily("colmi-r07", "Colmi R07", brand: "Colmi", pattern: "^COLMI R07_.*")
    static let colmiR08 = colmiFamily("colmi-r08", "Colmi R08", brand: "Colmi", pattern: "^R08_.*")
    static let colmiR09 = colmiFamily("colmi-r09", "Colmi R09", brand: "Colmi", pattern: "^R09_.*")
    static let colmiR10 = colmiFamily("colmi-r10", "Colmi R10", brand: "Colmi", pattern: "^COLMI R10_.*")
    static let colmiR11 = colmiFamily(
        "colmi-r11", "Colmi R11", brand: "Colmi", pattern: "^R11C_[0-9A-F]{4}$", imageName: "yawell-r11"
    )
    static let colmiR12 = colmiFamily("colmi-r12", "Colmi R12", brand: "Colmi", pattern: "^COLMI R12_.*")

    /// The R99 — the one SmartHealth-Colmi we have actually looked at (the owner's, captured with nRF
    /// Connect as `R99 54DC`). It stays under the **Colmi** brand tab because that is where its owner
    /// will look for it: it is a Colmi-line ring, it wears the Colmi ring art, and a brand tab of one
    /// would only hide it. What it does *not* share with the other Colmi cards is its default family —
    /// the capture shows the TK5's YCBT GATT and no QRing service at all, so `.colmiSmartHealth` is not
    /// a guess here, it is the observed firmware.
    ///
    /// It keeps the app-variant picker anyway. The card would otherwise promise recovery it can't give:
    /// `RingConnectFailure.message` tells a user whose connect stalls to "switch the app type and try
    /// again", and `PairingView.variantRetry` needs an `otherVariant` to offer. One confirmed unit is
    /// not a guarantee that no R99 ever shipped with QRing — the whole reason `RingAppVariant` exists —
    /// so the picker stays and simply defaults the other way (the default is `family`, not the first
    /// option; see `variant(picked:rowFamily:hinted:)`).
    ///
    /// No `imageName`: there is no R99 imageset, and a non-nil name that isn't registered renders an
    /// *empty* platter rather than falling back. nil is the supported path — `RingArtView.fallbackImage`
    /// is a generic Colmi ring, which is exactly what this is.
    static let colmiR99 = WearableModel(
        id: "colmi-r99", displayName: "Colmi R99", brand: "Colmi", family: .colmiSmartHealth,
        tint: PulseColors.hrv, blurb: smartHealthBlurb,
        advertisedNamePatterns: ["^R99 [0-9A-Fa-f]{4}$"],
        appVariants: colmiAppVariants
    )

    // TK5 — the YCBT protocol (be940 service, SmartHealth app), shared with the SmartHealth-flavoured
    // Colmi rings. Advertises as "TK5 <4 hex>", which is unambiguous, so it needs no app-variant picker.
    // Blurb mirrors `TK5Coordinator.capabilities` — the *baseline*, so it no longer promises BP: like the
    // rest of the TK5's per-SKU sensors, on-demand BP is now claimed from the ring's own capability
    // bitmap at connect time. The driver is `.limited` (see `supportLevel`).
    static let tk5 = WearableModel(
        id: "tk5", displayName: "TK5", brand: "TK", family: .tk5,
        tint: PulseColors.spo2, blurb: "HR · SpO₂ · HRV · Sleep · Steps",
        advertisedNamePatterns: ["^TK5 ?[0-9A-Fa-f]{0,4}$"], imageName: "tk5"
    )

    // Yawell-branded variants of the same hardware.
    static let yawellR05 = colmiFamily("yawell-r05", "Yawell R05", brand: "Yawell", pattern: "^R05_[0-9A-F]{4}$")
    static let yawellR10 = colmiFamily("yawell-r10", "Yawell R10", brand: "Yawell", pattern: "^R10_[0-9A-F]{4}$")
    static let yawellR11 = colmiFamily("yawell-r11", "Yawell R11", brand: "Yawell", pattern: "^R11_[0-9A-F]{4}$")
    static let h59 = colmiFamily("h59", "H59 Ring", brand: "H59", pattern: "^H59_.*")

    /// The blurbs differ because the firmwares do. The SmartHealth one lists only what *every* YCBT ring
    /// certainly does (`ColmiSmartHealthCoordinator.capabilities`); its per-SKU sensors — temperature,
    /// blood pressure, stress — are claimed at connect time from the ring's own capability bitmap, so
    /// promising them on the card would be a promise we can't keep for every unit.
    private static let qringBlurb = "HR · SpO₂ · HRV · Stress · Temp · Sleep"
    private static let smartHealthBlurb = "HR · SpO₂ · HRV · Sleep · Steps"

    /// Every Colmi-line ring is sold with one of two apps, so every Colmi card offers both — including
    /// the R99, whose firmware we *have* confirmed (a confirmed unit is not a confirmed SKU).
    ///
    /// The order here is the picker's segment order, nothing more: which option a card *starts* on is
    /// its own `family` (`variant(picked:rowFamily:hinted:)`), so one shared list serves both the
    /// QRing-by-default cards and the SmartHealth-by-default R99.
    private static let colmiAppVariants: [AppVariantOption] = [
        AppVariantOption(variant: .qring, family: .colmiR02, blurb: qringBlurb),
        AppVariantOption(variant: .smartHealth, family: .colmiSmartHealth, blurb: smartHealthBlurb),
    ]

    private static func colmiFamily(
        _ id: String,
        _ name: String,
        brand: String,
        pattern: String,
        imageName: String? = nil
    ) -> WearableModel {
        // Asset-catalog image name matches the model id (see PulseLoop/Assets.xcassets).
        WearableModel(
            id: id, displayName: name, brand: brand, family: .colmiR02,
            tint: PulseColors.hrv, blurb: qringBlurb,
            advertisedNamePatterns: [pattern], imageName: imageName ?? id,
            appVariants: colmiAppVariants
        )
    }

    // MARK: - App variants

    /// Every driver family this card can resolve to — its default plus each app variant's. The pairing
    /// screen filters discovered rows on this, so a Colmi row the scan tagged `.colmiSmartHealth` is
    /// still offered under the Colmi card the user is looking at.
    var families: Set<RingDeviceType> { Set([family] + appVariants.map(\.family)) }

    /// The driver family a picked app selects. `nil` (nothing picked, or a single-firmware card) keeps
    /// the card's default family, so non-variant models behave exactly as before.
    func family(for variant: RingAppVariant?) -> RingDeviceType {
        option(for: variant)?.family ?? self.family
    }

    /// The capability chips to show for a picked app — the two firmwares expose different metric sets.
    func blurb(for variant: RingAppVariant?) -> String {
        option(for: variant)?.blurb ?? self.blurb
    }

    func supportLevel(for variant: RingAppVariant?) -> WearableSupportLevel {
        family(for: variant).supportLevel
    }

    /// The app implied by a family this card can resolve to — used to default the picker from what the
    /// scan tagged a discovered row.
    func variant(for family: RingDeviceType) -> RingAppVariant? {
        appVariants.first { $0.family == family }?.variant
    }

    /// The app to drive when connecting to **one specific discovered row**, in strict precedence:
    /// the user's own pick, then the family the scan tagged *that row* with, then the card-level hint,
    /// then the card's default.
    ///
    /// `rowFamily` outranking `hinted` is the load-bearing part. The hint is a property of the *card*,
    /// taken from the first variant-mapped ring in the whole scan — which may be a completely different
    /// peripheral. With a QRing-Colmi and a SmartHealth-Colmi both in range (this project's owner has
    /// exactly that), letting the hint decide would drive one ring with the other ring's protocol even
    /// though the scan had already identified both correctly. A row that the scan claimed knows better
    /// than a hint borrowed from its neighbour; only a deliberate pick beats it.
    ///
    /// The last fallback is the card's **own default family**, not the first option in the picker: the
    /// R99 lists the same two apps as every other Colmi card but starts on SmartHealth, because that is
    /// the firmware its capture shows.
    ///
    /// nil for a single-firmware card (no picker, no override — auto-detection exactly as before).
    func variant(
        picked: RingAppVariant?,
        rowFamily: RingDeviceType?,
        hinted: RingAppVariant?
    ) -> RingAppVariant? {
        guard !appVariants.isEmpty else { return nil }
        return picked ?? rowFamily.flatMap(variant(for:)) ?? hinted ?? variant(for: family)
    }

    /// The family to *force* on a connect to one discovered row, or nil to leave the scan's auto-match
    /// in charge.
    ///
    /// Only an app-variant card overrides, and only for a row that could plausibly be it: forcing the
    /// carousel's family on an unrelated row would hand a jring the Colmi driver merely because the user
    /// hadn't swiped away from the Colmi card. A row the scan recognized as *nothing* is fair game — the
    /// alternative is the jring fallback, which is certainly wrong.
    func preferredFamily(
        picked: RingAppVariant?,
        rowFamily: RingDeviceType?,
        hinted: RingAppVariant?
    ) -> RingDeviceType? {
        guard let variant = variant(picked: picked, rowFamily: rowFamily, hinted: hinted) else { return nil }
        guard rowFamily.map(families.contains) ?? true else { return nil }
        return family(for: variant)
    }

    /// The other app on this card, offered as one-tap recovery after a wrong pick.
    func otherVariant(than variant: RingAppVariant) -> RingAppVariant? {
        appVariants.first { $0.variant != variant }?.variant
    }

    private func option(for variant: RingAppVariant?) -> AppVariantOption? {
        guard let variant else { return nil }
        return appVariants.first { $0.variant == variant }
    }

    /// Every supported model. The pairing screen groups these by `brand` and sorts each tab
    /// alphabetically, so this array's order is not user-visible.
    static let catalog: [WearableModel] = [
        jring,
        colmiR02, colmiR03, colmiR06, colmiR07, colmiR08, colmiR09, colmiR10, colmiR11, colmiR12,
        colmiR99,
        yawellR05, yawellR10, yawellR11, h59,
        tk5,
    ]

    static func model(id: String?) -> WearableModel? {
        guard let id else { return nil }
        return catalog.first { $0.id == id }
    }

    static func model(advertisedName: String?) -> WearableModel? {
        guard let advertisedName else { return nil }
        let range = NSRange(advertisedName.startIndex..<advertisedName.endIndex, in: advertisedName)
        return catalog.first { model in
            model.advertisedNamePatterns.contains { pattern in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                return regex.firstMatch(in: advertisedName, options: [], range: range) != nil
            }
        }
    }

    /// Bluetooth identity wins when available; the user's carousel choice is the fallback for
    /// service-only or otherwise generic advertisements.
    ///
    /// Matched on `families`, not `family`, so a card still identifies the ring once an app variant has
    /// re-pointed the connection at a different driver — an R09 connecting as `.colmiSmartHealth` is
    /// still a "Colmi R09", and without this it would resolve to no model at all and the device card
    /// would lose its name and product art.
    static func resolve(
        advertisedName: String?,
        selectedModelID: String?,
        family: RingDeviceType
    ) -> WearableModel? {
        if let detected = model(advertisedName: advertisedName), detected.families.contains(family) {
            return detected
        }
        if let selected = model(id: selectedModelID), selected.families.contains(family) {
            return selected
        }
        return family == .jring ? .jring : nil
    }
}
