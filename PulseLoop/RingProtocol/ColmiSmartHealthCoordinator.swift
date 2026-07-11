import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for Colmi rings that ship with the **SmartHealth** app (the owner's `R99 54DC`).
///
/// Same product line as `ColmiCoordinator`, a completely different firmware: these speak YCBT — the
/// byte-identical protocol the TK5 speaks — so the entire stack they build (`YCBTDriver` → encoder,
/// decoder, history transfer, sync engine) is the shared one, and this file is the whole of what makes
/// them their own family: an advertised identity and a capability set. Colmi rings that ship with
/// **QRing** keep the GadgetBridge-derived `ColmiDriver`.
///
/// The two are told apart at *pairing*, not on the wire — see `RingAppVariant`.
///
/// ## What the owner's ring taught us (the `R99 54DC` nRF Connect capture)
///
/// The first real SmartHealth-Colmi we have looked at. Its GATT is the TK5's, exactly: the YCBT
/// service `BE940000-…` with `BE940001/2/3`, plus JieLi RCSP (`AE00`, unimplemented on purpose),
/// Nordic UART, `FEE7` and standard Heart Rate. **Neither QRing service** (`6e40fff0…`, `de5bf728…`)
/// is present — so it is definitively not a ring `ColmiDriver` could talk to — and, like the TK5, it
/// does **not** advertise `be940000`, which is why recognition here has to be name-first.
///
/// It also settled the question the file was built around. Both YCBT rings we have now seen name
/// themselves `<MODEL><SPACE><4 hex>` — `TK5 24AA`, `R99 54DC` — while every QRing-Colmi in the
/// catalog uses an underscore (`R02_A1B2`, `COLMI R10_9C3F`, `R11C_BEEF`). Space-versus-underscore is
/// a signal from real hardware in both families; the `1078` manufacturer marker is not (see below).
@MainActor
final class ColmiSmartHealthCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .colmiSmartHealth

    // MARK: - Advertisement constants

    /// **Confirmed** by the `R99 54DC` capture: the GATT layout (identical to the TK5's), the absence of
    /// the QRing services, and the `<MODEL> <4 hex>` naming convention.
    ///
    /// **Still unknown**: the raw advertisement payload. The capture logged GATT discovery only — no
    /// manufacturer-data hex, no advertised service-UUID list — so `manufacturerHexMarker` remains a
    /// prediction carried over from the TK5, and that is exactly why it no longer decides anything on
    /// its own. What would confirm it: an nRF Connect *scanner* capture (the raw scan record, not the
    /// connected device's service list) of any SmartHealth-Colmi.
    ///
    /// The design still does not depend on any of this being right. The user's explicit pick is what
    /// selects the driver (`RingBLEClient.coordinatorType(preferredFamily:autoMatched:)`), so a
    /// heuristic that never fires costs a toggle the user has to flip — not a working connection — and
    /// one that fires wrongly costs the same. Matching is a hint that sets the picker's default.
    enum Advertisement {
        /// The SmartHealth naming convention: model, one space, four hex digits. Both confirmed rings in
        /// this family advertise this way (`TK5 24AA`, `R99 54DC`) and no QRing-Colmi does — every
        /// Colmi-line pattern in the catalog is underscore-separated. That makes the *name*, not the
        /// manufacturer data, the primary signal.
        ///
        /// Anchored end to end so the hex suffix is the whole tail: `Beats FADE` would satisfy it, but
        /// only a name no catalog card claims ever reaches this test (see `matches`), and the four-hex
        /// tail plus a bare model token is a narrow enough shape that the cost of a false positive — one
        /// stray row in the pairing list, tagged with a family the user can override — stays trivial.
        static let namePattern = "^[A-Za-z0-9]+( [A-Za-z0-9]+)* [0-9A-Fa-f]{4}$"

        /// The Yucheng SDK's company ID (0x7810, little-endian ⇒ `1078`), matched as a **prefix of the
        /// manufacturer data** — the company-ID slot, which is where the one capture in this family that
        /// does include a scan record (the TK5's `10786501…`) puts it.
        ///
        /// **Demoted to corroborating evidence.** It used to be a hard requirement, and the R99 is why it
        /// can't be: we have no advertisement for it at all, so requiring the marker would reject the one
        /// ring in this family we actually own. Its absence therefore no longer vetoes a name match. It
        /// still earns its keep in the other direction — a ring *nothing* names, carrying the Yucheng
        /// company ID, is a YCBT ring, and this family (whose sensors are bitmap-gated rather than
        /// assumed) is the conservative home for one.
        ///
        /// It is deliberately **not** allowed to override a name. A QRing-Colmi may well carry the same
        /// company ID — every ring in this SDK family does, the TK5 included — so letting `1078` promote
        /// an underscore-named Colmi would mis-tag a ring we already support fully, and default its
        /// picker (and first connect) to a protocol its firmware does not speak. The name is the
        /// evidence; the marker only fills the silence.
        ///
        /// Matched as a prefix, never as a substring: an unanchored test over hex is not even
        /// byte-aligned (manufacturer bytes `a1 07 8f` stringify to `"a1078f"`), and Colmi's manufacturer
        /// payload commonly embeds the MAC.
        static let manufacturerHexMarker = "1078"

        /// The QRing-flavoured Colmi rings advertise one of these. Presence is a positive disqualifier:
        /// this ring answers to the *other* driver, so `matches` rejects it outright. The R99 advertises
        /// neither — its GATT has no QRing service at all.
        static let qringServiceUUIDs: [CBUUID] = [
            CBUUID(string: ColmiUUIDs.serviceV1),
            CBUUID(string: ColmiUUIDs.serviceV2),
        ]

        /// Does this local name follow the SmartHealth convention?
        static func isSmartHealthName(_ name: String?) -> Bool {
            guard let name, let regex = try? NSRegularExpression(pattern: namePattern) else { return false }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return regex.firstMatch(in: name, options: [], range: range) != nil
        }
    }

    /// Name-first, with the catalog as the arbiter of *whose* name it is.
    ///
    /// 1. A QRing service disqualifies outright — that ring answers to `ColmiDriver`.
    /// 2. If a catalog card claims the name, the card decides: it must be one that can be this family
    ///    **and** the name must follow the SmartHealth convention. That second half is what does the real
    ///    work, because every Colmi card can be this family (they all offer both apps): it is the
    ///    space-versus-underscore split that separates `R99 54DC` from `R02_A1B2`. A `TK5 24AA` is
    ///    rejected by the first half instead — its card resolves to `.tk5` only — which is what keeps
    ///    this coordinator, registered *ahead* of `TK5Coordinator`, off the TK5.
    /// 3. Otherwise nobody names it: fall back to the manufacturer marker, standing aside for the TK5,
    ///    whose fuller `10786501…` prefix is a confirmed identity and whose coordinator is checked after
    ///    us. (`WearableModel.model(advertisedName:)` is nil here, so `TK5Coordinator` is being asked
    ///    exactly the question we can't answer: "is this manufacturer data yours?")
    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        guard !advertisement.serviceUUIDs.contains(where: { Advertisement.qringServiceUUIDs.contains($0) })
        else { return false }
        if let model = WearableModel.model(advertisedName: name) {
            return model.families.contains(deviceType) && Advertisement.isSmartHealthName(name)
        }
        guard let manufacturer = advertisement.manufacturerData,
              manufacturer.hexString.hasPrefix(Advertisement.manufacturerHexMarker) else { return false }
        return !TK5Coordinator.matches(name: name, advertisement: advertisement)
    }

    // MARK: - Capabilities

    /// The floor: what every YCBT ring does regardless of which sensors its SKU carries. A *family* is
    /// not a SKU here — two Colmi rings speaking this identical protocol can differ on whether they have
    /// a temperature or blood-pressure sensor at all — so anything sensor-dependent is deferred to
    /// `bitmapGatedCapabilities` and only claimed if the ring itself claims it.
    ///
    /// **A baseline entry is an unconditional promise**: the refinement is additive-only, so the bitmap
    /// can never take one back. That is why HRV is no longer here — see `bitmapGatedCapabilities`.
    ///
    /// Two entries look like they belong in the gated set and deliberately don't, because they are
    /// *protocol* facts, not sensor facts — identical for every YCBT ring, and the TK5 (the one unit of
    /// this protocol we have on the bench) declares both as baseline:
    ///
    /// - `.measurementInterval` is the five `01 xx {enable, interval}` monitor writes. It is a settings
    ///   screen, not a sensor; a ring that doesn't implement one of the five NAKs that one write. The
    ///   R99 proved this benign: it NAKed `01 45` (HRV) and `01 1c` (all-day BP) with `0xFC` and honoured
    ///   the other three.
    /// - `.spo2History` is the all-day `05 1A` log. A ring without it answers the query with a no-data
    ///   header or `0xFC`, which `YCBTHistoryTransfer` skips permanently.
    ///
    /// Neither is named by any bit in `YCBTSupportFunction`, so gating them would not defer the decision
    /// — it would make them permanently unreachable (see `bitmapGatedCapabilities`).
    ///
    /// **`.findDevice` stays here on no evidence either way.** The R99's bitmap does *not* claim it
    /// (byte 6 bit 4 is clear) and nobody has pressed Find Ring on one, so we have neither a working
    /// buzz nor a refusal. Gating it would *remove* a button that may well work — the opposite trade from
    /// HRV, where four independent denials said the button can never work. Left as a baseline promise,
    /// recorded here as untested; the first person to press it on an R99 settles it.
    ///
    /// **`.fatigue` is deliberately absent, from *both* lists.** It rides the body-data record (`05 33`),
    /// which the R99 answered with `0xFC` (unsupported key): on this ring it is confirmed absent, so a
    /// baseline entry would leave its Vitals gauge permanently at "No fatigue score yet". It is not in
    /// `bitmapGatedCapabilities` either, though it now *could* be — `YCBTSupportFunction` derives it from
    /// `IS_HAS_PRESSURE`, the bit the vendor app gates the whole body-data query on (see the bit table,
    /// and `TK5Coordinator`, which gates it that way). Gating it here would be a provable no-op — the R99
    /// leaves that bit clear — so it stays out until a SmartHealth-Colmi that *sets* it turns up and can
    /// say whether its `body` field is real. Nothing in this family has ever produced a fatigue score.
    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .spo2History, .steps, .sleep, .remSleep, .battery,
        .manualHeartRate, .manualSpo2,
        .realtimeHeartRate, .realtimeSteps,
        .findDevice, .measurementInterval,
    ]

    /// The per-SKU sensors: added only if this unit's `02 01` capability bitmap claims them (the
    /// refinement is `WearableCoordinator.refinedCapabilities`, which can only *add*, and only from
    /// this list).
    ///
    /// Every entry must be a capability `YCBTSupportFunction` can actually derive from a bit — a gate no
    /// bit can ever satisfy is not a deferred decision but a dead promise, permanently unreachable while
    /// reading as "supported if the ring says so". `PairingMatchingTests` asserts that invariant.
    ///
    /// ## HRV moved here, and the R99 is why
    ///
    /// `.hrv`/`.manualHrv` used to be baseline — an unconditional promise this ring cannot keep. The
    /// owner's `R99 54DC` (firmware 2.32) denies HRV **four independent ways** in one session:
    ///
    /// - its `02 01` bitmap leaves `ISHASHRV` (byte 1 bit 1) clear;
    /// - `01 45` (the all-day HRV monitor) → `0xFC` unsupported key;
    /// - `05 33` (the body-data history that carries HRV) → `0xFC`;
    /// - `03 2f` with mode `0x0a` → status `0x01`, an outright refusal to start.
    ///
    /// The user pressed "Measure HRV", the ring never answered, and the app spun the full 45 s window
    /// before failing. Gating both on the bitmap turns a broken button into an absent one — and costs a
    /// ring that *does* claim HRV (the bits exist: byte 1 bit 1 and byte 23 bit 0) nothing at all.
    ///
    /// The TK5 took the same lesson and now gates its own sensor set — but it keeps `.hrv`/`.manualHrv`
    /// as baseline, because on *that* ring HRV was observed working (48 / 79 ms, cross-checked against
    /// the vendor app). Same discipline, opposite evidence, opposite conclusion; see `TK5Coordinator`.
    ///
    /// The same session settled the rest of this list on the same ring: `.bloodPressure` +
    /// `.manualBloodPressure` were claimed and a spot BP measurement returned 100/68 — the gate working
    /// as designed — while `.temperature`, `.stress` and `.bloodSugar` were not claimed and correctly
    /// never appeared.
    let bitmapGatedCapabilities: Set<WearableCapability> = [
        .temperature, .bloodPressure, .stress, .bloodSugar, .manualBloodPressure,
        .hrv, .manualHrv,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        YCBTDriver(writer: writer)
    }
}
