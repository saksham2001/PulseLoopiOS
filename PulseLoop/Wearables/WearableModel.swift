import SwiftUI

/// A selectable ring model for the pairing carousel — purely presentational, layered over the
/// persisted `RingDeviceType` family. Several models (the whole Colmi/Yawell line) map to the same
/// `family`/driver; this catalog just gives each a name, tint, and one-line capability blurb so the
/// user can swipe and say "this is my ring."
///
/// `family` decides which coordinator/driver the scan should accept. Swapping the stylized vector art
/// for real product photos later only needs an added `imageName` consumed by `RingArtView`.
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
    /// Asset-catalog image name for this ring's product art. When nil, `RingArtView` falls back to
    /// the stylized vector torus. Set this per model once real ring images are added to the catalog.
    var imageName: String? = nil
}

extension WearableModel {
    // "jring" is intentionally lowercase — that's how the brand styles its name (kept as-is in the tab).
    static let jring = WearableModel(
        id: "jring", displayName: "jring", brand: "jring", family: .jring,
        tint: PulseColors.accent, blurb: "Heart rate · SpO₂ · Sleep",
        advertisedNamePatterns: ["^SMART_RING$"], imageName: "jring"
    )

    // Colmi line — all share the Colmi protocol/driver (family .colmiR02).
    static let colmiR02 = colmiFamily("colmi-r02", "Colmi R02", brand: "Colmi", pattern: "^R02_.*")
    static let colmiR03 = colmiFamily("colmi-r03", "Colmi R03", brand: "Colmi", pattern: "^R03_.*")
    static let colmiR06 = colmiFamily("colmi-r06", "Colmi R06", brand: "Colmi", pattern: "^R06_.*")
    static let colmiR07 = colmiFamily("colmi-r07", "Colmi R07", brand: "Colmi", pattern: "^COLMI R07_.*")
    static let colmiR09 = colmiFamily("colmi-r09", "Colmi R09", brand: "Colmi", pattern: "^R09_.*")
    static let colmiR10 = colmiFamily("colmi-r10", "Colmi R10", brand: "Colmi", pattern: "^COLMI R10_.*")
    static let colmiR11 = colmiFamily(
        "colmi-r11", "Colmi R11", brand: "Colmi", pattern: "^R11C_[0-9A-F]{4}$", imageName: "yawell-r11"
    )
    static let colmiR12 = colmiFamily("colmi-r12", "Colmi R12", brand: "Colmi", pattern: "^COLMI R12_.*")

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
        colmiR02, colmiR03, colmiR06, colmiR07, colmiR09, colmiR10, colmiR11, colmiR12,
        yawellR05, yawellR10, yawellR11, h59,
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
