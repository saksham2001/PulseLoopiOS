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
}
