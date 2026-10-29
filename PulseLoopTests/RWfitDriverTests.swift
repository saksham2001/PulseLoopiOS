import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The driver's two family-defining behaviours: **framing selection from the discovered GATT**
/// (the whole reason `WearableDriver.servicesDiscovered` exists) and **ACK-before-decode** on both
/// wire protocols — plus the command gate's single-outstanding discipline.
@MainActor
final class RWfitDriverTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
    }

    private let notify = CBUUID(string: RWfitUUIDs.notify)
    private let dataService = CBUUID(string: RWfitUUIDs.service)

    private func deviceFrame(cmd: UInt8, payload: [UInt8], serial: Int = 7) -> Data {
        var bytes: [UInt8] = [0x7e, 0x01, cmd, 0x00, UInt8(payload.count)]
        bytes += RWfitBytes.packU16BE(serial)
        bytes.append(payload.isEmpty ? 0 : RWfitBytes.xorChecksum(payload))
        bytes += payload
        return Data(bytes)
    }

    // MARK: - Framing selection

    func testDefaultsToLegacyFraming() {
        let driver = RWfitDriver(writer: FakeWriter())
        XCTAssertEqual(driver.framing, .legacy)
        driver.servicesDiscovered([dataService])
        XCTAssertEqual(driver.framing, .legacy, "A00A alone is only a legacy starting hint")
    }

    func testJieliServiceSelectsJieliFraming() {
        let driver = RWfitDriver(writer: FakeWriter())
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])
        XCTAssertEqual(driver.framing, .jieli)
    }

    func testTelinkOrPixartOTAAlsoSelectJieli() {
        // `r5/b.java:703-727`: the Telink/PixArt OTA services flip the same platform flag as AE00.
        let telink = RWfitDriver(writer: FakeWriter())
        telink.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.telinkOTA)])
        XCTAssertEqual(telink.framing, .jieli)

        let pixart = RWfitDriver(writer: FakeWriter())
        pixart.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.pixartOTA)])
        XCTAssertEqual(pixart.framing, .jieli)
    }

    func testReconnectRedecidesFraming() {
        let driver = RWfitDriver(writer: FakeWriter())
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])
        driver.connectionDidEnd()
        driver.connectionDidStart()
        driver.servicesDiscovered([dataService])
        XCTAssertEqual(driver.framing, .legacy, "each link's discovery decides afresh")
    }

    // MARK: - Legacy ingest

    func testLegacyDeviceFrameIsAckedBeforeDecode() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService])

        let events = driver.ingest(deviceFrame(cmd: 0x01, payload: [0, 0, 88], serial: 5), from: notify)

        XCTAssertEqual(writer.sent.count, 1, "a device frame must be ACKed")
        let ack = [UInt8](writer.sent[0])
        XCTAssertEqual(ack[2], RWfitLegacyCommand.appAck)
        XCTAssertEqual(Array(ack[8...]), [0x00, 0x05, 0x01, 0x00], "[serial, cmd, ok]")
        guard case let .battery(percent)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(percent, 88)
    }

    func testLegacyChecksumFailureSendsNack() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService])

        var corrupted = [UInt8](deviceFrame(cmd: 0x01, payload: [0, 0, 88], serial: 5))
        corrupted[8] ^= 0xff
        let events = driver.ingest(Data(corrupted), from: notify)

        XCTAssertTrue(events.isEmpty)
        let nack = [UInt8](writer.sent[0])
        XCTAssertEqual(Array(nack[8...]), [0x00, 0x05, 0x01, 0x02], "status 2 asks for a retransmit")
    }

    // MARK: - JieLi ingest

    func testReplyBodySurvivesBothResponseFlagsWithoutInferredCapabilities() {
        for isAck in [false, true] {
            let writer = FakeWriter()
            let driver = RWfitDriver(writer: writer)
            let events = driver.ingest(RWfitJLCodec().encode(payload: [2, 3, 0x10, 76, 0, 0], isAck: isAck), from: notify)
            XCTAssertEqual(writer.sent.count, isAck ? 0 : 1)
            XCTAssertTrue(driver.framingValidated)
            XCTAssertEqual(driver.framing, .jieli)
            XCTAssertTrue(events.contains { if case .battery(percent: 76) = $0 { true } else { false } })
            XCTAssertFalse(events.contains { if case .supportFunctions = $0 { true } else { false } })
        }
    }

    func testMalformedModernFrameCannotValidateFramingOrGrantCapabilities() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        var frame = RWfitJLCodec().encode(payload: [2, 3, 0x10, 76, 0, 0])
        frame[6] ^= 0xff
        XCTAssertTrue(driver.ingest(frame, from: notify).isEmpty)
        XCTAssertFalse(driver.framingValidated)
        XCTAssertTrue(writer.sent.isEmpty)
    }

    func testPushIsDecodedWithoutAcknowledgement() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        var frame = RWfitJLCodec().encode(payload: [2, 3, 0x10, 76, 0, 0])
        frame[1] = 0x21
        let events = driver.ingest(frame, from: notify)
        XCTAssertTrue(writer.sent.isEmpty)
        XCTAssertTrue(events.contains { if case .battery(percent: 76) = $0 { true } else { false } })
    }

    private final class TrackedWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        var confirmations: [@MainActor (Result<Void, Error>) -> Void] = []
        func enqueue(_ command: Data) { sent.append(command) }
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            sent.append(command)
            confirmations.append(completion)
        }
    }

    private func waitForWrites(_ count: Int, writer: TrackedWriter) async {
        for _ in 0..<100 {
            if writer.sent.count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected \(count) writes, got \(writer.sent.count)")
    }

    func testGateRetainsEarlyResponseUntilActualWriteConfirmation() async throws {
        let writer = TrackedWriter()
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec(), responseTimeout: 0.01)
        gate.framing = .jieli
        var completed = false
        let task = Task { @MainActor in
            let value = try await gate.execute(.jieli(payload: [2, 3, 0x10]))
            completed = true
            return value
        }
        await waitForWrites(1, writer: writer)
        gate.noteJieliFrame(flag: 0x11, triple: .init(cmd: 2, key: 3, keyFlag: 0), payload: [2, 3, 0, 76])
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(completed)
        XCTAssertEqual(writer.sent.count, 1, "Response timer must not run while queued for transmission")
        writer.confirmations[0](.success(()))
        let value = try await task.value
        XCTAssertEqual(value, [2, 3, 0, 76])
        gate.cancel()
    }

    func testGateIgnoresPushAndWrongCommandThenReturnsWriteFailure() async {
        let writer = TrackedWriter()
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec())
        let task = Task { try await gate.execute(.jieli(payload: [2, 3, 0x10])) }
        await waitForWrites(1, writer: writer)
        gate.noteJieliFrame(flag: 0x21, triple: .init(cmd: 2, key: 3, keyFlag: 0), payload: [2, 3, 0, 76])
        gate.noteJieliFrame(flag: 0x11, triple: .init(cmd: 2, key: 4, keyFlag: 0), payload: [2, 4, 0])
        writer.confirmations[0](.failure(RWfitSessionError.unavailable))
        do { _ = try await task.value; XCTFail("Write failure must propagate") }
        catch { XCTAssertEqual(error.localizedDescription, RWfitSessionError.unavailable.localizedDescription) }
        gate.cancel()
    }

    func testGateRetriesModernRequestTwiceThenFails() async {
        let writer = TrackedWriter()
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec(), responseTimeout: 0.01)
        gate.framing = .jieli
        let task = Task { try await gate.execute(.jieli(payload: [2, 3, 0x10])) }
        for attempt in 0..<3 {
            await waitForWrites(attempt + 1, writer: writer)
            guard writer.confirmations.count > attempt else { gate.cancel(); return }
            writer.confirmations[attempt](.success(()))
        }
        do { _ = try await task.value; XCTFail("Silence must fail") }
        catch { XCTAssertEqual(error.localizedDescription, RWfitSessionError.timeout.localizedDescription) }
        XCTAssertEqual(writer.sent.count, 3)
        gate.cancel()
    }

    func testLegacyAckDoesNotCompletePayloadReadAndCancellationReleasesWaiter() async {
        let writer = TrackedWriter()
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec())
        var completed = false
        let task = Task { @MainActor in
            _ = try await gate.execute(.legacy(cmd: 1, payload: []))
            completed = true
        }
        await waitForWrites(1, writer: writer)
        writer.confirmations[0](.success(()))
        gate.noteLegacyAck(cmd: 1, serial: 1)
        await Task.yield()
        XCTAssertFalse(completed)
        gate.cancel()
        do { try await task.value; XCTFail("Cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDestructiveDeleteIsNeverAutomaticallyRetried() async {
        let writer = TrackedWriter()
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec(), responseTimeout: 0.01)
        gate.framing = .jieli
        let task = Task { try await gate.execute(.jieli(payload: [5, 5, 0x30]), needsPayload: false) }
        await waitForWrites(1, writer: writer)
        writer.confirmations[0](.success(()))
        do { _ = try await task.value; XCTFail("Lost delete acknowledgement must fail") }
        catch { XCTAssertEqual(error.localizedDescription, RWfitSessionError.timeout.localizedDescription) }
        XCTAssertEqual(writer.sent.count, 1, "Retry could consume a page that was never journaled")
        gate.cancel()
    }

}
