import Foundation
@preconcurrency import CoreBluetooth

/// Reassembles CRP command replies (`fdd3`) that span multiple BLE notifications. A logical frame
/// starts with `FD DA …` and its declared total length (`CRPProtocol.frameLength`) tells us when it
/// is complete. Mirrors the vendor's `g1/a.k()`.
///
/// **Must be reset when a link comes up.** Auto-reconnect re-uses the same `CRPDriver` instance —
/// `RingBLEClient.didDisconnectPeripheral` re-dials with a bare `central.connect`, and only
/// `beginConnect`/`adoptRememberedIdentity` ever call `installDriver` — so a frame left half-assembled
/// when the old link dropped would be completed with bytes from the new one and decoded as genuine.
/// The group-2 history frames are long and multi-notification, so the spliced result would be a
/// fabricated vital sample or sleep record, not an obvious parse failure. `CRPDriver.connectionDidStart`
/// calls `reset()`, matching `LuckRingDriver`/`YCBTDriver`.
final class CRPFrameAssembler {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private var buffer: [UInt8] = []
    private var expected = 0

    /// Drop any partially-assembled frame. See the type doc — this is not optional bookkeeping.
    func reset() {
        buffer = []
        expected = 0
    }

    /// Feed one notification chunk. Returns the complete frame when the last chunk lands, else nil.
    func append(_ chunk: Data) -> Data? {
        if chunk.isEmpty { return nil }
        if CRPProtocol.isFrameStart(chunk) {
            expected = CRPProtocol.frameLength(chunk)
            buffer = []
        }
        // A continuation chunk with no in-progress frame is noise — drop it.
        if expected <= 0 { return nil }
        buffer.append(contentsOf: chunk)
        if buffer.count >= expected {
            let frame = buffer.count == expected ? buffer : Array(buffer.prefix(expected))
            buffer = []
            expected = 0
            return Data(frame)
        }
        return nil
    }
}

/// Decodes CRP notifications into `RingDecodedEvent`s. Routing is by source characteristic (the
/// `from` UUID `CRPDriver.ingest` passes through), matching the vendor's `g1/a.a(characteristic)`
/// dispatch:
///   - `fdd1` → raw current-steps triples (no CRP header)
///   - `fdd3` → framed `FD DA …` command replies (already reassembled by `CRPFrameAssembler`)
///
/// NOTE: This ring does NOT use the standard `2a37` HR characteristic — all vital results come
/// back as framed replies on `fdd3` with group/cmd routing. The `2a37` path is dead code for CRP
/// rings (removed during port).
///
/// Group-1 replies (`g1/a.java` lines 664–712) carry real-time vital results:
///   cmd 9  → HR (payload[0] = bpm, per `e1/f.b()`)
///   cmd 10 → HRV (payload[0] = ms)
///   cmd 11 → SpO2 (payload[0] = percent)
///   cmd 14 → stress (payload[0] = 0..100)
///   cmd 32 → temperature (payload[0..] = raw)
///   Other cmd values → command acknowledgment.
enum CRPDecoder {

    /// `calendar` resolves the ring's day-relative history (`day 0` = today) against the device's
    /// **local** midnight, which is what the ring stamps against. Injectable so tests can pin a zone.
    static func decode(_ data: Data, from characteristic: CBUUID, now: Date = Date(),
                       calendar: Calendar = .current) -> [RingDecodedEvent] {
        switch characteristic {
        case CRPUUIDs.stepsNotifyCBUUID:
            return decodeCurrentSteps(data, now: now)
        default:
            return CRPProtocol.isFrameStart(data) ? decodeFramedReply(data, now: now, calendar: calendar) : []
        }
    }

    /// All-day timeline frames carry sample slots at a fixed 5-minute cadence (`w0.b.a() / 5` in the
    /// vendor). Two slot widths: HR/SpO2/stress store one byte per slot (144 slots/frame, terminal
    /// frame index 1); HRV stores a little-endian 2-byte value per slot (72 slots/frame, terminal
    /// index 3). Both reassemble to a 288-slot (24 h) day across their frames.
    private static let timingSlotMinutes = 5
    private static let timingSlotsPerFrame1Byte = 144
    private static let timingSlotsPerFrame2Byte = 72
    /// `CRPHistoryDay` tops out at 14 days ago; a wilder value is a corrupt reply, not a real day.
    private static let maxHistoryDay = 14
    private static let maxSleepMinutes = 24 * 60

    /// `fdd1` push — little-endian 3-byte triples: [steps][distance][calories]. From `e1/k.b`.
    /// distance is metres, calories kcal (vendor units).
    private static func decodeCurrentSteps(_ data: Data, now: Date) -> [RingDecodedEvent] {
        let b = [UInt8](data)
        if b.isEmpty || b.count % 3 != 0 { return [] }
        let steps = le3(b, 0)
        let distance = b.count >= 6 ? le3(b, 3) : 0
        let calories = b.count >= 9 ? le3(b, 6) : 0
        return [.activityUpdate(timestamp: now, steps: steps,
                                distanceMeters: Double(distance), calories: Double(calories))]
    }

    /// Framed `fdd3` reply: `FD DA 10 <len> <group> <cmd> <payload>`.
    /// Real-time vital results come on group 1; sleep/all-day history and the capability read-backs on
    /// group 2; device identity and state pushes on group 3. Group 7 is the vendor's Gomore module,
    /// not device info.
    private static func decodeFramedReply(_ frame: Data, now: Date, calendar: Calendar) -> [RingDecodedEvent] {
        let b = [UInt8](frame)
        if b.count < CRPProtocol.headerSize { return [] }
        let group = Int(b[4])
        let cmd = Int(b[5])
        let payload = b.count > CRPProtocol.headerSize ? Array(b[CRPProtocol.headerSize..<b.count]) : []
        func ack() -> [RingDecodedEvent] {
            [.commandAck(commandId: UInt8(truncatingIfNeeded: (group << 4) | (cmd & 0x0F)))]
        }

        // Group 1: real-time vital results (decompiled `g1/a.java` lines 664–712).
        if group == CRPCommands.groupDevice {
            return decodeVitalResult(cmd: cmd, payload: payload, now: now)
        }

        // Group 7: the vendor's Gomore module (`b1/r`). Nothing we send lands here any more; kept so
        // an unsolicited Gomore frame in a capture is still recorded rather than dropped.
        if group == CRPCommands.groupGomore {
            return ack()
        }

        // Group 2: sleep + the all-day "timing" vital timelines + temperature history + read-backs.
        //   cmd 14          → sleep (`e1/j`), confirmed against a hardware capture.
        //   cmd 15/16/17/47 → HR/HRV/SpO2/stress all-day timeline (`e1/{f,g,d,l}`), confirmed
        //                     against zaggash's R11 capture (Android issue #29).
        //   cmd 37          → the ring's own SpO2-hardware answer.
        //   cmd 22          → temperature history, still an ack until a non-empty capture pins it.
        if group == CRPCommands.groupHistory {
            if cmd == CRPCommands.cmdQueryHistorySleep {
                return decodeSleep(payload, now: now, calendar: calendar)
            }
            if cmd == CRPCommands.cmdQuerySupportSpO2Type {
                return decodeSpO2Support(payload)
            }
            if let timing = decodeTimingHistory(cmd: cmd, payload: payload, now: now, calendar: calendar) {
                return timing
            }
            return ack()
        }

        // Group 3: device control, the firmware-version string (cmd 3), and the autonomous wear-state
        // push (`g1/a.java` case 3→7, `onWearStateChange(payload[0] > 0)`). Confirmed against
        // zaggash's R11: a spot measure returns nothing while `payload[0] == 0` (ring off the finger).
        if group == CRPCommands.groupPower {
            if cmd == CRPCommands.cmdWearState, let first = payload.first {
                return [.wearingStatus(worn: first != 0, timestamp: now)]
            }
            if cmd == CRPCommands.cmdQueryFirmwareVersion,
               let firmware = decodeFirmwareVersion(payload) {
                // nil ⇒ nothing readable in the payload; fall through to the ack below.
                return firmware
            }
            return ack()
        }

        // Unknown group/cmd — ack.
        return ack()
    }

    /// Decode group-1 vital result replies. Confirmed against `g1/a.java` and `e1/f.java` (HR),
    /// `e1/g.java` (HRV), `e1/d.java` (SpO2), `e1/h.java` (stress/physical strength), and the
    /// vendor's `onMeasureComplete` flow for temperature (cmd 32).
    ///
    /// Layout: `payload[0]` is the metric value for all types. Plausibility guards prevent
    /// garbage samples (HR 40–200, SpO2 70–100, stress 0–100, HRV 20–200).
    private static func decodeVitalResult(cmd: Int, payload: [UInt8], now: Date) -> [RingDecodedEvent] {
        guard !payload.isEmpty else {
            return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDevice << 4) | (cmd & 0x0F)))]
        }
        let value = Int(payload[0])

        switch cmd {
        case CRPCommands.cmdResultHR:
            // HR from `e1/f.b()`: byte2int(payload[0]).
            guard value >= 40 && value <= 200 else { return [] }
            return [.heartRateSample(bpm: value, timestamp: now)]

        case CRPCommands.cmdResultHRV:
            // HRV: the vendor's live `onHrv()` receives byte2int(payload[0]).
            guard value >= 20 && value <= 200 else { return [] }
            return [.hrvSample(value: value, timestamp: now)]

        case CRPCommands.cmdResultSpO2:
            // SpO2 from `e1/d.b()`: byte2int(payload[0]).
            guard value >= 70 && value <= 100 else { return [] }
            return [.spo2Result(value: value, timestamp: now)]

        case CRPCommands.cmdResultStress:
            // Stress/physical strength: byte2int(payload[0]).
            guard value >= 0 && value <= 100 else { return [] }
            return [.stressSample(value: value, timestamp: now)]

        case CRPCommands.cmdResultTemp:
            // Vendor `e1/m.a(payload[1], payload[0])`: twoBytes2int / 10, valid 28.0…50.0 °C.
            guard payload.count >= 2 else { return [] }
            let celsius = Double((Int(payload[1]) << 8) | Int(payload[0])) / 10.0
            guard celsius >= 28.0 && celsius <= 50.0 else { return [] }
            return [.temperatureSample(celsius: celsius, timestamp: now)]

        default:
            // Acknowledgment for enable/disable commands.
            return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDevice << 4) | (cmd & 0x0F)))]
        }
    }

    /// Decode a CRP all-day "timing" vital-history reply (group 2). Returns `nil` for a non-timing
    /// group-2 cmd (e.g. temp cmd 22) so the caller falls back to an ack. Layout, confirmed against
    /// zaggash's R11 capture and the vendor parsers `e1/{f,g,d,l}.java`:
    ///   `[day][frameIndex][slot samples…]` — one 5-minute slot per sample, `0` = no reading.
    /// HR/SpO2/stress use one byte per slot; HRV a little-endian 2-byte value. Each slot's absolute
    /// time is the corresponding local wall-clock minute on `today − day`, matching the vendor's
    /// `w0.b.a()/5` slot indexing. Nonexistent spring-forward slots are skipped and repeated fall-back
    /// slots select their first occurrence. Emits one `.historyMeasurement` per valid slot plus a
    /// trailing `.timingHistoryFrame` that drives the engine's next-frame follow-up.
    private static func decodeTimingHistory(cmd: Int, payload: [UInt8], now: Date,
                                            calendar: Calendar) -> [RingDecodedEvent]? {
        // (kind, sample byte-width, validity predicate) per vital. Ranges mirror the vendor clamps:
        // HR 40…200 (`e1/f.e`), SpO2 1…100 (`e1/d.e`, >100→0), HRV any positive (`e1/g.d`, no clamp),
        // stress 1…100 (`e1/l.d`, no clamp; 0 treated as no-reading). Zero is always "no sample".
        let kind: MeasurementKind
        let twoByte: Bool
        let valid: (Int) -> Bool
        switch cmd {
        case CRPCommands.cmdQueryTimingHR:
            kind = .heartRate; twoByte = false; valid = { $0 >= 40 && $0 <= 200 }
        case CRPCommands.cmdQueryTimingSpO2:
            kind = .spo2; twoByte = false; valid = { $0 >= 1 && $0 <= 100 }
        case CRPCommands.cmdQueryTimingHRV:
            kind = .hrv; twoByte = true; valid = { $0 >= 1 && $0 <= 300 }
        case CRPCommands.cmdQueryTimingStress:
            kind = .stress; twoByte = false; valid = { $0 >= 1 && $0 <= 100 }
        default:
            return nil
        }
        // [day][frameIndex] header; anything shorter is malformed.
        if payload.count < 2 { return [] }
        let day = Int(payload[0])
        let frameIndex = Int(payload[1])
        let slotsPerFrame = twoByte ? timingSlotsPerFrame2Byte : timingSlotsPerFrame1Byte
        let step = twoByte ? 2 : 1
        let terminalFrameIndex = twoByte ? 3 : 1
        let sampleByteCount = payload.count - 2
        // Cursors and frame widths are fixed by the vendor parsers. Reject the whole reply rather than
        // letting extra bytes spill into another frame's timestamps or a bad cursor end the sync early.
        if day > maxHistoryDay || frameIndex > terminalFrameIndex
            || sampleByteCount > slotsPerFrame * step || sampleByteCount % step != 0 {
            return timingHistoryMalformedAck(cmd: cmd)
        }
        guard let midnight = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) else {
            return []
        }

        var events: [RingDecodedEvent] = []
        var slot = 0
        var i = 2
        while i + step - 1 < payload.count {
            let value = twoByte ? (Int(payload[i]) | (Int(payload[i + 1]) << 8)) : Int(payload[i])
            if valid(value) {
                let globalSlot = frameIndex * slotsPerFrame + slot
                if let ts = timingSlotDate(globalSlot: globalSlot, midnight: midnight, calendar: calendar) {
                    events.append(.historyMeasurement(kind: kind, value: Double(value), timestamp: ts))
                }
            }
            i += step
            slot += 1
        }
        // Drive the vendor's sequential next-frame pull (see `.timingHistoryFrame`).
        events.append(.timingHistoryFrame(cmd: cmd, day: day, frameIndex: frameIndex))
        return events
    }

    private static func timingHistoryMalformedAck(cmd: Int) -> [RingDecodedEvent] {
        [.commandAck(commandId: UInt8(truncatingIfNeeded:
            (CRPCommands.groupHistory << 4) | (cmd & 0x0F)))]
    }

    /// Resolve the ring's minute-of-day slot without treating a DST change as elapsed-time arithmetic.
    /// `.strict` keeps a nonexistent spring-forward wall time nil; `.first` makes fall-back deterministic.
    private static func timingSlotDate(globalSlot: Int, midnight: Date, calendar: Calendar) -> Date? {
        let minuteOfDay = globalSlot * timingSlotMinutes
        guard minuteOfDay >= 0 && minuteOfDay < 24 * 60 else { return nil }
        var components = calendar.dateComponents([.era, .year, .month, .day], from: midnight)
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        components.second = 0
        return calendar.nextDate(
            after: midnight.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    /// The firmware version string (`group 3 / cmd 3`). Vendor `g1/a.i1`:
    /// `onVersion(new String(payload, StandardCharsets.UTF_8))` — a bare UTF-8 string with no length
    /// prefix or terminator, e.g. `MOY-R1K3-2.1.6` on zaggash's R11 (Android issue #29).
    ///
    /// Returns `nil` when the payload holds nothing readable, so the caller acks it instead.
    /// Surfaced as `.firmware(version:)`, which the event bridge maps to `.firmwareVersion` — a
    /// device-info event, *not* a connection-state one. That distinction matters: the query rides
    /// `CRPSyncEngine`'s connect handshake, and a reply that bridged to "connected" would restamp the
    /// device row as freshly connected.
    ///
    /// Validated rather than coerced, because whatever comes back is shown verbatim in Settings.
    /// `String(decoding:as:)` cannot fail — it substitutes U+FFFD for invalid bytes — so a binary
    /// payload would render as a row of replacement characters *presented as a firmware version*.
    /// `String(bytes:encoding:)` returns nil instead, and the control-character check rejects the
    /// binary payloads that happen to be valid UTF-8. A real version (`MOY-R1K3-2.1.6`) passes both.
    private static func decodeFirmwareVersion(_ payload: [UInt8]) -> [RingDecodedEvent]? {
        guard let raw = String(bytes: payload, encoding: .utf8) else { return nil }
        // Trim only what firmwares actually pad with — NUL and whitespace. Deliberately narrower than
        // the vendor's `trim { it <= ' ' }`: trimming *all* control bytes first would strip a binary
        // payload's leading junk and let whatever printable byte followed through as a "version"
        // (`01 02 03 41` → "A"). Padding comes off, then anything still holding a control byte is
        // rejected outright rather than salvaged.
        let trimmed = raw.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        )
        if trimmed.isEmpty { return nil }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }
        return [.firmware(version: trimmed)]
    }

    /// The ring's own answer to "do you have SpO2 hardware?" (`group 2 / cmd 37`). Vendor `g1/a.V0`
    /// hands `payload[0]` to `CRPBloodOxygenType`, which defines exactly three values:
    /// **0 = NOT_SUPPORT, 1 = SLEEP_OXYGEN, 2 = TIMING_OXYGEN** — `getInstance` returns nil for
    /// anything else, so only 1 and 2 count as a claim of support.
    ///
    /// Treating "any non-zero" as support would be a real hazard on this ring: it uses `0xFF` as a
    /// no-reading sentinel elsewhere (every failed spot SpO2 answers `group 1 / cmd 11 [FF]`), and a
    /// `0xFF` here would otherwise read as a capability claim.
    ///
    /// **This is currently diagnostic, not capability-driving.** SpO2 is in `CRPCoordinator`'s
    /// unconditional capabilities because it is hardware-confirmed: zaggash's 2026-07-23 capture has a
    /// real reading (`group 1 / cmd 11` payload `0x61` = 97 %). `WearableCoordinator.refinedCapabilities`
    /// is additive-only (`capabilities.union(bitmapGated ∩ derived)`), so a NOT_SUPPORT answer cannot
    /// take SpO2 away — decoding it simply puts the ring's own answer in the raw-packet feed, where the
    /// next capture can confirm or challenge what we assume. Acting on a NOT_SUPPORT would need a
    /// subtractive mechanism that does not exist yet, and should not be invented without a ring that
    /// actually reports one.
    private static func decodeSpO2Support(_ payload: [UInt8]) -> [RingDecodedEvent] {
        guard let type = payload.first else {
            return [.commandAck(commandId: UInt8(truncatingIfNeeded:
                (CRPCommands.groupHistory << 4) | (CRPCommands.cmdQuerySupportSpO2Type & 0x0F)))]
        }
        // Only the two documented "supported" values; 0 = NOT_SUPPORT and anything else is unknown.
        // Report an empty set rather than nothing, so the feed records that the ring was asked.
        let granted: Set<WearableCapability> = (type == 1 || type == 2) ? [.spo2, .manualSpo2] : []
        return [.supportFunctions(granted)]
    }

    private struct SleepTransition {
        let elapsed: Int
        let state: Int
    }

    /// Decode a sleep-history reply (`group 2 / cmd 14`), a faithful port of the vendor parser
    /// `e1/j.b` (Moyoung "Da Rings"). Layout: `[dayIndex]` then repeating 3-byte records
    /// `[state, hour, minute]`, where a record marks the moment sleep entered `state` and that state
    /// runs until the NEXT record's timestamp (state 0=awake, 1=light, 2=deep, 3=rem). The vendor
    /// requires `length % 3 == 1` (one day byte + N whole records); anything else is malformed.
    ///
    /// Confirmed against a hardware capture (Android issue #29): a `dayIndex 0` reply of 26 records
    /// decoded to a clean 01:07→08:05 night (245 light / 110 deep / 63 REM minutes).
    ///
    /// Emitted as `.sleepTimeline`s whose `stages` lists are one entry per minute, matching
    /// `ColmiDecoder`'s sleep shape. A day's reply can hold more than one bout (a night plus a nap),
    /// so we split at any awake run of `SleepSegmentation.sessionGapMinutes`+ — the same gap the
    /// persistence layer uses to separate sessions. Short mid-night wakes stay inside their bout.
    ///
    /// Two deliberate departures from the vendor:
    ///  - The vendor extends the final record's state to the current wall-clock when it isn't awake
    ///    (an in-progress sleep). We don't — a completed night always ends on an awake record, so the
    ///    only case affected is a sync taken mid-sleep, where showing the night up to the last real
    ///    transition beats inventing minutes up to "now".
    ///  - Session-start anchoring is ours (the vendor keeps minute-of-day only and lets the UI place
    ///    the date from `dayIndex`). We anchor the FIRST record on the wake day (`today − dayIndex`)
    ///    from the actual midnight rollover in the transition sequence, then place later bouts by
    ///    elapsed offset. Looking only at the final record fails when an overnight bout is followed by
    ///    another late-evening bout whose clock time is later than the first record.
    ///    NOTE: assumes `dayIndex` is the WAKE day; verified against a post-midnight capture, but an
    ///    evening-start night is not yet capture-confirmed.
    private static func decodeSleep(_ payload: [UInt8], now: Date, calendar: Calendar) -> [RingDecodedEvent] {
        // [dayIndex] + N*[state,hour,minute]; the vendor rejects any other shape outright.
        if payload.count < 4 || payload.count % 3 != 1 { return [] }
        let dayIndex = Int(payload[0])
        if dayIndex > maxHistoryDay { return [] }
        let recordCount = (payload.count - 1) / 3

        // Pass 1: fold records into monotonic transition points — an elapsed-minute offset from the
        // first valid record plus the state beginning there. Corrupt records are skipped without
        // advancing the cursor, matching the vendor's `iA >= 0` guard.
        var transitions: [SleepTransition] = []
        var firstMinuteOfDay = -1
        var crossedMidnight = false
        var elapsed = 0
        var prevHour = 0
        var prevMinute = 0
        for k in 0..<recordCount {
            let off = 1 + k * 3
            let state = Int(payload[off])
            let hour = Int(payload[off + 1])
            let minute = Int(payload[off + 2])
            if hour > 23 || minute > 59 { continue }
            if transitions.isEmpty {
                firstMinuteOfDay = hour * 60 + minute
                transitions.append(SleepTransition(elapsed: 0, state: state))
            } else {
                let duration = sleepSegmentMinutes(prevHour: prevHour, prevMinute: prevMinute,
                                                   hour: hour, minute: minute)
                if duration < 0 || duration > maxSleepMinutes { continue }
                if hour < prevHour { crossedMidnight = true }
                elapsed += duration
                transitions.append(SleepTransition(elapsed: elapsed, state: state))
            }
            prevHour = hour
            prevMinute = minute
        }
        if transitions.count < 2 { return [] }

        // Anchor the first record; every bout is then just an offset from it.
        let startOffset = firstMinuteOfDay - (crossedMidnight ? 1440 : 0)
        guard let wakeDayStart = calendar.date(byAdding: .day, value: -dayIndex,
                                               to: calendar.startOfDay(for: now)) else { return [] }
        let anchor = wakeDayStart.addingTimeInterval(Double(startOffset) * 60)

        // Pass 2: each transition's state runs until the next; split bouts on a long awake gap.
        var events: [RingDecodedEvent] = []
        var boutStages: [SleepStage] = []
        var boutStartElapsed = 0
        for i in 0..<(transitions.count - 1) {
            let segment = transitions[i]
            let duration = transitions[i + 1].elapsed - segment.elapsed
            if duration <= 0 { continue }
            let stage = mapSleepState(segment.state)
            if stage == .awake && duration >= SleepSegmentation.sessionGapMinutes {
                emitSleepBout(into: &events, anchor: anchor, startElapsed: boutStartElapsed, stages: boutStages)
                boutStages = []
                continue
            }
            if boutStages.isEmpty { boutStartElapsed = segment.elapsed }
            boutStages.append(contentsOf: repeatElement(stage, count: duration))
        }
        emitSleepBout(into: &events, anchor: anchor, startElapsed: boutStartElapsed, stages: boutStages)
        return events
    }

    /// Emit a bout as a `.sleepTimeline`, unless it holds no actual sleep (awake-only).
    private static func emitSleepBout(into events: inout [RingDecodedEvent], anchor: Date,
                                      startElapsed: Int, stages: [SleepStage]) {
        if !stages.contains(where: { $0 != .awake }) { return }
        events.append(.sleepTimeline(timestamp: anchor.addingTimeInterval(Double(startElapsed) * 60),
                                     stages: stages))
    }

    /// Minutes from a previous `hh:mm` to this one, wrapping across midnight (vendor `e1/j.a`).
    private static func sleepSegmentMinutes(prevHour: Int, prevMinute: Int, hour: Int, minute: Int) -> Int {
        let wrappedHour = prevHour > hour ? hour + 24 : hour
        return ((wrappedHour - prevHour) * 60 + minute) - prevMinute
    }

    /// Vendor `e1/j.c` state codes → shared `SleepStage`.
    private static func mapSleepState(_ state: Int) -> SleepStage {
        switch state {
        case 0: return .awake
        case 1: return .light
        case 2: return .deep
        case 3: return .rem
        default: return .unknown
        }
    }

    /// Little-endian unsigned 3-byte int at `offset`.
    private static func le3(_ b: [UInt8], _ offset: Int) -> Int {
        Int(b[offset]) | (Int(b[offset + 1]) << 8) | (Int(b[offset + 2]) << 16)
    }
}
