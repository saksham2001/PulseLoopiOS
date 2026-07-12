import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the TK5 ring (SmartHealth app). Declares the capabilities we can actually decode
/// and recognizes the device from its advertisement.
///
/// The *protocol* is not TK5-specific — the ring speaks YCBT, so the driver, encoder, decoder and sync
/// engine it builds are the shared `YCBT*` types. This file is the whole of what makes a TK5 a TK5:
/// its advertised identity and its capability set.
///
/// Recognition is name-first: the TK5's proprietary `be940000` service is **not advertised** (only
/// standard Heart Rate + a generic `FEE7` service are), so the reliable signal is the `TK5 …` local
/// name, backed up by the manufacturer-data prefix observed in the nRF capture.
@MainActor
final class TK5Coordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .tk5

    /// Manufacturer-data prefix from the capture (`10786501…`, company 0x7810). The trailing bytes are
    /// device-specific (they echo the name suffix), so only the prefix is matched.
    private static let manufacturerHexPrefix = "10786501"

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name, name.uppercased().hasPrefix("TK5") { return true }
        if WearableModel.model(advertisedName: name)?.family == .tk5 { return true }
        if let mfg = advertisement.manufacturerData, mfg.hexString.hasPrefix(manufacturerHexPrefix) {
            return true
        }
        return false
    }

    /// The floor: what the TK5 has been *seen* doing, plus what every YCBT ring does regardless of which
    /// sensors its SKU carries. Live + history HR, SpO₂ (live *and* the all-day `05 1A` log), day steps,
    /// HRV, the deep/light/REM sleep timeline, and the in-band battery.
    ///
    /// **A baseline entry is an unconditional promise**: the refinement is additive-only
    /// (`WearableCoordinator.refinedCapabilities`), so the ring's own bitmap can never take one back.
    /// Everything sensor-dependent therefore moved to `bitmapGatedCapabilities` — see there for the R99
    /// session that is the reason why.
    ///
    /// **`.hrv` / `.manualHrv` stay here, and they are the one sensor that earns it.** The TK5's HRV is
    /// not an SDK inference: it was *observed on this ring*, values (48 / 79 ms) cross-checked against
    /// what the vendor app showed for the same session. That is the strongest evidence class we have —
    /// stronger than any bit — and it is exactly the opposite of the R99, whose HRV was denied four
    /// independent ways. Gating it could only ever *lose* it: we have never captured the TK5's `02 01`
    /// reply, so we do not know its length, and `.manualHrv` lives at byte 23 behind the SDK's 24-byte
    /// block gate. A firmware that answers with a legal shorter array would silently delete a "Measure
    /// HRV" button that demonstrably works. Deleting a working feature is a worse bug than the one being
    /// fixed here. (If a TK5 bitmap ever turns up with `ISHASHRV` set, gating becomes a no-op and can be
    /// done freely; if it turns up *clear*, we have a firmware under-reporting a sensor it provably has —
    /// which is evidence against trusting that bitmap, not for it.)
    ///
    /// Three more entries look gate-able and deliberately are not:
    ///
    /// - `.spo2History` — the all-day `05 1A` log. No bit names it: it is one of the SpO₂ sources
    ///   `ISHASBLOODOXYGEN` already grants, not a separate sensor. A ring without the log answers the
    ///   query with a no-data header or `0xFC`, which `YCBTHistoryTransfer` skips permanently.
    /// - `.remSleep` — a stage tag (`3`) *inside* the `05 04` timeline `ISHASSLEEP` grants. Same shape.
    ///   Gating either would not defer the decision, it would make them permanently unreachable, because
    ///   no bit can ever satisfy the gate (`PairingMatchingTests`).
    /// - `.findDevice` — a bit *does* name it (`ISHASFINDDEVICE`, byte 6 bit 4), but nobody has pressed
    ///   Find Ring on a TK5, so we have neither a working buzz nor a refusal, and gating it would
    ///   *remove* a button that may well work. Left as a baseline promise on no evidence either way —
    ///   the same call `ColmiSmartHealthCoordinator` makes, for the same reason.
    ///
    /// `manualHeartRate` / `manualSpo2` / `manualHrv` surface the "Measure now" buttons in Vitals: a spot
    /// reading toggles the live `03 2f` stream on in the metric's own mode, collects the first good
    /// sample from the `06 01` (HR) / `06 02` (SpO₂) / `06 03` (HRV) frames, then toggles the same mode
    /// off. (`manualBloodPressure` rides the same stream — it is gated below only because the *sensor*
    /// is.)
    ///
    /// `measurementInterval` surfaces the Measurement-settings screen: the ring's five `01 xx
    /// {enable, interval}` monitors map 1:1 onto it (HR `01 0C`, BP `01 1C`, temperature `01 20`,
    /// SpO₂ `01 26`, HRV `01 45`), and the interval is floored at the firmware's 30-minute minimum. It is
    /// a settings screen, not a sensor: a ring that doesn't implement one of the five NAKs that one write
    /// (the R99 NAKed two with `0xFC` and honoured three), so it stays baseline.
    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .spo2History, .steps, .battery,
        .hrv, .manualHrv,
        .sleep, .remSleep,
        .manualHeartRate, .manualSpo2,
        .realtimeHeartRate, .realtimeSteps,
        .findDevice, .measurementInterval,
    ]

    /// The per-SKU sensors: offered only if this unit's `02 01` bitmap claims them.
    ///
    /// ## Why the TK5 stopped claiming these unconditionally: the R99 session
    ///
    /// These four (five, with on-demand BP) used to be baseline here — added in A3 because the *SDK*
    /// defines their record types (`05 1E` temperature, `05 33` body data, `05 2F` comprehensive), not
    /// because a TK5 was ever seen producing one. This project's own earlier TK5 notes said the opposite:
    /// *"skin temperature and stress aren't decoded at all — no capture contains the data."* An
    /// SDK-defined record type is a statement about the *protocol*, never about the silicon in a
    /// particular ring.
    ///
    /// The sibling family then paid for exactly that reasoning. `ColmiSmartHealthCoordinator` baselined
    /// `.hrv`/`.manualHrv` on the same grounds; the owner's `R99 54DC` denied HRV four independent ways
    /// (bitmap bit clear, `01 45` → `0xFC`, `05 33` → `0xFC`, `03 2f` mode `0x0a` → refusal), the owner
    /// pressed "Measure HRV", and the app spun the full 45 s window before failing. The *same* session
    /// showed the gate working as designed in both directions: BP was claimed and a spot reading returned
    /// 100/68, while temperature, stress and blood sugar were not claimed and correctly never appeared.
    ///
    /// So the TK5's unconditional claims are no longer trusted either. It is a `.limited`-support ring
    /// whose sensor complement nobody has confirmed on hardware, and an unfilled card with a dead
    /// "Measure now" button is worse than an absent one. The bitmap costs a ring that *does* have these
    /// sensors nothing: it claims them, and it gets them.
    ///
    /// ## `.fatigue` is gated on the stress bit
    ///
    /// There is no `ISHASFATIGUE` — not in the SDK, not in the app (`HomeFragmentModelUtil.checkedFunction`
    /// has no fatigue card at all). But fatigue is not ungatable: it is the `body` field of the body-data
    /// record (`05 33`), whose *whole query* the vendor app gates on `IS_HAS_PRESSURE`
    /// (`DataSyncUtils`: `if (isSupportFunction(IS_HAS_PRESSURE)) add(Health_History_Body_Data)`) — the
    /// same bit that gates stress, the `pressure` field of the same record. One record, one bit, two
    /// fields: a ring with the bit clear is never asked for the record, so it has neither score. That is
    /// what `YCBTSupportFunction` now derives, and it is why `.fatigue` is here rather than dropped —
    /// gating it defers the decision to the ring instead of guessing for it.
    let bitmapGatedCapabilities: Set<WearableCapability> = [
        .temperature, .bloodPressure, .manualBloodPressure,
        .stress, .fatigue, .bloodSugar,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        YCBTDriver(writer: writer)
    }
}
