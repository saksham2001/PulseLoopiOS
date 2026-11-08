import XCTest
@testable import PulseLoop

/// The Colmi history state machine's paging: each HR/stress/HRV day ends on the page count its own
/// packet 0 announces (so the next request goes out at once instead of after the 10 s watchdog), the
/// HR request epoch, and the big-data request bytes. Pure — a recording writer captures every
/// enqueued command, no hardware. Inbound frames are built with `ColmiPacket.frame` (16 bytes +
/// checksum), as the ring sends them.
@MainActor
final class ColmiSyncEngineTests: XCTestCase {

    private final class RecordingWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        private(set) var frames: [Data] = []
        func enqueue(_ command: Data) { frames.append(command) }
    }

    private var writer: RecordingWriter!
    private var engine: ColmiSyncEngine!

    override func setUp() {
        super.setUp()
        writer = RecordingWriter()
        engine = ColmiSyncEngine(writer: writer, decoder: ColmiDecoder())
    }

    override func tearDown() {
        engine = nil
        writer = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func feed(_ content: [UInt8]) {
        _ = engine.handleHistoryFrame(ColmiPacket.frame(content))
    }

    /// An "empty day" reply (`packetNr = 0xff`).
    private func feedEmptyDay(_ op: UInt8) { feed([op, 0xff]) }

    /// A paged day: header announcing `size` packets (cadence byte 5), then data packets 1..<`size`.
    private func feedPagedDay(_ op: UInt8, size: UInt8) {
        feed([op, 0x00, size, 0x05])
        for nr in 1..<size { feed([op, nr, 60, 61, 62]) }
    }

    private var lastFrame: [UInt8] { [UInt8](writer.frames.last ?? Data()) }

    private func hrRequest(daysAgo: Int) -> [UInt8] {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
        let epoch = ColmiSyncEngine.heartRateRequestEpoch(dayStart: day, timeZone: cal.timeZone)
        return ColmiEncoder().syncHeartRate(fromUnix: epoch)
    }

    /// Start a full sync and complete all eight activity days as empty → HR day 0 requested.
    private func driveToHeartRate() {
        engine.syncHistory()
        for _ in 0..<8 { feedEmptyDay(ColmiCommandID.syncActivity) }
    }

    /// … then all eight HR days as empty → stress requested.
    private func driveToStress() {
        driveToHeartRate()
        for _ in 0..<8 { feedEmptyDay(ColmiCommandID.syncHeartRate) }
    }

    /// … then stress, SpO2 and sleep → HRV day 0 requested.
    private func driveToHRV() {
        driveToStress()
        feedEmptyDay(ColmiCommandID.syncStress)
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSpo2)
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSleep)
    }

    // MARK: HR paging

    func testHeartRateDayEndsAtHeaderPageCountAndRequestsNextDay() {
        driveToHeartRate()
        XCTAssertEqual(lastFrame, hrRequest(daysAgo: 0))
        let before = writer.frames.count

        feed([ColmiCommandID.syncHeartRate, 0x00, 0x03, 0x05])   // header: 3 packets (0, 1, 2)
        feed([ColmiCommandID.syncHeartRate, 0x01, 0, 0, 0, 0, 60, 61])
        XCTAssertEqual(writer.frames.count, before, "packet 1 of 3 is not the last — keep waiting")

        feed([ColmiCommandID.syncHeartRate, 0x02, 62, 63])
        XCTAssertEqual(writer.frames.count, before + 1, "the last packet must end the day at once")
        XCTAssertEqual(lastFrame, hrRequest(daysAgo: 1), "next HR day requested, not the stress stage")
    }

    func testAllEightHeartRateDaysAreRequestedThenStress() {
        driveToHeartRate()
        for daysAgo in 0..<8 {
            XCTAssertEqual(lastFrame, hrRequest(daysAgo: daysAgo))
            feedPagedDay(ColmiCommandID.syncHeartRate, size: 4)
        }
        XCTAssertEqual(lastFrame, ColmiEncoder().syncStress())
    }

    func testHeartRateWithoutHeaderEndsOnPacket23() {
        driveToHeartRate()
        let before = writer.frames.count
        feed([ColmiCommandID.syncHeartRate, 22, 60])
        XCTAssertEqual(writer.frames.count, before)
        feed([ColmiCommandID.syncHeartRate, 23, 60])
        XCTAssertEqual(lastFrame, hrRequest(daysAgo: 1))
    }

    func testOutOfRangeHeaderFallsBackToDefault() {
        driveToHeartRate()
        let before = writer.frames.count
        feed([ColmiCommandID.syncHeartRate, 0x00, 0xc8, 0x05])   // size 200: garbled, ignored
        feed([ColmiCommandID.syncHeartRate, 0x01, 60])
        XCTAssertEqual(writer.frames.count, before, "packet 1 is not terminal without a usable header")
    }

    // MARK: Stress / HRV paging

    func testStressEndsOnHeaderPageCount() {
        driveToStress()
        XCTAssertEqual(lastFrame, ColmiEncoder().syncStress())
        feedPagedDay(ColmiCommandID.syncStress, size: 3)
        XCTAssertEqual(lastFrame, [UInt8](ColmiEncoder().bigDataSpo2()), "stress done after packet 2 of 3")
    }

    func testStressWithoutHeaderStillEndsOnPacket4() {
        driveToStress()
        let before = writer.frames.count
        for nr: UInt8 in 1...3 { feed([ColmiCommandID.syncStress, nr, 20]) }
        XCTAssertEqual(writer.frames.count, before)
        feed([ColmiCommandID.syncStress, 4, 20])
        XCTAssertEqual(lastFrame, [UInt8](ColmiEncoder().bigDataSpo2()))
    }

    func testHRVEndsOnHeaderPageCountAndRequestsNextDay() {
        driveToHRV()
        XCTAssertEqual(lastFrame, ColmiEncoder().syncHRV(daysAgo: 0))
        let before = writer.frames.count

        feed([ColmiCommandID.syncHRV, 0x00, 0x03, 0x1e])
        feed([ColmiCommandID.syncHRV, 0x01, 0x00, 40])
        XCTAssertEqual(writer.frames.count, before)
        feed([ColmiCommandID.syncHRV, 0x02, 41])
        XCTAssertEqual(lastFrame, ColmiEncoder().syncHRV(daysAgo: 1))
    }

    func testHeaderFromOneDayDoesNotLeakIntoTheNext() {
        driveToHRV()
        feedPagedDay(ColmiCommandID.syncHRV, size: 2)      // day 0 ends on packet 1
        XCTAssertEqual(lastFrame, ColmiEncoder().syncHRV(daysAgo: 1))
        let before = writer.frames.count
        feed([ColmiCommandID.syncHRV, 0x01, 0x00, 40])     // day 1, no header: fallback size 5
        XCTAssertEqual(writer.frames.count, before)
    }

    // MARK: Request bytes

    func testSleepRequestIsQRingNewSleepProtocol() {
        XCTAssertEqual([UInt8](ColmiEncoder().bigDataSleep()), [0xbc, 0x27, 0x02, 0x00, 0x81, 0x80, 0xff, 0x01])
    }

    func testSleepStageSendsTheNewRequest() {
        driveToStress()
        feedEmptyDay(ColmiCommandID.syncStress)
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSpo2)
        XCTAssertEqual(lastFrame, [0xbc, 0x27, 0x02, 0x00, 0x81, 0x80, 0xff, 0x01])
    }

    /// The CRC builder reproduces the SpO2 and temperature requests already verified on rings.
    func testOtherBigDataRequestsAreUnchanged() {
        XCTAssertEqual([UInt8](ColmiEncoder().bigDataSpo2()), [0xbc, 0x2a, 0x01, 0x00, 0xff, 0x00, 0xff])
        XCTAssertEqual([UInt8](ColmiEncoder().bigDataTemperature()), [0xbc, 0x25, 0x01, 0x00, 0x3e, 0x81, 0x02])
    }

    func testHeartRateRequestEpochIsLocalDateAtUTCMidnight() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcMidnight = utc.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        for id in ["Asia/Kolkata", "America/New_York", "UTC"] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: id)!
            let localMidnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
            XCTAssertEqual(
                ColmiSyncEngine.heartRateRequestEpoch(dayStart: localMidnight, timeZone: cal.timeZone),
                Int(utcMidnight.timeIntervalSince1970), id
            )
        }
    }

    // MARK: Nap sleep

    func testNapBigDataDecodesAsSleep() {
        let payload: [UInt8] = [0x01, 0x00, 0x08, 0xd0, 0x02, 0x0c, 0x03, ColmiCommandID.sleepLight, 30, ColmiCommandID.sleepDeep, 14]
        let frame = Data([ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleepNap,
                          UInt8(payload.count), 0x00, 0x00, 0x00] + payload)
        let events = ColmiDecoder().decodeBigData(frame)
        guard events.count == 1, case let .sleepTimeline(_, stages) = events[0] else {
            return XCTFail("expected one sleepTimeline, got \(events.map(\.kind))")
        }
        XCTAssertEqual(stages.count, 44)
    }
}
