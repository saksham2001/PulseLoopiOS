import XCTest
import CoreBluetooth
@testable import PulseLoop

/// GATT-fragment reassembly. A logical frame longer than `MTU-3` arrives as several notifications, and
/// several short frames can arrive in one. The old driver required `declaredLength == bytes.count` and
/// dropped every split frame as garbage — which is half of why TK5 history never landed.
@MainActor
final class YCBTFrameAssemblerTests: XCTestCase {
    private let stream = CBUUID(string: YCBTUUIDs.stream)
    private let command = CBUUID(string: YCBTUUIDs.command)

    /// A valid frame with an `n`-byte payload of `fill`.
    private func frame(cmd: UInt8, payloadLength: Int, fill: UInt8 = 0xaa) -> Data {
        YCBTFrame.frame([0x05, cmd] + [UInt8](repeating: fill, count: payloadLength))
    }

    func testFrameSplitAcrossThreeNotificationsIsReassembled() {
        let assembler = YCBTFrameAssembler()
        let whole = frame(cmd: 0x15, payloadLength: 60)   // 66 bytes: bigger than a 23-byte default MTU

        XCTAssertTrue(assembler.append(whole.prefix(20), from: stream).isEmpty)
        XCTAssertTrue(assembler.append(whole.dropFirst(20).prefix(20), from: stream).isEmpty)
        let done = assembler.append(whole.dropFirst(40), from: stream)

        XCTAssertEqual(done, [whole])
        XCTAssertNotNil(YCBTFrame(validating: done[0]), "the reassembled frame must still validate")
    }

    func testTwoFramesInOneNotificationBothEmerge() {
        let assembler = YCBTFrameAssembler()
        let first = frame(cmd: 0x15, payloadLength: 6)
        let second = frame(cmd: 0x18, payloadLength: 20)

        XCTAssertEqual(assembler.append(first + second, from: stream), [first, second])
    }

    /// A partial frame followed by a whole one in the same notification: the tail completes the first
    /// and the rest emerges intact.
    func testFragmentThenWholeFrameInOneNotification() {
        let assembler = YCBTFrameAssembler()
        let first = frame(cmd: 0x15, payloadLength: 30)
        let second = frame(cmd: 0x18, payloadLength: 4)

        XCTAssertTrue(assembler.append(first.prefix(10), from: stream).isEmpty)
        XCTAssertEqual(assembler.append(first.dropFirst(10) + second, from: stream), [first, second])
    }

    /// Garbage (a truncated tail from a dropped connection, a stray notification) must not poison the
    /// stream: resync byte by byte until a plausible header appears.
    func testGarbagePrefixResyncsToTheNextValidFrame() {
        let assembler = YCBTFrameAssembler()
        let good = frame(cmd: 0x15, payloadLength: 6)
        let garbage = Data([0xff, 0x00, 0xff, 0xff, 0x7f])   // implausible group + absurd length

        XCTAssertEqual(assembler.append(garbage + good, from: stream), [good])
    }

    /// Fragments from the command channel and the async stream interleave; concatenating one onto the
    /// other would corrupt both.
    func testChannelsBufferIndependently() {
        let assembler = YCBTFrameAssembler()
        let streamFrame = frame(cmd: 0x15, payloadLength: 30)
        let commandFrame = YCBTFrame.frame([0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64])

        XCTAssertTrue(assembler.append(streamFrame.prefix(10), from: stream).isEmpty)
        XCTAssertEqual(assembler.append(commandFrame, from: command), [commandFrame])
        XCTAssertEqual(assembler.append(streamFrame.dropFirst(10), from: stream), [streamFrame])
    }

    func testResetDropsPartialFrames() {
        let assembler = YCBTFrameAssembler()
        let whole = frame(cmd: 0x15, payloadLength: 30)

        XCTAssertTrue(assembler.append(whole.prefix(10), from: stream).isEmpty)
        assembler.reset()
        // The tail alone is garbage now — it must not be mistaken for the rest of the dropped frame.
        XCTAssertTrue(assembler.append(whole.dropFirst(10), from: stream).isEmpty)
    }
}
