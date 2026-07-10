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
    let family: RingDeviceType
    let tint: Color
    let blurb: String
    /// Bluetooth local-name patterns that identify this exact product model. Protocol-family
    /// matching remains the coordinator's job; these patterns are only for user-facing identity.
    let advertisedNamePatterns: [String]
    /// Asset-catalog image name for this ring's product art. When nil, `RingArtView` falls back to a
    /// generic ring photo. Set this per model once real ring images are added to the catalog.
    var imageName: String? = nil

    /// Maturity of this model's driver, mirrored from its `family` (the real source of truth).
    var supportLevel: WearableSupportLevel { family.supportLevel }
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
        case .tk5: return .limited
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

    // TK5 — its own protocol (be940 service, SmartHealth app). Advertises as "TK5 <4 hex>".
    // Blurb mirrors `TK5Coordinator.capabilities`; the driver is `.limited` (see `supportLevel`).
    static let tk5 = WearableModel(
        id: "tk5", displayName: "TK5", brand: "TK", family: .tk5,
        tint: PulseColors.spo2, blurb: "HR · SpO₂ · HRV · BP · Sleep",
        advertisedNamePatterns: ["^TK5 ?[0-9A-Fa-f]{0,4}$"], imageName: "tk5"
    )

    // Yawell-branded variants of the same hardware.
    static let yawellR05 = colmiFamily("yawell-r05", "Yawell R05", brand: "Yawell", pattern: "^R05_[0-9A-F]{4}$")
    static let yawellR10 = colmiFamily("yawell-r10", "Yawell R10", brand: "Yawell", pattern: "^R10_[0-9A-F]{4}$")
    static let yawellR11 = colmiFamily("yawell-r11", "Yawell R11", brand: "Yawell", pattern: "^R11_[0-9A-F]{4}$")
    static let h59 = colmiFamily("h59", "H59 Ring", brand: "H59", pattern: "^H59_.*")

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
            tint: PulseColors.hrv, blurb: "HR · SpO₂ · HRV · Stress · Temp · Sleep",
            advertisedNamePatterns: [pattern], imageName: imageName ?? id
        )
    }

    /// Every supported model. The pairing screen groups these by `brand` and sorts each tab
    /// alphabetically, so this array's order is not user-visible.
    static let catalog: [WearableModel] = [
        jring,
        colmiR02, colmiR03, colmiR06, colmiR07, colmiR08, colmiR09, colmiR10, colmiR11, colmiR12,
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
    static func resolve(
        advertisedName: String?,
        selectedModelID: String?,
        family: RingDeviceType
    ) -> WearableModel? {
        if let detected = model(advertisedName: advertisedName), detected.family == family {
            return detected
        }
        if let selected = model(id: selectedModelID), selected.family == family {
            return selected
        }
        return family == .jring ? .jring : nil
    }
}
