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
            // 1-byte live SpO₂ %. UNVERIFIED (capture-inferred): values sat in 95–98, i.e. plausible.
            guard let spo2 = frame.payload.first else { return [.commandAck(commandId: frame.cmd)] }
            return [.spo2Result(value: Int(spo2), timestamp: now)]

        case (TK5FrameType.stream, TK5Command.liveExtended):
            // Live HRV appears at payload[3] on this frame (e.g. `00 00 00 4f` = 79 ms, matching the
            // app's live reading); other sub-frames carry it as 0 and are ignored. hrvRange-gated.
            let p = frame.payload
            guard p.count >= 4, p[3] > 0 else { return [.commandAck(commandId: frame.cmd)] }
            return [.hrvSample(value: Int(p[3]), timestamp: now)]

        // MARK: History records (be940003, type 0x05)

        case (TK5FrameType.register, TK5Command.historyRecordShort):
            // `[ts:4][hr:1]` — the single metric byte tracked the live HR range in the capture.
            // UNVERIFIED (capture-inferred).
            let p = frame.payload
            guard p.count >= 5 else { return [.commandAck(commandId: frame.cmd)] }
            return [.historyMeasurement(kind: .heartRate, value: Double(p[4]),
                                        timestamp: TK5Bytes.date(TK5Bytes.u32(p, 0)))]

        case (TK5FrameType.register, TK5Command.historyRecordLong):
            // `[ts:4][steps:2]…[hrv:1 @offset 11]…`. steps verified (0x027b = 635 matched the live
            // status frame); HRV verified against the app (payload[11] = 48 ms @1:00, 79 ms @1:32).
            // Steps → additive bucket (Colmi-style, timestamp-keyed so re-syncs are idempotent); HRV →
            // history measurement, both range-gated by RingEventBridge.
            let p = frame.payload
            guard p.count >= 6 else { return [.commandAck(commandId: frame.cmd)] }
            let timestamp = TK5Bytes.date(TK5Bytes.u32(p, 0))
            var events: [RingDecodedEvent] = [
                .activityBucket(timestamp: timestamp, steps: TK5Bytes.u16(p, 4), distanceMeters: 0),
            ]
            if p.count >= 12, p[11] > 0 {
                events.append(.historyMeasurement(kind: .hrv, value: Double(p[11]), timestamp: timestamp))
            }
            return events

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
}
