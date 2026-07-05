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
    /// Asset-catalog image name for this ring's product art. When nil, `RingArtView` falls back to
    /// the stylized vector torus. Set this per model once real ring images are added to the catalog.
    var imageName: String? = nil
}

extension WearableModel {
    // "jring" is intentionally lowercase — that's how the brand styles its name (kept as-is in the tab).
    static let jring = WearableModel(
        id: "jring", displayName: "jring", brand: "jring", family: .jring,
        tint: PulseColors.accent, blurb: "Heart rate · SpO₂ · Sleep", imageName: "jring"
    )

    // Colmi line — all share the Colmi protocol/driver (family .colmiR02).
    static let colmiR02 = colmiFamily("colmi-r02", "Colmi R02", brand: "Colmi")
    static let colmiR03 = colmiFamily("colmi-r03", "Colmi R03", brand: "Colmi")
    static let colmiR06 = colmiFamily("colmi-r06", "Colmi R06", brand: "Colmi")
    static let colmiR07 = colmiFamily("colmi-r07", "Colmi R07", brand: "Colmi")
    static let colmiR09 = colmiFamily("colmi-r09", "Colmi R09", brand: "Colmi")
    static let colmiR10 = colmiFamily("colmi-r10", "Colmi R10", brand: "Colmi")
    static let colmiR12 = colmiFamily("colmi-r12", "Colmi R12", brand: "Colmi")

    // Yawell-branded variants of the same hardware.
    static let yawellR05 = colmiFamily("yawell-r05", "Yawell R05", brand: "Yawell")
    static let yawellR10 = colmiFamily("yawell-r10", "Yawell R10", brand: "Yawell")
    static let yawellR11 = colmiFamily("yawell-r11", "Yawell R11", brand: "Yawell")
    static let h59 = colmiFamily("h59", "H59 Ring", brand: "H59")

    private static func colmiFamily(_ id: String, _ name: String, brand: String) -> WearableModel {
        // Asset-catalog image name matches the model id (see PulseLoop/Assets.xcassets).
        WearableModel(
            id: id, displayName: name, brand: brand, family: .colmiR02,
            tint: PulseColors.hrv, blurb: "HR · SpO₂ · HRV · Stress · Temp · Sleep", imageName: id
        )
    }

    /// Every supported model. The pairing screen groups these by `brand` and sorts each tab
    /// alphabetically, so this array's order is not user-visible.
    static let catalog: [WearableModel] = [
        jring,
        colmiR02, colmiR03, colmiR06, colmiR07, colmiR09, colmiR10, colmiR12,
        yawellR05, yawellR10, yawellR11, h59,
    ]
}
