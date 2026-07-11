import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The `02 01` capability bitmap: how it is parsed, and the rule by which it is allowed to change what
/// the app thinks a ring can do.
///
/// The refinement rule (`baseline ∪ (gated ∩ derived)`) is the safety property worth testing hardest —
/// it is what lets one driver serve SKUs with different sensors *without* letting a misread bit or a
/// truncated reply either strip a working metric card or conjure one the ring can't fill.
final class YCBTSupportFunctionTests: XCTestCase {

    /// Build a bitmap payload of `length` bytes with the given bits set, MSB-first within each byte —
    /// i.e. `(byte, bit)` addressed exactly as the SDK's `(bArr[byte] >> bit) & 1`.
    private func bitmap(length: Int, set bits: [(byte: Int, bit: Int)]) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: length)
        for bit in bits where bit.byte < length {
            payload[bit.byte] |= UInt8(1 << bit.bit)
        }
        return payload
    }

    /// A full-length bitmap with every bit set — the "this ring has everything" case.
    private var allOnes: [UInt8] { [UInt8](repeating: 0xff, count: 27) }

    // MARK: - Bit → capability mapping

    /// Each mapped bit, in isolation, yields exactly its own capability (or capabilities) and nothing
    /// else. This is the table's regression net: a transposed byte or bit index shows up here as a wrong
    /// capability.
    ///
    /// `IS_HAS_PRESSURE` is the one bit that yields **two**, because the ring gives them one switch: the
    /// vendor app gates the entire body-data query (`05 33`) on it, and stress (`pressure`) and fatigue
    /// (`body`) are two fields of that one record.
    func testEachMappedBitYieldsExactlyItsCapability() {
        let expected: [(byte: Int, bit: Int, capabilities: Set<WearableCapability>)] = [
            (0, 7, [.steps]),               // ISHASSTEPCOUNT
            (0, 6, [.sleep]),               // ISHASSLEEP
            (0, 3, [.heartRate]),           // ISHASHEARTRATE
            (0, 0, [.bloodPressure]),       // ISHASBLOOD
            (1, 3, [.spo2]),                // ISHASBLOODOXYGEN
            (1, 1, [.hrv]),                 // ISHASHRV
            (6, 4, [.findDevice]),          // ISHASFINDDEVICE
            (8, 0, [.temperature]),         // ISHASTEMP
            (15, 1, [.manualHeartRate]),    // ISHATESTHEART
            (15, 2, [.manualBloodPressure]),// ISHASTESTBLOOD
            (15, 3, [.manualSpo2]),         // ISHASTESTSPO2
            (17, 3, [.bloodSugar]),         // ISHASBLOODSUGAR
            (22, 6, [.stress, .fatigue]),   // IS_HAS_PRESSURE — the whole `05 33` record
            (23, 0, [.manualHrv]),          // IS_HAS_HRV_MEASUREMENT
        ]
        for entry in expected {
            let payload = bitmap(length: 27, set: [(entry.byte, entry.bit)])
            XCTAssertEqual(
                YCBTSupportFunction.capabilities(from: payload),
                entry.capabilities,
                "byte \(entry.byte) bit \(entry.bit) should map to \(entry.capabilities) alone"
            )
        }
    }

    /// Bit order is MSB-first *within* each byte. `ISHASSTEPCOUNT` is byte 0 bit 7 (0x80) and
    /// `ISHASBLOOD` is byte 0 bit 0 (0x01) — an LSB-first reader would swap them, which is exactly the
    /// mistake that would show a blood-pressure card on a step-only ring.
    func testBitOrderingIsMSBFirstWithinAByte() {
        var stepsOnly = [UInt8](repeating: 0, count: 27)
        stepsOnly[0] = 0x80
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: stepsOnly), [.steps])

        var bloodOnly = [UInt8](repeating: 0, count: 27)
        bloodOnly[0] = 0x01
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: bloodOnly), [.bloodPressure])
    }

    /// An all-ones bitmap yields precisely the mapped set — no more. Proves the unmapped/reserved bits
    /// (ECG, dials, per-sport, notification apps…) are ignored rather than silently folded into
    /// something. If a future bit is added to the table, this is the test that must be updated.
    func testUnmappedBitsAreIgnored() {
        XCTAssertEqual(
            YCBTSupportFunction.capabilities(from: allOnes),
            [
                .steps, .sleep, .heartRate, .bloodPressure, .spo2, .hrv, .findDevice, .temperature,
                .bloodSugar, .stress, .fatigue,
                .manualHeartRate, .manualBloodPressure, .manualSpo2, .manualHrv,
            ]
        )
    }

    func testEmptyBitmapClaimsNothing() {
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: [UInt8](repeating: 0, count: 27)), [])
    }

    /// Several bits packed into one byte decode together (the realistic shape of a reply).
    func testMultipleBitsWithinOneByteDecodeTogether() {
        var payload = [UInt8](repeating: 0, count: 14)
        payload[0] = 0b1100_1001   // stepCount(7) + sleep(6) + heartRate(3) + blood(0)
        payload[1] = 0b0000_1010   // bloodOxygen(3) + hrv(1)
        XCTAssertEqual(
            YCBTSupportFunction.capabilities(from: payload),
            [.steps, .sleep, .heartRate, .bloodPressure, .spo2, .hrv]
        )
    }

    /// `rawBits` is the diagnostic view — the bitmap carries far more bits than we map, and an
    /// unrecognised ring is triaged from the raw array. MSB-first, so 0b1000_0001 reads ends-in.
    func testRawBitsAreMSBFirst() {
        XCTAssertEqual(
            YCBTSupportFunction.rawBits(from: [0b1000_0001]),
            [true, false, false, false, false, false, false, true]
        )
    }

    // MARK: - Length guards

    /// A payload shorter than the SDK's own `>= 14` gate is parsed as nothing at all — not as a partial
    /// claim. A truncated reply must read as "no opinion" (baseline stands), never as a denial.
    func testPayloadBelowTheSDKsMinimumClaimsNothing() {
        for length in 0..<14 {
            let payload = [UInt8](repeating: 0xff, count: length)
            XCTAssertEqual(
                YCBTSupportFunction.capabilities(from: payload),
                [],
                "a \(length)-byte bitmap is below the SDK's 14-byte gate and must claim nothing"
            )
        }
    }

    /// No byte access may run off the end: every truncation of an all-ones bitmap must parse without
    /// trapping, and must only ever claim a subset of the full-length result.
    func testEveryTruncationIsSafeAndMonotonic() {
        let full = YCBTSupportFunction.capabilities(from: allOnes)
        for length in 0...allOnes.count {
            let claimed = YCBTSupportFunction.capabilities(from: Array(allOnes.prefix(length)))
            XCTAssertTrue(claimed.isSubset(of: full), "a \(length)-byte bitmap claimed more than the full one")
        }
    }

    /// The gates reproduce the SDK's *block* structure, not a per-byte bounds check.
    /// `saveDeviceSupportFunctionData` reads bytes 14–17 only behind `if (bArr.length >= 18)`, so a
    /// 16-byte bitmap has a physical byte 15 that the vendor SDK — and therefore we — must not read.
    func testByte15IsNotReadBelowTheSDKs18ByteGate() {
        let manualBits = [(byte: 15, bit: 1), (byte: 15, bit: 2), (byte: 15, bit: 3)]
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: bitmap(length: 16, set: manualBits)), [])
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: bitmap(length: 17, set: manualBits)), [])
        XCTAssertEqual(
            YCBTSupportFunction.capabilities(from: bitmap(length: 18, set: manualBits)),
            [.manualHeartRate, .manualBloodPressure, .manualSpo2]
        )
    }

    /// The same block rule at the far end of the array: stress (and, on the same bit, fatigue) needs
    /// 23 bytes, manual-HRV needs 24.
    func testTrailingBlocksNeedTheirOwnLengths() {
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: bitmap(length: 22, set: [(22, 6)])), [])
        XCTAssertEqual(
            YCBTSupportFunction.capabilities(from: bitmap(length: 23, set: [(22, 6)])),
            [.stress, .fatigue]
        )
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: bitmap(length: 23, set: [(23, 0)])), [])
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: bitmap(length: 24, set: [(23, 0)])), [.manualHrv])
    }

    /// A 14-byte bitmap (the shortest the SDK accepts) still yields the whole first block.
    func testShortestAcceptedBitmapYieldsTheFirstBlock() {
        let payload = bitmap(length: 14, set: [(0, 3), (1, 3), (8, 0)])
        XCTAssertEqual(YCBTSupportFunction.capabilities(from: payload), [.heartRate, .spo2, .temperature])
    }

    // MARK: - Refinement formula: baseline ∪ (gated ∩ derived)

    /// A coordinator that gates `temperature` + `stress` on the bitmap, over a fixed baseline.
    @MainActor
    private final class GatedCoordinator: WearableCoordinator {
        nonisolated deinit {}
        static let deviceType: RingDeviceType = .tk5
        static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool { false }
        let capabilities: Set<WearableCapability> = [.heartRate, .steps, .battery]
        let bitmapGatedCapabilities: Set<WearableCapability> = [.temperature, .stress]
        let iconSystemName = "circle"
        func makeDriver(writer: RingCommandWriter) -> WearableDriver { YCBTDriver(writer: writer) }
    }

    /// A gated capability the ring claims is added.
    @MainActor
    func testBitmapAddsAPreApprovedCapabilityTheRingClaims() {
        let refined = GatedCoordinator().refinedCapabilities(bitmapDerived: [.temperature])
        XCTAssertEqual(refined, [.heartRate, .steps, .battery, .temperature])
    }

    /// A gated capability the ring does *not* claim stays off — the whole point of gating.
    @MainActor
    func testBitmapWithholdsAPreApprovedCapabilityTheRingDoesNotClaim() {
        let refined = GatedCoordinator().refinedCapabilities(bitmapDerived: [.temperature])
        XCTAssertFalse(refined.contains(.stress))
    }

    /// **The bitmap can never remove a baseline capability.** Firmwares under-report in the field (an
    /// old one simply sends a shorter array), and a metric card vanishing mid-session is a worse failure
    /// than one extra card. Here the ring claims nothing at all and the baseline still stands.
    @MainActor
    func testBitmapCannotRemoveABaselineCapability() {
        let coordinator = GatedCoordinator()
        XCTAssertEqual(coordinator.refinedCapabilities(bitmapDerived: []), coordinator.capabilities)
    }

    /// **The bitmap can never add a capability the coordinator didn't pre-approve.** A bit we mapped
    /// wrongly — or a metric PulseLoop has no decoder for — must not be able to conjure a UI surface.
    @MainActor
    func testBitmapCannotAddACapabilityTheCoordinatorDidNotPreApprove() {
        let refined = GatedCoordinator().refinedCapabilities(bitmapDerived: [.bloodPressure, .bloodSugar, .remSleep])
        XCTAssertEqual(refined, [.heartRate, .steps, .battery])
    }

    /// A family that gates nothing is bit-for-bit unaffected by any bitmap — the zero-regression property
    /// that keeps jring and QRing-Colmi out of this feature's blast radius. (Neither speaks YCBT, so
    /// neither has a bitmap to consult in the first place; both YCBT families now gate.)
    @MainActor
    func testFamilyThatGatesNothingIsUnaffectedByAnyBitmap() {
        for coordinator in [JringCoordinator(), ColmiCoordinator()] as [any WearableCoordinator] {
            XCTAssertTrue(coordinator.bitmapGatedCapabilities.isEmpty)
            let refined = coordinator.refinedCapabilities(bitmapDerived: YCBTSupportFunction.capabilities(from: allOnes))
            XCTAssertEqual(refined, coordinator.capabilities, "\(type(of: coordinator)) must ignore the bitmap")
            XCTAssertEqual(coordinator.refinedCapabilities(bitmapDerived: []), coordinator.capabilities)
        }
    }

    /// Refinement is idempotent: re-applying the same bitmap (the ring re-sends it on every handshake,
    /// and a reconnect runs a fresh one) converges rather than accumulating.
    @MainActor
    func testRefinementIsIdempotent() {
        let coordinator = GatedCoordinator()
        let once = coordinator.refinedCapabilities(bitmapDerived: [.temperature, .stress])
        let twice = coordinator.refinedCapabilities(bitmapDerived: [.temperature, .stress])
        XCTAssertEqual(once, twice)
    }

    // MARK: - Decoder wiring

    /// The `02 01` reply now emits `.supportFunctions` rather than a bare ack.
    func testDecoderEmitsSupportFunctionsEvent() throws {
        let payload = bitmap(length: 27, set: [(0, 3), (1, 3), (22, 6)])
        let frame = try XCTUnwrap(YCBTFrame(validating: YCBTFrame.frame([0x02, 0x01] + payload)))
        let events = YCBTDecoder().decode(frame)
        guard case let .supportFunctions(claimed) = events.first else {
            return XCTFail("expected .supportFunctions, got \(events)")
        }
        XCTAssertEqual(claimed, [.heartRate, .spo2, .stress, .fatigue])
    }

    /// The `02 1b` reply reaches the debug feed with its value (`InnerUtils.isJieLiChipScheme`: 3/4/5).
    func testDecoderEmitsChipSchemeEvent() throws {
        let frame = try XCTUnwrap(YCBTFrame(validating: YCBTFrame.frame([0x02, 0x1b, 0x03])))
        guard case let .chipScheme(value) = YCBTDecoder().decode(frame).first else {
            return XCTFail("expected .chipScheme")
        }
        XCTAssertEqual(value, 3)
        XCTAssertTrue(YCBTChipScheme.isJieLi(value))
        XCTAssertFalse(YCBTChipScheme.isJieLi(0))
    }

    /// An error status in the chipScheme byte (the `0xFB…0xFF` band) folds to 0 = unknown, not a
    /// scheme id of 255 — matching `unpackGetChipScheme`'s `>= 240` check.
    func testChipSchemeErrorStatusFoldsToUnknown() {
        XCTAssertEqual(YCBTChipScheme.value(from: [0xff]), 0)
        XCTAssertEqual(YCBTChipScheme.value(from: []), 0)
        XCTAssertEqual(YCBTChipScheme.value(from: [0x04]), 4)
    }

    /// Neither event produces a `PulseEvent`: capabilities reach persistence via the re-published
    /// `.deviceIdentified`, and chipScheme is diagnostic only. If either started fanning out here it
    /// would be written to the metric store as a reading.
    func testNeitherEventProducesAPulseEvent() {
        XCTAssertTrue(RingEventBridge.events(for: .supportFunctions([.heartRate])).isEmpty)
        XCTAssertTrue(RingEventBridge.events(for: .chipScheme(value: 3)).isEmpty)
    }
}
