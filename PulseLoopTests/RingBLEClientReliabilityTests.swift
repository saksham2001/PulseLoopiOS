import XCTest
@testable import PulseLoop

@MainActor
final class RingBLEClientReliabilityTests: XCTestCase {
    func testKeepalivePolicyUsesGattBatteryForCRP() {
        XCTAssertEqual(RingBLEClient.keepaliveMode(for: .crp), .gattBatteryRead)
        XCTAssertEqual(RingBLEClient.keepaliveMode(for: .jring), .command)
        XCTAssertEqual(RingBLEClient.keepaliveMode(for: .colmiR02), .none)
        XCTAssertEqual(RingBLEClient.keepaliveMode(for: nil), .none)
    }
}
