import Foundation
import os.log

private let ycbtLog = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "YCBTDecoder")

/// Decodes inbound YCBT frames into the shared `RingDecodedEvent`. Frames arrive already reassembled
/// (`YCBTFrameAssembler`) and CRC-validated (`YCBTFrame`), from either the command channel (be940001)
/// or the async stream (be940003); this decoder dispatches on `(type, cmd)` regardless of channel.
///
/// **Health-group (`0x05`) frames never reach here** — the driver routes them into
/// `YCBTHistoryTransfer`, which reassembles a whole transfer before `YCBTHealthRecords` cuts it into
/// records. History records are packed back-to-back and chopped at arbitrary frame boundaries, so
/// decoding one per-frame loses every record that straddles two (see `docs/YCBT-Protocol.md` §4).
///
/// Everything routes through `RingEventBridge`, which range-gates each metric, so a misdecoded byte is
/// dropped rather than persisted as garbage.
struct YCBTDecoder {
    /// Decode one validated frame into the events it carries. Dispatch is on the **group** first, exactly
    /// as `YCBTClientImpl.bleDataResponse` does — the key byte only means anything within its group
    /// (`0x00` is GetDeviceInfo in group 2, the live-status stream in group 6, and find-phone in group 4).
    ///
    /// - Parameter startedMode: the mode of the `03 2f` **start** still awaiting its reply, or nil if the
    ///   last live-measurement command we sent was a stop (or none was). The ring's reply carries a status
    ///   but not a mode, so the decoder cannot know on its own *which* measurement a refusal refers to —
    ///   `YCBTDriver`, the one thing that sees both directions, supplies it.
    func decode(_ frame: YCBTFrame, now: Date = Date(), startedMode: UInt8? = nil) -> [RingDecodedEvent] {
        switch frame.type {
        case YCBTGroup.real:
            return decodeRealStream(frame, now: now)

        // Auto-ACKed by `YCBTDriver` *before* this decode runs — the ring retransmits until it is.
        case YCBTGroup.devControl:
            return decodeDevControlPush(frame.cmd, payload: frame.payload, now: now)

        case YCBTGroup.get:
            return decodeGetReply(frame)

        case YCBTGroup.appControl where frame.cmd == YCBTCommand.liveMeasurement:
            return decodeMeasurementStartReply(frame.payload, startedMode: startedMode)

        case YCBTGroup.setting where frame.cmd == YCBTSettingKey.setTime:
            return [.timeSyncAck(timestamp: now)]

        default:
            return [.commandAck(commandId: frame.cmd)]
        }
    }

    // MARK: - AppControl replies (group 0x03)

    /// The ring's answer to `03 2f {enable, mode}` — one status byte (§5.1 / `YCBTMeasurementMode.isAccepted`).
    ///
    /// `0x00` is "started", and is the only reply the app has ever acted on. Anything else is the firmware
    /// declining: the R99 answers `0x01` to mode `0x0a` (HRV), a sensor it does not have. Surfaced as
    /// `.measurementRejected` so the in-flight spot measurement can fail immediately instead of polling a
    /// stream the ring already told us it will never send.
    ///
    /// Two things keep a *stray* refusal from cancelling the wrong measurement, and both are deliberate:
    ///
    /// 1. `startedMode` is nil unless a start is actually outstanding — a rejected **stop** is just an ack
    ///    (nothing is in flight to cancel), and a duplicate/late reply finds the mode already cleared.
    /// 2. The mode travels with the event, so `RingSyncCoordinator` can check it against the measurement
    ///    it is actually running before failing anything.
    private func decodeMeasurementStartReply(_ p: [UInt8], startedMode: UInt8?) -> [RingDecodedEvent] {
        let ack: [RingDecodedEvent] = [.commandAck(commandId: YCBTCommand.liveMeasurement)]
        // A status is exactly one byte (the SDK's own `isError` shape); anything else is not a verdict.
        guard p.count == 1, let status = p.first, !YCBTMeasurementMode.isAccepted(status: status),
              let mode = startedMode else { return ack }
        ycbtLog.info("03 2f mode \(mode, privacy: .public) refused → status \(status, privacy: .public)")
        return [.measurementRejected(mode: mode)]
    }

    // MARK: - Async live stream (be940003, group 0x06)

    private func decodeRealStream(_ frame: YCBTFrame, now: Date) -> [RingDecodedEvent] {
        let p = frame.payload
        switch frame.cmd {
        case YCBTCommand.liveStatus:
            // Cumulative day totals. steps verified against capture (0x027b = 635); distance/calories
            // are the adjacent u16s — UNVERIFIED (capture-inferred), but `applyActivityUpdate` uses
            // max() so an over-read can't corrupt the day.
            guard p.count >= 2 else { return [.commandAck(commandId: frame.cmd)] }
            return [.activityUpdate(timestamp: now, steps: YCBTBytes.u16(p, 0),
                                    distanceMeters: Double(YCBTBytes.u16(p, 2)),
                                    calories: Double(YCBTBytes.u16(p, 4)))]

        case YCBTCommand.liveHeartRate:
            // 1-byte live bpm. Verified (climbed 82→86 across the capture).
            guard let bpm = p.first else { return [.commandAck(commandId: frame.cmd)] }
            return [.heartRateSample(bpm: Int(bpm), timestamp: now)]

        case YCBTCommand.liveSpo2:
            // 1-byte live SpO₂ % from the mode-0x02 (red-LED) stream; values sat in 95–98 in the
            // capture. Gate to a plausible range so a warm-up 0 isn't surfaced as a reading — `.spo2Result`
            // is the one metric `RingEventBridge` does not range-gate, so the decoder must.
            guard let spo2 = p.first, RingEventBridge.spo2Range.contains(Int(spo2)) else {
                return [.commandAck(commandId: frame.cmd)]
            }
            return [.spo2Result(value: Int(spo2), timestamp: now)]

        case YCBTCommand.liveVitals:
            return decodeLiveVitals(p, cmd: frame.cmd, now: now)

        case YCBTCommand.liveBattery:
            // `06 15` battery push (`unpackUploadBatteryLevel`): `[chargingStatus][percent]`. The ring
            // sends it unprompted on charge/level changes, so battery stays fresh without polling `02 00`.
            // The charging flag has no home in `RingDecodedEvent` and is dropped.
            guard p.count >= 2 else { return [.commandAck(commandId: frame.cmd)] }
            return [.battery(percent: Int(p[1]))]

        case YCBTCommand.liveWearingStatus:
            // `06 13` (`unpackWearingStatusData`): `[ts:u32 2000-epoch][status]`. **UNVERIFIED polarity** —
            // the SDK and the app both forward `status` without ever asserting which value means "worn",
            // so nonzero is taken as worn. Harmless: this event produces no `PulseEvent` (debug feed only).
            guard p.count >= 5 else { return [.commandAck(commandId: frame.cmd)] }
            return [.wearingStatus(worn: p[4] != 0, timestamp: YCBTBytes.date(YCBTBytes.u32(p, 0)))]

        default:
            return [.commandAck(commandId: frame.cmd)]
        }
    }

    // MARK: - Command channel (be940001, group 0x02)

    private func decodeGetReply(_ frame: YCBTFrame) -> [RingDecodedEvent] {
        switch frame.cmd {
        case YCBTCommand.getDeviceInfo:
            return decodeDeviceInfo(frame.payload)
        case YCBTCommand.getSupportFunction:
            return decodeSupportFunction(frame.payload)
        case YCBTCommand.getChipScheme:
            return decodeChipScheme(frame.payload)
        default:
            return [.commandAck(commandId: frame.cmd)]
        }
    }

    /// `02 00` GetDeviceInfo reply (`DataUnpack.unpackDeviceInfoData`): deviceId u16 @0, firmware
    /// sub-version @2 and main-version @3 (displayed "main.sub"), battery **state** @4 and battery
    /// **percent** @5. Battery is in-band on this reply — the ring exposes no standard battery service.
    ///
    /// The sub-version is **zero-padded to two digits** (`i4 < 10 ? i5 + ".0" + i4 : i5 + "." + i4`), so
    /// main 1 / sub 5 is the "1.05" the vendor's release notes name — not "1.5", which the user would
    /// read as a different firmware than the one they are on.
    private func decodeDeviceInfo(_ p: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = [.status(address: nil)]
        if p.count >= 4 { events.append(.firmware(version: String(format: "%d.%02d", p[3], p[2]))) }
        if p.count >= 6 { events.append(.battery(percent: Int(p[5]))) }
        return events
    }

    /// `02 01` GetSupportFunction reply — the firmware's own capability bitmap, and the only thing that
    /// can tell two SKUs of one ring family apart at runtime. `RingBLEClient` folds it into the active
    /// capability set; the log line stays because the raw byte count is the first thing to check when a
    /// ring under-reports (an old firmware just sends a shorter array).
    private func decodeSupportFunction(_ p: [UInt8]) -> [RingDecodedEvent] {
        let caps = YCBTSupportFunction.capabilities(from: p)
        ycbtLog.info("SupportFunction bitmap (\(p.count, privacy: .public) B) → \(caps.csv, privacy: .public)")
        return [.supportFunctions(caps)]
    }

    /// `02 1b` GetChipScheme reply — the chipset/OTA family. Nothing branches on it (PulseLoop does no
    /// firmware updates); it is decoded so the debug feed shows *which* OTA family a ring belongs to and
    /// whether JieLi RCSP — the AE00 auth we deliberately don't implement — is in play at all.
    private func decodeChipScheme(_ p: [UInt8]) -> [RingDecodedEvent] {
        let scheme = YCBTChipScheme.value(from: p)
        ycbtLog.info("chipScheme \(scheme, privacy: .public) (JieLi: \(YCBTChipScheme.isJieLi(scheme), privacy: .public))")
        return [.chipScheme(value: scheme)]
    }

    /// `06 03` — the SDK's `Real_UploadBlood` frame (`DataUnpack.unpackRealBloodData`), and the live feed
    /// for **both** the BP and the HRV spot measurements (SmartHealth's BP screen and HRV screen each
    /// subscribe to this one dataType, reading `bloodSBP`/`bloodDBP` and `hrv` respectively):
    ///
    ///   `[SBP@0][DBP@1][hr@2]` then, if the payload is long enough, `[hrv@3][spo2@4][tempInt@5][tempFrac@6]`
    ///
    /// There are **not** two frame shapes here to disambiguate: the offsets are fixed, and the mode just
    /// decides which of them the ring fills (BP mode fills @0/@1 and zeroes @3; HRV mode the reverse).
    /// So each field is emitted iff it carries a value — which also recovers the HR that the BP sweep
    /// measures, and which a shape heuristic would throw away.
    ///
    /// Temperature is `int` and `frac` **string-concatenated**, not `int + frac/100` as the realtime
    /// report claimed: SmartHealth's temperature screen does `Double.parseDouble(int + "." + frac)` on
    /// the same field pair (see `YCBTHealthRecords.composite`). Ranges belong to `RingEventBridge`, except
    /// SpO₂ — the one metric it doesn't gate — so a warm-up 0 is dropped here.
    private func decodeLiveVitals(_ p: [UInt8], cmd: UInt8, now: Date) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        if p.count >= 2, p[0] > 0, p[1] > 0 {
            events.append(.bloodPressureSample(systolic: Int(p[0]), diastolic: Int(p[1]), timestamp: now))
        }
        if p.count >= 3, p[2] > 0 {
            events.append(.heartRateSample(bpm: Int(p[2]), timestamp: now))
        }
        if p.count >= 4, p[3] > 0 {
            events.append(.hrvSample(value: Int(p[3]), timestamp: now))
        }
        if p.count >= 5, RingEventBridge.spo2Range.contains(Int(p[4])) {
            events.append(.spo2Result(value: Int(p[4]), timestamp: now))
        }
        if p.count >= 7, p[5] > 0 {
            events.append(.temperatureSample(celsius: YCBTHealthRecords.composite(p[5], p[6]), timestamp: now))
        }
        return events.isEmpty ? [.commandAck(commandId: cmd)] : events
    }

    /// The ring's DevControl pushes. Only the measurement ones carry data PulseLoop has a home for.
    ///
    /// Everything else in the catalog — find-phone (`0x00`), SOS (`0x05` / `0x17`), sedentary reminder
    /// (`0x16`), the camera / music / call remotes — has **no product surface in PulseLoop**: it is not a
    /// phone-notification mirror and has no SOS flow. Those frames are ACKed (in the driver, so the ring
    /// stops retransmitting) and surfaced as a plain `.commandAck`, which still puts them in the debug
    /// packet feed. Giving any of them a behaviour is a product decision, not a protocol one.
    private func decodeDevControlPush(_ cmd: UInt8, payload: [UInt8], now: Date) -> [RingDecodedEvent] {
        switch cmd {
        case YCBTDevControl.measurementStatus:
            let events = measurementStatusEvents(payload, now: now)
            return events.isEmpty ? [.commandAck(commandId: cmd)] : events

        case YCBTDevControl.measurementResult:
            // `04 0e` (`unpackParseData` 1038): `[measureType][result]`, **no value**. SmartHealth reacts
            // to a success by re-reading history — which is where the reading actually lands, and which
            // PulseLoop's periodic re-sync already does. Log it: it is the only signal that says *why* a
            // spot measurement produced nothing (2 = failed, else cancelled).
            if payload.count >= 2 {
                ycbtLog.info("MeasurementResult: mode \(payload[0], privacy: .public) → \(payload[1], privacy: .public)")
            }
            return [.commandAck(commandId: cmd)]

        default:
            return [.commandAck(commandId: cmd)]
        }
    }

    /// `04 13` MeasurStatusAndResults (dataType 1043) — the ring's live "measurement in progress / done"
    /// push, the counterpart of the `03 2f` start we sent: `[type@0][state@1]` then that type's value(s).
    /// `type` is the same mode byte we started with (`YCBTMeasurementMode`). `state` is a progress/abort
    /// code that the SDK forwards without ever naming — so we don't invent an enum for it either; a frame
    /// with no usable value simply acks.
    ///
    /// The SDK gates the whole parse on `payload.count >= 24` (the ring pads the frame). We gate per type
    /// on the bytes it actually reads instead: the offsets are identical either way, and a shorter frame
    /// from a different firmware would otherwise silently drop a real reading.
    private func measurementStatusEvents(_ p: [UInt8], now: Date) -> [RingDecodedEvent] {
        guard p.count >= 3 else { return [] }
        let value = p[2]
        let fraction = p.count >= 4 ? p[3] : 0

        switch p[0] {
        case YCBTMeasurementMode.heartRate:
            return value > 0 ? [.heartRateSample(bpm: Int(value), timestamp: now)] : []

        case YCBTMeasurementMode.bloodPressure:
            guard value > 0, fraction > 0 else { return [] }
            return [.bloodPressureSample(systolic: Int(value), diastolic: Int(fraction), timestamp: now)]

        case YCBTMeasurementMode.spo2:
            guard RingEventBridge.spo2Range.contains(Int(value)) else { return [] }
            return [.spo2Result(value: Int(value), timestamp: now)]

        case YCBTMeasurementMode.temperature:
            guard value > 0 else { return [] }
            return [.temperatureSample(celsius: YCBTHealthRecords.composite(value, fraction), timestamp: now)]

        case YCBTMeasurementMode.bloodSugar:
            // Tenths of mmol/L, as everywhere else in this SDK (`int * 10 + frac`) — see
            // `YCBTHealthRecords.bloodSugarMgdl`. UNVERIFIED scale, gated by the bridge's mg/dL range.
            let tenths = Int(value) * 10 + Int(fraction)
            guard tenths > 0 else { return [] }
            return [.bloodSugarSample(mgdl: YCBTHealthRecords.bloodSugarMgdl(tenthsOfMmol: tenths), timestamp: now)]

        default:
            // Respiratory rate (3), uric acid (6), ketone (7), blood fat (9): no live `RingDecodedEvent`
            // exists for any of them, and PulseLoop can't start those measurements in the first place —
            // only a ring-initiated one could land here. Respiratory rate does reach SwiftData, but via the
            // history record, so nothing is lost by not fabricating a live event stamped `now`.
            return []
        }
    }
}
