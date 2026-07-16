import XCTest
@testable import PulseLoop

/// The decoder's record cutting, per `ProcessDATA_TYPE_*`: battery, firmware, the metric history fan-outs,
/// the sport u24 fields, the paged sleep timeline (sessions → per-minute stages), the empty-envelope
/// "ended" markers, and the /10 temperature scaling. Range gating is `RingEventBridge`'s job, so these
/// assert the raw decode.
@MainActor
final class LuckRingDecoderTests: XCTestCase {
    private let decoder = LuckRingDecoder()
    private let base: UInt32 = 1_700_000_000
    private var baseDate: Date { Date(timeIntervalSince1970: TimeInterval(base)) }

    /// Concatenate byte chunks without `+` chains — CI's older Swift compiler times out
    /// type-checking heterogeneous `[UInt8] + [literal]` expressions ("unable to type-check
    /// this expression in reasonable time").
    private func cat(_ parts: [UInt8]...) -> [UInt8] {
        parts.flatMap { $0 }
    }

    // Envelope: [total u16 LE][items u8] + records.
    private func envelope(items: Int, records: [[UInt8]]) -> [UInt8] {
        cat(LuckRingBytes.le16(items), [UInt8(items)], records.flatMap { $0 })
    }

    private func frame(_ dataType: UInt8, _ payload: [UInt8], cmd: LuckRingCmdType = .send) -> LuckRingFrame {
        LuckRingFrame(cmdType: cmd, dataType: dataType, payload: payload)
    }

    private func le24(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff)]
    }

    // MARK: Simple frames

    func testBattery() {
        guard case let .battery(percent) = decoder.decode(frame(3, [85, 1])).first else {
            return XCTFail("expected battery")
        }
        XCTAssertEqual(percent, 85)
    }

    func testFirmwareStringJoinsBytesOneToFive() {
        // [items, customer, hardware, code, picture, font] → "customer.hardware.code.picture.font".
        guard case let .firmware(version) = decoder.decode(frame(2, [6, 1, 2, 3, 4, 5])).first else {
            return XCTFail("expected firmware")
        }
        XCTAssertEqual(version, "1.2.3.4.5")
    }

    func testDeviceAckDecodesToCommandAck() {
        guard case let .commandAck(id) = decoder.decode(frame(111, [1], cmd: .ack)).first else {
            return XCTFail("expected commandAck")
        }
        XCTAssertEqual(id, 111)
    }

    // MARK: History fan-outs

    func testHeartRateHistoryFansOutPerRecord() {
        let payload = envelope(items: 2, records: [
            cat(LuckRingBytes.le32(base), [72]),
            cat(LuckRingBytes.le32(base + 60), [75]),
        ])
        let events = decoder.decode(frame(8, payload))
        let readings: [(Double, Date)] = events.compactMap {
            if case let .historyMeasurement(kind, value, ts) = $0, kind == .heartRate { return (value, ts) }
            return nil
        }
        XCTAssertEqual(readings.map(\.0), [72, 75])
        XCTAssertEqual(readings.first?.1, baseDate)
    }

    func testSpo2HistoryDecodes() {
        let payload = envelope(items: 1, records: [cat(LuckRingBytes.le32(base), [97])])
        guard case let .historyMeasurement(kind, value, _) = decoder.decode(frame(40, payload)).first else {
            return XCTFail("expected spo2 history")
        }
        XCTAssertEqual(kind, .spo2)
        XCTAssertEqual(value, 97)
    }

    func testBloodPressureHistoryFansOutSystolicAndDiastolic() {
        let payload = envelope(items: 1, records: [cat(LuckRingBytes.le32(base), [120, 80])])
        let events = decoder.decode(frame(41, payload))
        let kinds = events.compactMap { evt -> (MeasurementKind, Double)? in
            if case let .historyMeasurement(kind, value, _) = evt { return (kind, value) }
            return nil
        }
        XCTAssertEqual(kinds.count, 2)
        XCTAssertTrue(kinds.contains { $0 == (.bloodPressureSystolic, 120) })
        XCTAssertTrue(kinds.contains { $0 == (.bloodPressureDiastolic, 80) })
    }

    func testHrvHistoryDecodes() {
        let payload = envelope(items: 1, records: [cat(LuckRingBytes.le32(base), [45])])
        guard case let .historyMeasurement(kind, value, _) = decoder.decode(frame(42, payload)).first else {
            return XCTFail("expected hrv history")
        }
        XCTAssertEqual(kind, .hrv)
        XCTAssertEqual(value, 45)
    }

    func testTemperatureScalesByTenFromTheWideRecord() {
        // 8-byte record (`parseFloat`): [time u32][value u16 LE]/10 (+2 pad). 365 → 36.5 °C.
        let payload = envelope(items: 1, records: [cat(LuckRingBytes.le32(base), LuckRingBytes.le16(365), [0, 0])])
        guard case let .historyMeasurement(kind, value, _) = decoder.decode(frame(47, payload)).first else {
            return XCTFail("expected temperature history")
        }
        XCTAssertEqual(kind, .temperature)
        XCTAssertEqual(value, 36.5, accuracy: 0.001)
    }

    // MARK: Live streams

    func testLiveHeartRateSamplesAndEndedMarker() {
        let stream = envelope(items: 1, records: [cat(LuckRingBytes.le32(base), [66])])
        guard case let .heartRateSample(bpm, _) = decoder.decode(frame(7, stream)).first else {
            return XCTFail("expected live HR sample")
        }
        XCTAssertEqual(bpm, 66)

        // Empty envelope (items 0) = the measurement ended.
        let ended = decoder.decode(frame(7, envelope(items: 0, records: [])))
        guard case .heartRateComplete = ended.first else {
            return XCTFail("expected heartRateComplete for an empty envelope, got \(ended)")
        }
    }

    func testLiveBloodPressureDecodes() {
        let payload = envelope(items: 1, records: [cat(LuckRingBytes.le32(base), [118, 76])])
        guard case let .bloodPressureSample(sys, dia, _) = decoder.decode(frame(18, payload)).first else {
            return XCTFail("expected live BP")
        }
        XCTAssertEqual(sys, 118)
        XCTAssertEqual(dia, 76)
    }

    // MARK: Sport

    func testSportRecordDecodesU24Fields() {
        // [start u32][steps u32][distance u24+pad][calories u24+pad][duration u24+pad].
        let record = cat(LuckRingBytes.le32(base), LuckRingBytes.le32(1234),
                         le24(5000), [0], le24(300), [0], le24(600), [0])
        let events = decoder.decode(frame(5, envelope(items: 1, records: [record])))
        guard case let .activityBucket(ts, steps, distance) = events.first else {
            return XCTFail("expected activityBucket, got \(events)")
        }
        XCTAssertEqual(ts, baseDate)
        XCTAssertEqual(steps, 1234)
        XCTAssertEqual(distance, 5000)
    }

    // MARK: Sleep

    /// One session: start → 5 min light, deep → 10 min deep, wake ends it. The 15-slot page is padded.
    func testSleepSingleSessionExpandsToPerMinuteStages() {
        let entries: [(UInt8, UInt32)] = [
            (1, base),           // session start
            (2, base + 300),     // deep, 5 min after start
            (4, base + 900),     // wake, 10 min after the deep entry
        ]
        let events = decoder.decode(frame(6, sleepPayload(pages: [(3, entries)])))
        guard case let .sleepTimeline(ts, stages) = events.first else {
            return XCTFail("expected sleepTimeline, got \(events)")
        }
        XCTAssertEqual(ts, baseDate)
        XCTAssertEqual(stages.prefix(5), ArraySlice([.light, .light, .light, .light, .light]))
        XCTAssertEqual(stages.count, 15)
        XCTAssertEqual(stages.suffix(10), ArraySlice(Array(repeating: SleepStage.deep, count: 10)))
    }

    /// Type 5 (movement) maps to light; two sessions separated by a wake both surface.
    func testSleepMultiSessionAndMovementMapping() {
        let first: [(UInt8, UInt32)] = [
            (1, base), (5, base + 120), (4, base + 300),
        ]
        let second: [(UInt8, UInt32)] = [
            (1, base + 3600), (2, base + 3720), (4, base + 3900),
        ]
        let events = decoder.decode(frame(6, sleepPayload(pages: [(3, first), (3, second)])))
        let sessions = events.compactMap { evt -> (Date, [SleepStage])? in
            if case let .sleepTimeline(ts, stages) = evt { return (ts, stages) }
            return nil
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions[0].1.allSatisfy { $0 == .light }, "start + movement both render as light")
        XCTAssertEqual(sessions[1].0, Date(timeIntervalSince1970: TimeInterval(base + 3600)))
    }

    // Build a sleep payload: [total u16][pageCount], then each page = [validCount] + 15 × [type, time u32].
    private func sleepPayload(pages: [(valid: Int, entries: [(UInt8, UInt32)])]) -> [UInt8] {
        var out = cat(LuckRingBytes.le16(0), [UInt8(pages.count)])
        for page in pages {
            out.append(UInt8(page.valid))
            for slot in 0..<15 {
                if slot < page.entries.count {
                    out.append(page.entries[slot].0)
                    out.append(contentsOf: LuckRingBytes.le32(page.entries[slot].1))
                } else {
                    out.append(contentsOf: [0, 0, 0, 0, 0])
                }
            }
        }
        return out
    }
}
