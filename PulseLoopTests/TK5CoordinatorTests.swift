import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The TK5 *device*: how it is recognized in a scan, and what it claims it can do.
///
/// Deliberately separate from `YCBTDecoderTests`. The protocol the TK5 speaks is shared byte-for-byte
/// with every other SmartHealth-family ring, so the decoder/encoder/driver tests are family-neutral;
/// what is TK5-only is its advertised identity and its capability set, and those belong here.
final class TK5CoordinatorTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<n], radix: 16)!)
            i = n
        }
        return Data(out)
    }

    @MainActor
    func testCoordinatorMatchesTK5Name() {
        let noAdv = AdvertisementInfo(serviceUUIDs: [], manufacturerData: nil)
        XCTAssertTrue(TK5Coordinator.matches(name: "TK5 24AA", advertisement: noAdv))
        XCTAssertFalse(TK5Coordinator.matches(name: "SMART_RING", advertisement: noAdv))
        XCTAssertFalse(JringCoordinator.matches(name: "TK5 24AA", advertisement: noAdv))
    }

    @MainActor
    func testCoordinatorMatchesManufacturerPrefix() {
        let adv = AdvertisementInfo(
            serviceUUIDs: [],
            manufacturerData: bytes("10786501000101120000000000"))
        XCTAssertTrue(TK5Coordinator.matches(name: "Unlabeled", advertisement: adv))
    }

    /// The Measurement-settings screen is gated on `.measurementInterval`; the five `01 xx` monitor
    /// writes are what back it.
    @MainActor
    func testCoordinatorDeclaresMeasurementInterval() {
        XCTAssertTrue(TK5Coordinator().capabilities.contains(.measurementInterval))
    }
}
