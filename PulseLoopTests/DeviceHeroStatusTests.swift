import XCTest
@testable import PulseLoop

final class DeviceHeroStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testConnectedWithBatteryShowsChipAndDisconnect() {
        let s = DeviceHeroStatus.make(state: .connected, connectedName: "Jring 56ff",
            knownName: "Jring 56ff", batteryPercent: 82, lastSync: nil, now: now)
        XCTAssertEqual(s.title, "Jring 56ff")
        XCTAssertEqual(s.statusLine, "Connected")
        XCTAssertEqual(s.batteryText, "82%")
        XCTAssertEqual(s.action, .disconnect)
        XCTAssertEqual(s.actionTitle, "Disconnect")
    }

    func testConnectedWithNilBatteryHidesChip() {
        let s = DeviceHeroStatus.make(state: .connected, connectedName: "Colmi R11",
            knownName: "Colmi R11", batteryPercent: nil, lastSync: nil, now: now)
        XCTAssertNil(s.batteryText)
    }

    func testKnownButDisconnectedShowsConnect() {
        let s = DeviceHeroStatus.make(state: .disconnected, connectedName: nil,
            knownName: "Jring 56ff", batteryPercent: nil, lastSync: nil, now: now)
        XCTAssertEqual(s.title, "Jring 56ff")
        XCTAssertEqual(s.statusLine, "Disconnected")
        XCTAssertEqual(s.action, .connect)
    }

    func testNoDeviceShowsSetUp() {
        let s = DeviceHeroStatus.make(state: .idle, connectedName: nil,
            knownName: nil, batteryPercent: nil, lastSync: nil, now: now)
        XCTAssertEqual(s.title, "No ring connected")
        XCTAssertEqual(s.statusLine, "No ring paired")
        XCTAssertEqual(s.action, .setUp)
    }

    func testSyncTextNilWhenNoSamples() {
        let s = DeviceHeroStatus.make(state: .connected, connectedName: "Jring 56ff",
            knownName: "Jring 56ff", batteryPercent: 50, lastSync: nil, now: now)
        XCTAssertNil(s.syncText)
    }

    func testSyncTextPresentWithLastSync() {
        let s = DeviceHeroStatus.make(state: .connected, connectedName: "Jring 56ff",
            knownName: "Jring 56ff", batteryPercent: 50,
            lastSync: now.addingTimeInterval(-120), now: now)
        XCTAssertEqual(s.syncText?.hasPrefix("Synced") == true, true)
    }
}
