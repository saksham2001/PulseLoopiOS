import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for generic YCBT / SmartHealth rings that belong to neither the Colmi line nor the TK5 —
/// the **LittleMeatball R10M** is the hardware-validated unit (FCF4, firmware 2.32).
///
/// The *protocol* is not R10M-specific: the ring speaks YCBT, so the driver, encoder, decoder and sync
/// engine it builds are the shared `YCBT*` types. This file is the whole of what makes an R10M an R10M —
/// its advertised identity, its capability set, and the two firmware quirks carried in
/// `YCBTFamilyProfile`.
///
/// ## Why a separate family rather than another `.colmiSmartHealth` card
///
/// `.colmiSmartHealth` is the Colmi line's SmartHealth firmware; its capability baseline, its product art
/// and its app-variant picker are all Colmi facts. The R10M is a different vendor's ring that happens to
/// speak the same protocol. Folding it in would have it inherit Colmi art and Colmi claims, and would put
/// an "is this a QRing or a SmartHealth ring?" question in front of a user whose ring only ever shipped
/// one firmware.
@MainActor
final class YCBTCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .ycbt

    /// The R10M naming convention, normalized (trimmed + uppercased) before matching.
    ///
    /// Deliberately **looser** than `WearableModel.r10m`'s catalog pattern: that one is user-facing
    /// identity and must not mislabel a ring, while this one only decides which driver to install. A
    /// bare `R10M`, a `-` separator, or a non-hex suffix still gets the right protocol — it just resolves
    /// to no catalog model, so it pairs with a generic name and the fallback art.
    private static let namePattern = "^R10M(?:[ _-][0-9A-Z]+)?$"

    /// The QRing-flavoured Colmi rings advertise one of these. Presence is a positive disqualifier: that
    /// ring answers to `ColmiDriver`, and this coordinator is registered ahead of it.
    private static let qringServiceUUIDs: [CBUUID] = [
        CBUUID(string: ColmiUUIDs.serviceV1),
        CBUUID(string: ColmiUUIDs.serviceV2),
    ]

    /// Service-first, then name — the reverse of `TK5Coordinator`, because unlike the TK5 the R10M
    /// **does** advertise its proprietary `be940000` service.
    ///
    /// 1. A QRing service disqualifies outright.
    /// 2. If a catalog card claims the name, the card decides — so a `TK5 24AA` or an `R09_A1B2` is
    ///    handed straight back even though both are YCBT rings, because their cards name other families.
    /// 3. Otherwise: the `be940000` service, or an R10M-shaped name, is enough on its own.
    ///
    /// Note what is **not** here: no `TK5`/`T50`/`SR0x`/`R0x` name prefixes and no `1078` manufacturer
    /// marker. Both would let this coordinator — registered ahead of `TK5Coordinator` and
    /// `ColmiSmartHealthCoordinator` — swallow uncataloged rings that belong to those families and hand
    /// them a capability set built for a different ring. A YCBT ring nothing recognizes is better served
    /// by the coordinator whose baseline was written for it.
    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        guard !advertisement.serviceUUIDs.contains(where: { qringServiceUUIDs.contains($0) })
        else { return false }
        if let model = WearableModel.model(advertisedName: name) {
            return model.families.contains(deviceType)
        }
        if advertisement.serviceUUIDs.contains(CBUUID(string: YCBTUUIDs.service)) { return true }
        return isYCBTName(name)
    }

    /// Does this local name follow the R10M convention?
    static func isYCBTName(_ name: String?) -> Bool {
        guard let name, let regex = try? NSRegularExpression(pattern: namePattern) else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return regex.firstMatch(in: normalized, options: [], range: range) != nil
    }

    // MARK: - Capabilities

    /// The floor, and every entry is backed by the R10M FW 2.32 hardware session: HR and SpO₂ (live and
    /// history), day steps, the deep/light/REM sleep timeline, and the in-band battery.
    ///
    /// **A baseline entry is an unconditional promise** — the refinement is additive-only
    /// (`WearableCoordinator.refinedCapabilities`), so the ring's own bitmap can never take one back.
    /// Everything sensor-dependent is therefore in `bitmapGatedCapabilities`, including HRV: unlike the
    /// TK5, whose HRV was observed and cross-checked against the vendor app, nobody has seen an R10M
    /// produce an HRV figure, and FW 2.32 does not declare the bit.
    ///
    /// `.remSleep` is a stage tag (`3`) *inside* the `05 04` timeline that `ISHASSLEEP` already grants —
    /// no bit names it, so gating it would make it permanently unreachable rather than deferred. Same
    /// shape as the TK5's reasoning.
    ///
    /// `.measurementInterval` surfaces the Measurement-settings screen. It is a settings screen, not a
    /// sensor: the monitors are now capability-filtered before they are sent (`YCBTEncoder`), so a ring
    /// only ever receives the `01 xx` writes for sensors it declares.
    ///
    /// **`.spo2History` is deliberately in neither set.** The R10M has no dedicated `05 1a` SpO₂ log, and
    /// `YCBTSyncEngine` gates that query on this capability — so leaving it out is what stops the query
    /// being issued at all. Its all-day SpO₂ arrives in the `05 09` combined record instead.
    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .sleep, .remSleep, .battery,
        .manualHeartRate, .manualSpo2,
        .realtimeHeartRate, .realtimeSteps,
        .measurementInterval,
    ]

    /// The per-SKU sensors: offered only if this unit's `02 01` bitmap claims them.
    ///
    /// FW 2.32 on the validated unit declares none of temperature, blood sugar, HRV, stress, fatigue or
    /// Find Device, so in practice the R10M shows exactly its baseline plus blood pressure. They stay
    /// listed because the gate costs a ring that *does* have them nothing — it claims them, and it gets
    /// them — and because "R10M" is a model, not a firmware.
    ///
    /// `.fatigue` rides the stress bit for the same reason it does on the TK5: there is no
    /// `ISHASFATIGUE`, but fatigue is the `body` field of the body-data record (`05 33`) whose whole query
    /// the vendor app gates on `IS_HAS_PRESSURE` — one record, one bit, two fields.
    let bitmapGatedCapabilities: Set<WearableCapability> = [
        .temperature, .bloodPressure, .manualBloodPressure,
        .stress, .fatigue, .bloodSugar,
        .hrv, .manualHrv,
        // The HRV panel (SDNN/RMSSD/pNN50/LF/HF) rides `IS_HAS_PRESSURE` with stress and fatigue —
        // all three are fields of the one `05 33` body-data record that bit gates.
        .hrvDetail,
        .findDevice,
    ]

    let iconSystemName = "circle.circle.fill"

    /// Two firmware quirks, both observed on the R10M and both absent on the TK5 / SmartHealth-Colmi
    /// (which pass these flags `true`):
    ///
    /// - **No `02 1b` GetChipScheme.** The R10M closes an otherwise healthy connection with HCI `0x13` on
    ///   this purely informational query.
    /// - **No `01 1c` all-day blood-pressure monitor.** The ring does not implement it; sending it earns a
    ///   NAK and nothing else.
    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        YCBTDriver(writer: writer, profile: YCBTFamilyProfile(
            baselineCapabilities: capabilities,
            bitmapGatedCapabilities: bitmapGatedCapabilities,
            queryChipSchemeAtStartup: false,
            supportsBloodPressureMonitor: false
        ))
    }
}
