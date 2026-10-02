import XCTest
@testable import PulseLoop

/// Unit tests for the CRP ("crrepa") framing + command builders (`CRPProtocol`). Pure byte-level
/// checks against the decompiled Moyoung "Da Rings" builders (`b1/q.java`, `b1/e.java`, `b1/k.java`,
/// `b1/t.java`, `b1/c0.java`, `b1/l.java`); no BLE stack needed. See `decompiled-moyoung-official/`.
/// Ported from the Android app's `CRPProtocolTest.kt`.
final class CRPProtocolTests: XCTestCase {

    func testFrameLaysOutFDDA10LenGroupCmdPayload() {
        let f = CRPProtocol.frame(group: 1, cmd: 9, payload: [1])
        // FD DA 10 | len=7 | group=1 | cmd=9 | payload=01
        XCTAssertEqual(f, Data([0xFD, 0xDA, 0x10, 7, 1, 9, 1]))
    }

    func testFrameLengthEqualsPayloadPlusSixByteHeader() {
        XCTAssertEqual(CRPProtocol.frame(group: 3, cmd: 0).count, 6)                                  // no payload
        XCTAssertEqual(CRPProtocol.frame(group: 1, cmd: 0, payload: [UInt8](repeating: 0, count: 5)).count, 11)
    }

    func testIsFrameStartRecognisesTheFDDAMagicOnly() {
        XCTAssertTrue(CRPProtocol.isFrameStart(Data([0xFD, 0xDA, 0x10, 6])))
        XCTAssertFalse(CRPProtocol.isFrameStart(Data([0xFD, 0x00])))
        XCTAssertFalse(CRPProtocol.isFrameStart(Data([0xDA])))
    }

    func testFrameLengthReadsByte3WithThe9thBitFromByte2() {
        // Short frame: byte[2]=0x10 (bit0 clear) => length is byte[3].
        XCTAssertEqual(CRPProtocol.frameLength(Data([0xFD, 0xDA, 0x10, 20])), 20)
        // Long frame: bit0 of byte[2] set => +256.
        XCTAssertEqual(CRPProtocol.frameLength(Data([0xFD, 0xDA, 0x11, 5])), 256 + 5)
    }

    func testFrameEncodesTheNinthLengthBit() {
        let frame = CRPProtocol.frame(group: 2, cmd: 15, payload: [UInt8](repeating: 0, count: 250))
        XCTAssertEqual(frame.count, 256)
        XCTAssertEqual(frame[2], 0x11)
        XCTAssertEqual(frame[3], 0x00)
        XCTAssertEqual(CRPProtocol.frameLength(frame), 256)
    }

    func testFrameSupportsTheMaximum511ByteLength() {
        let frame = CRPProtocol.frame(group: 2, cmd: 15, payload: [UInt8](repeating: 0, count: 505))
        XCTAssertEqual(frame.count, 511)
        XCTAssertEqual(frame[2], 0x11)
        XCTAssertEqual(frame[3], 0xFF)
        XCTAssertEqual(CRPProtocol.frameLength(frame), 511)
    }

    func testSetUserInfoMatchesVendorLayout() {
        // b1/k.a: q.c(1, 0, [height, weight, age, gender, strideLen])
        let f = CRPProtocol.setUserInfo(heightCm: 175, weightKg: 70, ageYears: 30, gender: 1, strideCm: 75)
        XCTAssertEqual(f, Data([0xFD, 0xDA, 0x10, 11, 1, 0, 175, 70, 30, 1, 75]))
    }

    func testSetTimeIsGroup1Cmd1WithLittleEndianEpochAndTZByte8() {
        let b = [UInt8](CRPProtocol.setTime())
        XCTAssertEqual(b[0], 0xFD); XCTAssertEqual(b[1], 0xDA); XCTAssertEqual(b[2], 0x10)
        XCTAssertEqual(Int(b[3]), 11)   // 5 payload + 6 header
        XCTAssertEqual(Int(b[4]), 1)    // group
        XCTAssertEqual(Int(b[5]), 1)    // cmd
        XCTAssertEqual(Int(b[10]), 8)   // trailing timezone byte
        // Epoch is little-endian: reconstruct and sanity-check it's a plausible 2020s timestamp.
        let epoch = UInt32(b[6]) | (UInt32(b[7]) << 8) | (UInt32(b[8]) << 16) | (UInt32(b[9]) << 24)
        XCTAssertTrue((1_577_836_800...4_102_444_800).contains(Int(epoch)), "epoch \(epoch) out of expected range")
    }

    func testHeartRateStartAndStopToggleTheEnableByteOnGroup1Cmd9() {
        XCTAssertEqual(CRPProtocol.measureHeartRate(true), Data([0xFD, 0xDA, 0x10, 7, 1, 9, 1]))
        XCTAssertEqual(CRPProtocol.measureHeartRate(false), Data([0xFD, 0xDA, 0x10, 7, 1, 9, 0]))
    }

    func testSpO2UsesGroup1Cmd11() {
        XCTAssertEqual(CRPProtocol.measureSpO2(true), Data([0xFD, 0xDA, 0x10, 7, 1, 11, 1]))
    }

    func testFindDeviceIsGroup9Cmd2() {
        XCTAssertEqual(CRPProtocol.findDevice(true), Data([0xFD, 0xDA, 0x10, 7, 9, 2, 1]))
    }

    func testFactoryResetIsGroup3Cmd0WithNoPayload() {
        XCTAssertEqual(CRPProtocol.factoryReset(), Data([0xFD, 0xDA, 0x10, 6, 3, 0]))
    }

    // MARK: - Opcodes corrected against their `d1/b.java` callers

    /// `b1/l.k` → `d1/b.queryFirmwareVersion` = `q.b(3,3)`. The old `7/1` was `b1/r.d`, the vendor's
    /// `querySavedGomoreKey` — which is why the R11 answered none of the 23 sends (Android issue #29).
    func testFirmwareVersionQueryIsGroup3Cmd3() {
        XCTAssertEqual(CRPProtocol.queryFirmwareVersion(), Data([0xFD, 0xDA, 0x10, 6, 3, 3]))
    }

    /// `b1/i0.b` → `q.c(2,22,[day,idx])`, the same `[day, frameIndex]` shape as the other timing
    /// histories. `q.b(2,48)` is `b1/e0.d` = `querySleepState`, not temperature.
    func testTemperatureHistoryIsGroup2Cmd22WithDayAndFrameIndex() {
        XCTAssertEqual(CRPProtocol.queryHistoryTemp(), Data([0xFD, 0xDA, 0x10, 8, 2, 22, 0, 0]))
        XCTAssertEqual(CRPProtocol.queryHistoryTemp(day: 1, frameIndex: 2),
                       Data([0xFD, 0xDA, 0x10, 8, 2, 22, 1, 2]))
    }

    /// Both temp toggles ride cmd 13 with an enable byte — `d1/b.enableTimingTemp` and
    /// `disableTimingTemp` both call `b1/i0.c(Bool)`. Cmd 32 (`b1/i0.d`) is the *spot* toggle;
    /// sending it as a disable would have started a one-shot measurement instead.
    func testTempAllDayTogglesShareCmd13AndDifferOnlyInTheEnableByte() {
        XCTAssertEqual(CRPProtocol.enableTimingTemp(), Data([0xFD, 0xDA, 0x10, 7, 1, 13, 1]))
        XCTAssertEqual(CRPProtocol.disableTimingTemp(), Data([0xFD, 0xDA, 0x10, 7, 1, 13, 0]))
        XCTAssertEqual(CRPProtocol.measureTemp(true), Data([0xFD, 0xDA, 0x10, 7, 1, 32, 1]))
    }

    /// The read-backs that let the ring describe itself, all on group 2 with no payload.
    func testReadBackQueriesUseTheirVendorOpcodes() {
        XCTAssertEqual(CRPProtocol.querySupportSpO2Type(), Data([0xFD, 0xDA, 0x10, 6, 2, 37]))   // b1/h.e
        XCTAssertEqual(CRPProtocol.queryTimingHeartRateState(), Data([0xFD, 0xDA, 0x10, 6, 2, 6]))  // b1/t.e
        XCTAssertEqual(CRPProtocol.queryTimingHrvState(), Data([0xFD, 0xDA, 0x10, 6, 2, 7]))     // b1/u.e
        XCTAssertEqual(CRPProtocol.queryTimingSpO2State(), Data([0xFD, 0xDA, 0x10, 6, 2, 8]))    // b1/h.f
        XCTAssertEqual(CRPProtocol.queryTimingStressState(), Data([0xFD, 0xDA, 0x10, 6, 2, 45])) // b1/h0.e
        XCTAssertEqual(CRPProtocol.queryTimingTempState(), Data([0xFD, 0xDA, 0x10, 6, 2, 21]))   // b1/i0.a
    }

    /// The remaining spot-measure toggles, each `[enable]` on its own group-1 cmd.
    func testSpotMeasureTogglesCoverEveryVital() {
        XCTAssertEqual(CRPProtocol.measureHRV(true), Data([0xFD, 0xDA, 0x10, 7, 1, 10, 1]))
        XCTAssertEqual(CRPProtocol.measureStress(false), Data([0xFD, 0xDA, 0x10, 7, 1, 14, 0]))
    }
}
