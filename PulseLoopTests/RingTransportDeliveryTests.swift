import XCTest
@testable import PulseLoop

@MainActor
final class RingTransportDeliveryTests: XCTestCase {
    func testFragmentsAndRejectedNotificationsAreCapturedBeforeDecode() {
        var events: [PulseEvent] = []
        for data in [Data([0xAB]), Data([0x00, 0xFF])] {
            let before = events.count
            RingNotificationDelivery.receive(data, decode: {
                XCTAssertEqual(events.count, before + 1, "Raw bytes must be emitted before decode begins")
                return []
            }, publish: { events.append($0) }, deliver: { _ in XCTFail("No decoded frame") })
        }
        XCTAssertEqual(events.count, 2)
        guard case let .rawPacket(direction, data, _) = events[0] else { return XCTFail("Missing raw capture") }
        XCTAssertEqual(direction, .incoming)
        XCTAssertEqual(data, Data([0xAB]))
    }

    func testMultipleDecodedFramesHaveOneRawCaptureAndFullTypedFanout() {
        let decoded: [RingDecodedEvent] = [
            .heartRateSample(bpm: 72, timestamp: Date()),
            .measurementRejected(mode: 0x09)
        ]
        var events: [PulseEvent] = []
        RingNotificationDelivery.receive(Data([0xAB, 1, 2]), decode: { decoded },
            publish: { events.append($0) },
            deliver: { events.append(contentsOf: RingNotificationDelivery.events(for: $0)) })
        XCTAssertEqual(events.filter { if case .rawPacket = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.filter { if case .decodedPacket = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(events.filter { if case .heartRateSample = $0 { return true }; return false }.count, 1)
    }

    func testTrackedWriteSuccessCompletesExactlyOnceAndDisarmsDeadline() async throws {
        var completions = 0
        let tracked = RingTrackedWrite(timeoutNanoseconds: 1_000_000, timeoutError: TestFailure.timeout,
            onTimeout: { XCTFail("A completed write must not time out") }, completion: { result in
                if case .failure = result { XCTFail("Expected successful transport") }
                completions += 1
            })
        tracked.finish(.success(()))
        tracked.finish(.failure(TestFailure.timeout))
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(completions, 1)
    }

    func testTrackedWriteErrorOrDisconnectCompletesExactlyOnce() {
        var completions = 0
        let tracked = RingTrackedWrite(timeoutError: TestFailure.timeout, onTimeout: {}, completion: { result in
            guard case .failure = result else { return XCTFail("Expected transport failure") }
            completions += 1
        })
        tracked.finish(.failure(CancellationError()))
        tracked.finish(.success(()))
        XCTAssertEqual(completions, 1)
    }

    func testTrackedWriteDeadlineIncludesAnUnsentBackpressuredWrite() async throws {
        var retired = false
        var completions = 0
        let tracked = RingTrackedWrite(timeoutNanoseconds: 1_000_000, timeoutError: TestFailure.timeout,
            onTimeout: { retired = true }, completion: { result in
                XCTAssertTrue(retired, "Retire the old transport before notifying the engine")
                guard case .failure = result else { return XCTFail("Expected transport deadline") }
                completions += 1
            })
        try await Task.sleep(nanoseconds: 10_000_000)
        tracked.finish(.success(())) // A late ATT callback cannot overwrite the timeout.
        XCTAssertEqual(completions, 1)
    }

    private enum TestFailure: Error { case timeout }
}
