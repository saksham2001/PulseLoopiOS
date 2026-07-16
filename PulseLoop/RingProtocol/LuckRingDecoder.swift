import Foundation

/// Decodes reassembled LuckRing frames into the shared `RingDecodedEvent`. Frames arrive whole from
/// `LuckRingFrameAssembler`; this decoder dispatches on `dataType` and slices each record type per its
/// `ProcessDATA_TYPE_*` parser.
///
/// **Timestamps are true UTC Unix seconds** (`TimeUtil.s2CForDev(sec, true) == sec*1000`), so — unlike
/// the jring/YCBT clocks, which store local wall-clock — decoding is a plain `Date(timeIntervalSince1970:)`
/// with no offset to un-apply. Range gating lives in `RingEventBridge`, so a misdecoded byte is dropped
/// rather than persisted; the decoder only cuts records and drops the ring's "no sample" fillers.
///
/// **Every metric record uses one envelope**: `[total u16 LE][items u8]` then `items` fixed-stride
/// records. HR/HRV history and the live HR/HRV streams share the identical 5-byte record via the vendor's
/// `dealHeart` (a 3-byte sub-header + `[time u32][value u8]` records), so live vs. history is decided by
/// `dataType`, not by record shape.
struct LuckRingDecoder {
    // A flat opcode router — each dataType is an independent record layout, not branching logic.
    // swiftlint:disable:next cyclomatic_complexity
    func decode(_ frame: LuckRingFrame, now: Date = Date()) -> [RingDecodedEvent] {
        // A device ACK is a verdict on a command, not data.
        if frame.cmdType == .ack {
            return [.commandAck(commandId: frame.dataType)]
        }

        let p = frame.payload
        switch frame.dataType {
        case LuckRingDataType.devInfo:
            return decodeDeviceInfo(p)
        case LuckRingDataType.battery:
            guard let percent = p.first else { return [.commandAck(commandId: frame.dataType)] }
            return [.battery(percent: Int(percent))]

        case LuckRingDataType.realSport, LuckRingDataType.historySport:
            return decodeSport(p, dataType: frame.dataType)
        case LuckRingDataType.sleep:
            return decodeSleep(p, now: now)

        case LuckRingDataType.realHeart, LuckRingDataType.exerciseHeart:
            return decodeLiveHeart(p, now: now)
        case LuckRingDataType.historyHeart:
            return decodeHistory(p, kind: .heartRate)

        case LuckRingDataType.realO2:
            return decodeLiveSpO2(p, now: now)
        case LuckRingDataType.historyO2:
            return decodeHistory(p, kind: .spo2)

        case LuckRingDataType.realBP:
            return decodeLiveBP(p, now: now)
        case LuckRingDataType.historyBP:
            return decodeHistoryBP(p)

        case LuckRingDataType.realHRV:
            return decodeLive(p, now: now) { .hrvSample(value: Int($0), timestamp: $1) }
        case LuckRingDataType.historyHRV:
            return decodeHistory(p, kind: .hrv)

        case LuckRingDataType.realTemp:
            return decodeTemperature(p, now: now, history: false)
        case LuckRingDataType.historyTemp:
            return decodeTemperature(p, now: now, history: true)

        case LuckRingDataType.stress:
            return decodeLive(p, now: now) { .stressSample(value: Int($0), timestamp: $1) }
        case LuckRingDataType.stressHistory:
            return decodeHistory(p, kind: .stress)

        case LuckRingDataType.pairFinish, LuckRingDataType.findDevice, LuckRingDataType.devSync,
             LuckRingDataType.functionControl, LuckRingDataType.unbind:
            // Handshake/echo frames with no metric to persist — surfaced as acks (the raw-packet feed
            // still shows them). `devSync` (9) carries a MixInfo TLV of settings/function bits, but the
            // capability bitmap is obfuscated in the decompile, so nothing maps it yet.
            return [.commandAck(commandId: frame.dataType)]

        default:
            return [.unknown(commandId: frame.dataType, raw: Data(p))]
        }
    }

    // MARK: - Envelope helpers

    /// `[total u16 LE][items u8]` header, then `items` records. Returns each record's bytes, cut at the
    /// declared item count. When `stride` is nil it is derived from the payload — needed for temperature,
    /// whose 5-byte and 8-byte record variants share the same opcode (`K6_TempStruct.parse` vs
    /// `parseFloat`).
    private func records(_ payload: [UInt8], stride: Int?) -> [[UInt8]] {
        guard payload.count >= 3 else { return [] }
        let items = Int(payload[2])
        guard items > 0 else { return [] }
        let body = Array(payload[3...])
        let step = stride ?? (body.count / items)
        guard step > 0 else { return [] }
        var out: [[UInt8]] = []
        var offset = 0
        for _ in 0..<items where offset + step <= body.count {
            out.append(Array(body[offset..<(offset + step)]))
            offset += step
        }
        return out
    }

    private func ringDate(_ record: [UInt8]) -> Date {
        Date(timeIntervalSince1970: TimeInterval(LuckRingBytes.u32(record, 0)))
    }

    // MARK: - Records

    /// `K6_DevInfoStruct.getSoftwareVer()`: bytes `[1..5]` (customer.hardware.code.picture.font) joined by
    /// dots. Byte `[0]` is the item count and is not part of the version.
    private func decodeDeviceInfo(_ p: [UInt8]) -> [RingDecodedEvent] {
        guard p.count >= 6 else { return [.commandAck(commandId: LuckRingDataType.devInfo)] }
        let version = p[1...5].map { String(Int($0)) }.joined(separator: ".")
        return [.firmware(version: version)]
    }

    /// Sport records — 20 bytes each (`K6_Sport`): `[start u32][steps u32][distance u24(+pad)]`
    /// `[calories u24(+pad)][duration u24(+pad)]`. Emitted as `.activityBucket` (per-interval, summed into
    /// the day and upserted by timestamp) for both the live (4) and history (5) streams, so a re-sync is
    /// idempotent. Calories are intentionally dropped (`.activityBucket` carries none).
    private func decodeSport(_ p: [UInt8], dataType: UInt8) -> [RingDecodedEvent] {
        let recs = records(p, stride: 20)
        guard !recs.isEmpty else { return [.commandAck(commandId: dataType)] }
        return recs.map { r in
            .activityBucket(timestamp: ringDate(r),
                            steps: Int(LuckRingBytes.u32(r, 4)),
                            distanceMeters: Double(LuckRingBytes.u24(r, 8)))
        }
    }

    /// Live HR — 5-byte records `[time u32][bpm u8]` (`dealHeart`). An envelope with zero items is the
    /// ring signalling the measurement ended, surfaced as `.heartRateComplete`.
    private func decodeLiveHeart(_ p: [UInt8], now: Date) -> [RingDecodedEvent] {
        let recs = records(p, stride: 5)
        guard !recs.isEmpty else { return [.heartRateComplete(timestamp: now)] }
        return recs.map { .heartRateSample(bpm: Int($0[4]), timestamp: ringDate($0)) }
    }

    /// Live SpO₂ — 5-byte records `[time u32][spo2 u8]` (`K6_DATA_TYPE_REAL_O2`).
    private func decodeLiveSpO2(_ p: [UInt8], now: Date) -> [RingDecodedEvent] {
        let recs = records(p, stride: 5)
        guard !recs.isEmpty else { return [.spo2Complete(timestamp: now)] }
        return recs.map { .spo2Result(value: Int($0[4]), timestamp: ringDate($0)) }
    }

    /// Live blood pressure — 6-byte records `[time u32][sys u8][dia u8]` (`K6_DATA_TYPE_REAL_BP`).
    private func decodeLiveBP(_ p: [UInt8], now: Date) -> [RingDecodedEvent] {
        let recs = records(p, stride: 6)
        guard !recs.isEmpty else { return [.commandAck(commandId: LuckRingDataType.realBP)] }
        return recs.map {
            .bloodPressureSample(systolic: Int($0[4]), diastolic: Int($0[5]), timestamp: ringDate($0))
        }
    }

    /// A generic single-value live stream — 5-byte records `[time u32][value u8]` — mapped through a
    /// builder (HRV, stress). Empty envelope acks (nothing to complete).
    private func decodeLive(_ p: [UInt8], now: Date,
                            _ make: (UInt8, Date) -> RingDecodedEvent) -> [RingDecodedEvent] {
        let recs = records(p, stride: 5)
        guard !recs.isEmpty else { return [.commandAck(commandId: 0)] }
        return recs.map { make($0[4], ringDate($0)) }
    }

    /// History for a 5-byte `[time u32][value u8]` type → `.historyMeasurement`.
    private func decodeHistory(_ p: [UInt8], kind: MeasurementKind) -> [RingDecodedEvent] {
        let recs = records(p, stride: 5)
        guard !recs.isEmpty else { return [] }
        return recs.map { .historyMeasurement(kind: kind, value: Double($0[4]), timestamp: ringDate($0)) }
    }

    /// History blood pressure — 6-byte records fanned to a systolic and a diastolic row (each trends
    /// independently), mirroring `EventPersistenceSubscriber`'s two-row storage.
    private func decodeHistoryBP(_ p: [UInt8]) -> [RingDecodedEvent] {
        let recs = records(p, stride: 6)
        guard !recs.isEmpty else { return [] }
        return recs.flatMap { r -> [RingDecodedEvent] in
            let date = ringDate(r)
            return [
                .historyMeasurement(kind: .bloodPressureSystolic, value: Double(r[4]), timestamp: date),
                .historyMeasurement(kind: .bloodPressureDiastolic, value: Double(r[5]), timestamp: date),
            ]
        }
    }

    /// Temperature — `K6_TempStruct`: `[time u32][value u16 LE]/10`. The stride is derived from the
    /// envelope so both the 5-byte (`parse`) and 8-byte (`parseFloat`) record variants decode; the value
    /// is read as a u16 when the record is wide enough, else a single byte, and scaled by 10.
    private func decodeTemperature(_ p: [UInt8], now: Date, history: Bool) -> [RingDecodedEvent] {
        let recs = records(p, stride: nil)
        guard !recs.isEmpty else {
            return history ? [] : [.commandAck(commandId: LuckRingDataType.realTemp)]
        }
        return recs.map { r in
            let raw = r.count >= 6 ? LuckRingBytes.u16(r, 4) : Int(r.count > 4 ? r[4] : 0)
            let celsius = Double(raw) / 10.0
            let date = ringDate(r)
            return history
                ? .historyMeasurement(kind: .temperature, value: celsius, timestamp: date)
                : .temperatureSample(celsius: celsius, timestamp: date)
        }
    }

    // MARK: - Sleep

    /// Sleep timeline (`ProcessDATA_TYPE_SLEEP`): `[total u16][pageCount u8]`, then `pageCount` pages of
    /// `[validCount u8]` + 15 × `[type u8][time u32 LE]` (76 B/page, only `validCount` entries valid).
    ///
    /// Types (`CEBC.SLEEPSTATUS`): 1 start, 2 deep, 3 light, 4 wake (ends a session), 5 movement. Each
    /// entry's duration is the gap to the next entry; the segment's stage is the *earlier* entry's type,
    /// mapped 1/3/5→light, 2→deep. A session runs from a start (or the first entry) to a wake, and is
    /// emitted as a per-minute stage array stamped at the session start — the exact shape
    /// `EventPersistenceSubscriber.persistSleepTimeline` groups back into stage blocks.
    private func decodeSleep(_ p: [UInt8], now: Date) -> [RingDecodedEvent] {
        guard p.count >= 3 else { return [.commandAck(commandId: LuckRingDataType.sleep)] }
        let pageCount = Int(p[2])

        var entries: [(type: UInt8, time: UInt32)] = []
        var offset = 3
        for _ in 0..<pageCount {
            guard offset < p.count else { break }
            let valid = Int(p[offset])
            offset += 1
            for slot in 0..<15 {
                guard offset + 5 <= p.count else { break }
                if slot < valid {
                    entries.append((type: p[offset], time: LuckRingBytes.u32(p, offset + 1)))
                }
                offset += 5
            }
        }

        return sleepSessions(from: entries)
    }

    private func sleepSessions(from entries: [(type: UInt8, time: UInt32)]) -> [RingDecodedEvent] {
        var sessions: [RingDecodedEvent] = []
        var sessionStart: UInt32?
        var stages: [SleepStage] = []

        func flush() {
            if let start = sessionStart, !stages.isEmpty {
                sessions.append(.sleepTimeline(timestamp: Date(timeIntervalSince1970: TimeInterval(start)),
                                               stages: stages))
            }
            sessionStart = nil
            stages = []
        }

        for i in entries.indices {
            let entry = entries[i]
            if entry.type == 1 { flush() }                       // explicit session start
            if sessionStart == nil { sessionStart = entry.time }  // implicit start
            if entry.type == 4 { flush(); continue }             // wake ends the session

            guard i + 1 < entries.count else { continue }        // last entry has no duration
            let delta = Int(entries[i + 1].time) - Int(entry.time)
            let minutes = max(0, delta / 60)
            let stage = sleepStage(entry.type)
            stages.append(contentsOf: repeatElement(stage, count: minutes))
        }
        flush()
        return sessions
    }

    private func sleepStage(_ type: UInt8) -> SleepStage {
        switch type {
        case 2: return .deep
        case 4: return .awake
        default: return .light   // 1 start, 3 light, 5 movement all render as light sleep
        }
    }
}
