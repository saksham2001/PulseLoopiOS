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
    let family: RingDeviceType
    let tint: Color
    let blurb: String
}

extension WearableModel {
    static let jring = WearableModel(
        id: "jring", displayName: "jring", family: .jring,
        tint: PulseColors.accent, blurb: "Heart rate · SpO₂ · Sleep"
    )

    // Colmi line — all share the Colmi protocol/driver (family .colmiR02).
    static let colmiR02 = colmi("colmi-r02", "Colmi R02")
    static let colmiR03 = colmi("colmi-r03", "Colmi R03")
    static let colmiR06 = colmi("colmi-r06", "Colmi R06")
    static let colmiR07 = colmi("colmi-r07", "Colmi R07")
    static let colmiR09 = colmi("colmi-r09", "Colmi R09")
    static let colmiR10 = colmi("colmi-r10", "Colmi R10")
    static let colmiR12 = colmi("colmi-r12", "Colmi R12")

    // Yawell-branded variants of the same hardware.
    static let yawellR05 = colmi("yawell-r05", "Yawell R05")
    static let yawellR10 = colmi("yawell-r10", "Yawell R10")
    static let yawellR11 = colmi("yawell-r11", "Yawell R11")
    static let h59 = colmi("h59", "H59 Ring")

    private static func colmi(_ id: String, _ name: String) -> WearableModel {
        WearableModel(
            id: id, displayName: name, family: .colmiR02,
            tint: PulseColors.hrv, blurb: "HR · SpO₂ · HRV · Stress · Temp · Sleep"
        )
    }

    /// Carousel order: the most common cheap models first.
    static let catalog: [WearableModel] = [
        colmiR02, colmiR06, colmiR10, yawellR11, jring,
        colmiR03, colmiR07, colmiR09, colmiR12,
        yawellR05, yawellR10, h59,
    ]
}
