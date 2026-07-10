import Foundation

/// Decodes inbound TK5 frames into the shared `RingDecodedEvent`. Frames arrive already
/// CRC-validated (see `TK5Frame`), from either the command channel (be940001) or the async stream
/// (be940003); this decoder dispatches on `(type, cmd)` regardless of channel.
///
/// Confidence tags mirror the codebase convention: fields read straight out of the capture are
/// trusted; guessed offsets are tagged `// UNVERIFIED (capture-inferred)`. Everything routes through
/// `RingEventBridge`, which range-gates each metric, so a misdecoded byte is dropped rather than
/// persisted as garbage.
struct TK5Decoder {
    /// Decode one validated frame into the events it carries (usually one; unknown frames → `.unknown`).
    func decode(_ frame: TK5Frame, now: Date = Date()) -> [RingDecodedEvent] {
        switch (frame.type, frame.cmd) {

        // MARK: Async live stream (be940003, type 0x06)

        case (TK5FrameType.stream, TK5Command.liveStatus):
            // Cumulative day totals. steps verified against capture (0x027b = 635); distance/calories
            // are the adjacent u16s — UNVERIFIED (capture-inferred), but `applyActivityUpdate` uses
            // max() so an over-read can't corrupt the day.
            let p = frame.payload
            guard p.count >= 2 else { return [.commandAck(commandId: frame.cmd)] }
            let steps = TK5Bytes.u16(p, 0)
            let distance = Double(TK5Bytes.u16(p, 2))
            let calories = Double(TK5Bytes.u16(p, 4))
            return [.activityUpdate(timestamp: now, steps: steps, distanceMeters: distance, calories: calories)]

        case (TK5FrameType.stream, TK5Command.liveHeartRate):
            // 1-byte live bpm. Verified (climbed 82→86 across the capture).
            guard let bpm = frame.payload.first else { return [.commandAck(commandId: frame.cmd)] }
            return [.heartRateSample(bpm: Int(bpm), timestamp: now)]

        case (TK5FrameType.stream, TK5Command.liveSpo2):
            // 1-byte live SpO₂ % from the mode-0x02 (red-LED) stream; values sat in 95–98 in the
            // capture. Gate to a plausible range so a warm-up 0 isn't surfaced as a reading (the event
            // bridge doesn't range-gate SpO₂).
            guard let spo2 = frame.payload.first, (70...100).contains(spo2) else {
                return [.commandAck(commandId: frame.cmd)]
            }
            return [.spo2Result(value: Int(spo2), timestamp: now)]

        case (TK5FrameType.stream, TK5Command.liveExtended):
            return decodeLiveExtended(frame.payload, cmd: frame.cmd, now: now)

        // MARK: History records (be940003, type 0x05)

        case (TK5FrameType.register, TK5Command.historyRecordShort):
            // Packed **6-byte** HR history records: `[ts:4][flag:1][hr:1]`. One frame carries many —
            // e.g. eight hourly overnight samples (71,66,63,62,66,60,65,58 bpm @23:00–06:00, matched
            // to wall-clock) — so decode *every* record, not just the first (the earlier bug that hid
            // periodic data). hr is at offset 5.
            return records(in: frame.payload, size: 6).compactMap { r in
                let hr = r[5]
                guard hr > 0 else { return nil }
                return .historyMeasurement(kind: .heartRate, value: Double(hr),
                                           timestamp: TK5Bytes.date(TK5Bytes.u32(r, 0)))
            }

        case (TK5FrameType.register, TK5Command.historyRecordLong):
            return decodeCombinedVitals(frame.payload, cmd: frame.cmd)

        // MARK: Command channel (be940001)

        case (TK5FrameType.device, TK5Command.status):
            // 30-byte status. Battery at payload[5] (0x64 = 100 in the capture). UNVERIFIED
            // (capture-inferred); guarded to 0…100 downstream.
            let p = frame.payload
            var events: [RingDecodedEvent] = [.status(address: nil)]
            if p.count >= 6 { events.append(.battery(percent: Int(p[5]))) }
            return events

        case (TK5FrameType.device, TK5Command.deviceInfo):
            // 66-byte device/firmware block. A readable version string couldn't be pinned to a fixed
            // offset from one capture, so we just re-assert connected state here.
            return [.status(address: nil)]

        case (TK5FrameType.config, TK5Command.setTime):
            return [.timeSyncAck(timestamp: now)]

        default:
            return [.commandAck(commandId: frame.cmd)]
        }
    }

    /// The `06 03` live frame carries two shapes depending on the active measurement mode:
    ///   BP  (mode 0x01): `[sys][dia][hr?]…`  — verified against the app (111/74, 112/75)
    ///   HRV (mode 0x0a): `[0 0 0][hrv]…`      — verified against the app (79, 177 ms)
    /// Distinguish by the leading bytes; both are range-gated downstream.
    private func decodeLiveExtended(_ p: [UInt8], cmd: UInt8, now: Date) -> [RingDecodedEvent] {
        if p.count >= 2, (60...250).contains(p[0]), (30...160).contains(p[1]) {
            return [.bloodPressureSample(systolic: Int(p[0]), diastolic: Int(p[1]), timestamp: now)]
        }
        if p.count >= 4, p[3] > 0 {
            return [.hrvSample(value: Int(p[3]), timestamp: now)]
        }
        return [.commandAck(commandId: cmd)]
    }

    /// Packed **20-byte** combined-vitals history records: `[ts:4][steps:2][hr@6][sys?@7][dia?@8]
    /// [spo2@9][?@10][hrv@11]…`, many per frame. Emit periodic SpO₂ + HRV (HR comes from the paired
    /// `05 15` stream, so it isn't re-emitted here) plus per-day steps. HRV verified against the app
    /// (48/79 ms); SpO₂ inferred (95–98) and range-gated; BP verified (106/70 @6:00). Steps are a
    /// *cumulative* daily counter (rises through the day, resets to 0 at midnight), so they're emitted
    /// as an `activityUpdate` (per-day max) — not an additive bucket — with distance/calories 0 so
    /// `max()` leaves any live-status values intact.
    private func decodeCombinedVitals(_ payload: [UInt8], cmd: UInt8) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for r in records(in: payload, size: 20) {
            let ts = TK5Bytes.date(TK5Bytes.u32(r, 0))
            events.append(.activityUpdate(timestamp: ts, steps: TK5Bytes.u16(r, 4),
                                          distanceMeters: 0, calories: 0))
            if (60...250).contains(r[7]), (30...160).contains(r[8]) {
                events.append(.bloodPressureSample(systolic: Int(r[7]), diastolic: Int(r[8]), timestamp: ts))
            }
            if (70...100).contains(r[9]) {
                events.append(.historyMeasurement(kind: .spo2, value: Double(r[9]), timestamp: ts))
            }
            if r[11] > 0 {
                events.append(.historyMeasurement(kind: .hrv, value: Double(r[11]), timestamp: ts))
            }
        }
        return events.isEmpty ? [.commandAck(commandId: cmd)] : events
    }

    /// Decode a fully-reassembled sleep record (see `TK5Driver` for the multi-frame reassembly).
    /// Layout: a 20-byte header `[magic:2][totalLen:2 LE][startTs:4][endTs:4]…` followed by 8-byte
    /// stage segments `[stage:1][startTs:4 LE][durationSec:2 LE][pad:1]`. Segments are contiguous, so
    /// we expand each into per-minute `SleepStage`s and emit one `.sleepTimeline` anchored at the first
    /// segment. Stage mapping verified against the app's on-screen breakdown (deep 93 / light 249 /
    /// rem 130 min): `0xf1`=deep, `0xf2`=light, `0xf3`=rem, `0xf4`=awake.
    func decodeSleep(_ record: [UInt8]) -> [RingDecodedEvent] {
        let headerLen = 20
        let segmentLen = 8
        guard record.count >= headerLen + segmentLen else { return [] }

        var stages: [SleepStage] = []
        var startDate: Date?
        var i = headerLen
        while i + segmentLen <= record.count {
            let tag = record[i]
            guard let stage = sleepStage(tag) else { break }   // stop at padding / unknown tail
            let segStart = TK5Bytes.u32(Array(record[i...]), 1)
            let durationSec = TK5Bytes.u16(Array(record[i...]), 5)
            if startDate == nil { startDate = TK5Bytes.date(segStart) }
            let minutes = Int((Double(durationSec) / 60.0).rounded())
            stages.append(contentsOf: Array(repeating: stage, count: max(1, minutes)))
            i += segmentLen
        }

        guard let start = startDate, !stages.isEmpty else { return [] }
        return [.sleepTimeline(timestamp: start, stages: stages)]
    }

    /// Map a TK5 sleep stage tag to the shared `SleepStage`. Verified against the app's displayed
    /// deep/light/REM minutes; `nil` signals a non-stage byte (end of segment list).
    private func sleepStage(_ tag: UInt8) -> SleepStage? {
        switch tag {
        case 0xf1: return .deep
        case 0xf2: return .light
        case 0xf3: return .rem
        case 0xf4: return .awake
        default: return nil
        }
    }

    /// Split a packed history payload into fixed-size records, dropping any short trailing remainder.
    /// TK5 history frames concatenate many equal-size records (e.g. an hour's worth of samples), so a
    /// decoder must walk them all rather than reading only the first.
    private func records(in payload: [UInt8], size: Int) -> [[UInt8]] {
        guard size > 0 else { return [] }
        var out: [[UInt8]] = []
        var i = 0
        while i + size <= payload.count {
            out.append(Array(payload[i..<(i + size)]))
            i += size
        }
        return out
    }
}
