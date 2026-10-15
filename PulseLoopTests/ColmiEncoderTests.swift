import XCTest
@testable import PulseLoop

final class ColmiEncoderTests: XCTestCase {

    private let encoder = ColmiEncoder()

    /// Little-endian u32 from the request's timestamp bytes 1-4.
    private func timestamp(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
    }

    private func midnight(in zone: TimeZone, year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // The ring's RTC runs on local wall time, so the 0x15 HR-history request must carry local
    // midnight *as if it were UTC* (epoch + UTC offset), matching GadgetBridge / colmi_r02_client.
    // A true UTC epoch makes the ring reply "empty" for every day (the R03 field bug).

    func testSyncHeartRatePositiveOffset() {
        let zone = TimeZone(identifier: "Asia/Singapore")!   // UTC+8, no DST
        let day = midnight(in: zone, year: 2026, month: 7, day: 24)
        let bytes = encoder.syncHeartRate(dayStart: day, timeZone: zone)
        XCTAssertEqual(bytes[0], ColmiCommandID.syncHeartRate)
        XCTAssertEqual(timestamp(bytes), UInt32(day.timeIntervalSince1970) + 8 * 3600)
    }

    func testSyncHeartRateNegativeOffsetDSTAware() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!   // UTC-7 in July (PDT)
        let day = midnight(in: zone, year: 2026, month: 7, day: 24)
        let bytes = encoder.syncHeartRate(dayStart: day, timeZone: zone)
        XCTAssertEqual(zone.secondsFromGMT(for: day), -7 * 3600)
        XCTAssertEqual(timestamp(bytes), UInt32(Int(day.timeIntervalSince1970) - 7 * 3600))
    }

    func testSyncHeartRateGMTIsIdentity() {
        let zone = TimeZone(identifier: "GMT")!
        let day = midnight(in: zone, year: 2026, month: 7, day: 24)
        let bytes = encoder.syncHeartRate(dayStart: day, timeZone: zone)
        XCTAssertEqual(timestamp(bytes), UInt32(day.timeIntervalSince1970))
    }
}
