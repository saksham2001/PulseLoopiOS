import Foundation
import os.log

#if DEBUG
private let realtimeHRLog = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "ColmiRealtimeHR")
#endif

/// Decodes Colmi frames into the shared `RingDecodedEvent`. Two channels:
///  - **Normal (V1)**: realtime HR, manual HR, battery, notifications, and paged history
///    (HR / activity / stress / HRV).
///  - **Big-data (V2)**: reassembled `0xbc` frames for sleep / SpO2 / temperature.
///
/// The decoder is stateless: paging/day bookkeeping that drives the history state machine lives in
/// `ColmiSyncEngine`, which inspects the same raw frames. Layouts per `docs/ColmiR02-Protocol.md`;
/// `// UNVERIFIED` marks anything not checkable without a physical ring.
struct ColmiDecoder {

    /// Decode a normal-channel (V1) frame.
    func decodeNormal(_ data: Data, now: Date = Date(), calendar: Calendar = .current) -> [RingDecodedEvent] {
        guard let packet = ColmiPacket(validating: data) else {
            // Bad checksum / wrong length — surface as unknown for the debug trace, drop downstream.
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }
        let v = packet.bytes

        switch v[0] {
        case ColmiCommandID.battery:
            return [.battery(percent: Int(v[1]))]

        case ColmiCommandID.manualHeartRate:
            // 69 <?> <errorCode> <bpm>. errorCode: 0=ok, else worn-incorrectly/temporary.
            // The manual measurement is a *continuous stream* that warms up emitting bpm 0 for ~25s
            // before real readings — so a 0 with no error is warm-up, NOT a terminal "no reading".
            let errorCode = v[2]
            let bpm = Int(v[3])
            if errorCode != 0 {
                return [.heartRateComplete(timestamp: now)]   // genuine no-reading / worn incorrectly
            }
            guard (30...220).contains(bpm) else {
                return []   // warm-up (bpm 0) or noise — keep streaming, don't signal completion
            }
            return [.heartRateSample(bpm: bpm, timestamp: now)]

        case ColmiCommandID.realtimeHeartRate:
            // Realtime reply layout is UNVERIFIED on hardware, so accept both plausible shapes:
            //  - documented (GadgetBridge/colmi): 1e <errCode> <bpm>  — like manual 0x69, flag first
            //  - legacy (what this decoder originally assumed): 1e <bpm>
            // A zero error code with bpm 0 is warm-up; a nonzero code (incl. the 0xee=238 sentinel)
            // with no plausible bpm anywhere is a genuine no-reading.
            if v[1] == 0, (30...220).contains(Int(v[2])) {
                logRealtimeHR(v, branch: "errCode+bpm v[2]=\(v[2])")
                return [.heartRateSample(bpm: Int(v[2]), timestamp: now)]
            }
            if (30...220).contains(Int(v[1])) {
                logRealtimeHR(v, branch: "legacy v[1]=\(v[1])")
                return [.heartRateSample(bpm: Int(v[1]), timestamp: now)]
            }
            if v[1] != 0 {
                logRealtimeHR(v, branch: "error code v[1]=\(v[1])")
                return [.heartRateComplete(timestamp: now)]
            }
            logRealtimeHR(v, branch: "warm-up")
            return []

        case ColmiCommandID.realtimeHeartRateError:
            // Ring not worn / no reading available — surface completion, no sample.
            return [.heartRateComplete(timestamp: now)]

        case ColmiCommandID.notification:
            return decodeNotification(v, now: now)

        default:
            return [.commandAck(commandId: v[0])]
        }
    }

    /// DEBUG-only trace for realtime-HR (`0x1e`) frames: dumps the full frame and which parse
    /// branch fired, so a field test can pin the ring's actual (undocumented) reply layout.
    private func logRealtimeHR(_ v: [UInt8], branch: String) {
        #if DEBUG
        let hex = v.map { String(format: "%02x", $0) }.joined(separator: " ")
        realtimeHRLog.debug("0x1e frame [\(hex, privacy: .public)] → \(branch, privacy: .public)")
        #endif
    }

    /// Day-aware history decode, called by `ColmiSyncEngine` which tracks the current sync-day.
    /// HR/stress/HRV use the passed `day`; activity carries its own date in the frame.
    func decodeHistory(_ data: Data, day: Date, calendar: Calendar = .current, now: Date = Date()) -> [RingDecodedEvent] {
        guard let packet = ColmiPacket(validating: data) else { return [] }
        let v = packet.bytes
        switch v[0] {
        case ColmiCommandID.syncHeartRate:
            return decodeHRHistory(v, day: day, calendar: calendar)
        case ColmiCommandID.syncStress:
            return decodeStressHistory(v, day: day, calendar: calendar)
        case ColmiCommandID.syncHRV:
            return decodeHRVHistory(v, day: day, calendar: calendar)
        case ColmiCommandID.syncActivity:
            return decodeActivityHistory(v, calendar: calendar, now: now)
        default:
            return []
        }
    }

    /// The page number of a paged history frame (HR/stress/HRV): byte[1]. 0 = header, 0xff = empty.
    static func historyPacketNumber(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        return Int([UInt8](data)[1])
    }

    private func decodeNotification(_ v: [UInt8], now: Date) -> [RingDecodedEvent] {
        switch v[1] {
        case ColmiCommandID.notifBattery:
            return [.battery(percent: Int(v[2]))]
        case ColmiCommandID.notifLiveActivity:
            // Cumulative daily totals; PulseLoop treats steps/distance/calories as an activity update.
            let steps = ColmiBytes.u24(v[2], v[3], v[4])
            let calories = Double(ColmiBytes.u24(v[5], v[6], v[7])) / 10.0
            let distance = Double(ColmiBytes.u24(v[8], v[9], v[10]))
            return [.activityUpdate(timestamp: now, steps: steps, distanceMeters: distance, calories: calories)]
        default:
            return [.commandAck(commandId: v[0])]
        }
    }

    // MARK: Paged history (normal channel)

    /// HR history packet → up to N heart-rate samples (5-minute spaced). The engine handles paging
    /// (which day, packet ordering); here we just emit samples for the given day-of-`now`.
    private func decodeHRHistory(_ v: [UInt8], day: Date? = nil, calendar: Calendar) -> [RingDecodedEvent] {
        let packetNr = Int(v[1])
        // 0xff = empty, 0 = header (total count); neither carries samples.
        guard packetNr != 0xff, packetNr != 0 else { return [] }
        let startIndex = packetNr == 1 ? 6 : 2   // packet 1 has a 4-byte timestamp in 2..5
        var minutesInPrevious = 0
        if packetNr > 1 {
            minutesInPrevious = 9 * 5 + (packetNr - 2) * 13 * 5
        }
        let base = day ?? calendar.startOfDay(for: Date())
        var events: [RingDecodedEvent] = []
        for i in startIndex..<(v.count - 1) {
            let bpm = Int(v[i])
            guard bpm != 0 else { continue }
            let minuteOfDay = minutesInPrevious + (i - startIndex) * 5
            if let ts = calendar.date(byAdding: .minute, value: minuteOfDay, to: base) {
                events.append(.historyMeasurement(kind: .heartRate, value: Double(bpm), timestamp: ts))
            }
        }
        return events
    }

    /// Stress history packet → stress samples (30-minute spaced).
    private func decodeStressHistory(_ v: [UInt8], day: Date? = nil, calendar: Calendar) -> [RingDecodedEvent] {
        let packetNr = Int(v[1])
        guard packetNr != 0xff, packetNr != 0 else { return [] }
        let startIndex = packetNr == 1 ? 3 : 2
        var minutesInPrevious = 0
        if packetNr > 1 {
            minutesInPrevious = 12 * 30 + (packetNr - 2) * 13 * 30
        }
        let base = day ?? calendar.startOfDay(for: Date())
        var events: [RingDecodedEvent] = []
        for i in startIndex..<(v.count - 1) {
            let stress = Int(v[i])
            guard stress != 0 else { continue }
            let minuteOfDay = minutesInPrevious + (i - startIndex) * 30
            if let ts = calendar.date(byAdding: .minute, value: minuteOfDay, to: base) {
                events.append(.stressSample(value: stress, timestamp: ts))
            }
        }
        return events
    }

    /// HRV history packet → HRV samples in ms (30-minute spaced).
    private func decodeHRVHistory(_ v: [UInt8], day: Date? = nil, calendar: Calendar) -> [RingDecodedEvent] {
        let packetNr = Int(v[1])
        guard packetNr != 0xff, packetNr != 0 else { return [] }
        let startIndex = packetNr == 1 ? 3 : 2
        var minutesInPrevious = 0
        if packetNr > 1 {
            minutesInPrevious = 12 * 30 + (packetNr - 2) * 13 * 30
        }
        let base = day ?? calendar.startOfDay(for: Date())
        var events: [RingDecodedEvent] = []
        for i in startIndex..<(v.count - 1) {
            let hrv = Int(v[i])
            guard hrv != 0 else { continue }
            let minuteOfDay = minutesInPrevious + (i - startIndex) * 30
            if let ts = calendar.date(byAdding: .minute, value: minuteOfDay, to: base) {
                events.append(.hrvSample(value: hrv, timestamp: ts))
            }
        }
        return events
    }

    /// Activity history packet → one intraday **bucket** (quarter-hour). Verified against real R11
    /// captures: each `0x43` carries one 15-min bucket, so we emit `.activityBucket` (summed per day)
    /// rather than a cumulative `.activityUpdate`. Calories are intentionally omitted — the ring's
    /// calorie field is unverified/implausible (e.g. 10,915 for a single bucket).
    ///
    /// Layout: `43 yy MM dd qh cur tot ca ca st st di di …` where yy/MM/dd are BCD-literal date bytes,
    /// `qh = v[4]/4` is the nth-quarter-of-day hour, `cur/tot` are packet indices, and
    /// steps=u16(9,10), distance=u16(11,12). **UNVERIFIED:** BCD date + quarter-hour encoding.
    private func decodeActivityHistory(_ v: [UInt8], calendar: Calendar, now: Date = Date()) -> [RingDecodedEvent] {
        // GadgetBridge uses these markers on the first data byte for "empty"/"initial" packets.
        let marker = Int(v[1])
        guard marker != 0xff, marker != 0xf0, v.count >= 13 else { return [] }

        func hexLit(_ b: UInt8) -> Int { Int(String(format: "%02x", b)) ?? Int(b) }
        var comps = DateComponents()
        comps.year = 2000 + hexLit(v[1])
        comps.month = hexLit(v[2])
        comps.day = hexLit(v[3])
        // v[4] is the nth quarter-hour of the day (0…95): hour = q/4, minute = (q%4)*15. Dropping the
        // within-hour offset collapsed all four quarters of an hour onto HH:00, so — since the day
        // total is the sum of buckets keyed by their start epoch — three of every four quarters
        // overwrote each other and daily steps/distance were undercounted by up to ~75%.
        let quarter = min(95, max(0, Int(v[4])))
        comps.hour = quarter / 4
        comps.minute = (quarter % 4) * 15
        comps.second = 0
        guard let ts = calendar.date(from: comps) else { return [] }
        // Reject implausible dates (misframed packet / bad BCD): must be within the last ~8 days.
        let lower = calendar.date(byAdding: .day, value: -8, to: now) ?? now
        let upper = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        guard ts >= lower, ts <= upper else { return [] }

        let steps = ColmiBytes.u16(v[9], v[10])
        let distance = Double(ColmiBytes.u16(v[11], v[12]))
        return [.activityBucket(timestamp: ts, steps: steps, distanceMeters: distance)]
    }

    // MARK: Big-data (V2) — called by the driver after reassembly

    /// Decode a complete reassembled `0xbc` big-data frame by its type byte.
    func decodeBigData(_ data: Data, now: Date = Date(), calendar: Calendar = .current) -> [RingDecodedEvent] {
        let v = [UInt8](data)
        guard v.count >= 6, v[0] == ColmiCommandID.bigDataV2 else {
            return [.unknown(commandId: v.first ?? 0, raw: data)]
        }
        switch v[1] {
        case ColmiCommandID.bigDataSpo2:
            return decodeSpo2(v, calendar: calendar)
        case ColmiCommandID.bigDataSleep:
            return decodeSleep(v, calendar: calendar)
        case ColmiCommandID.bigDataTemperature:
            return decodeTemperature(v, calendar: calendar)
        default:
            return [.unknown(commandId: v[1], raw: data)]
        }
    }

    private func decodeSpo2(_ v: [UInt8], calendar: Calendar) -> [RingDecodedEvent] {
        let length = ColmiBytes.u16(v[2], v[3])
        var index = 6
        var events: [RingDecodedEvent] = []
        var daysAgo = -1
        while daysAgo != 0, index - 6 < length, index < v.count {
            daysAgo = Int(v[index]); index += 1
            let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) ?? Date()
            for hour in 0...23 {
                guard index + 1 < v.count else { break }
                let lo = Int(v[index]); index += 1
                let hi = Int(v[index]); index += 1
                if lo > 0, hi > 0 {
                    let mean = (Double(lo) + Double(hi)) / 2.0
                    let value = mean.rounded()
                    if let ts = calendar.date(byAdding: .hour, value: hour, to: dayStart) {
                        events.append(.historyMeasurement(kind: .spo2, value: value, timestamp: ts))
                    }
                }
                if index - 6 >= length { break }
            }
        }
        return events
    }

    private func decodeTemperature(_ v: [UInt8], calendar: Calendar) -> [RingDecodedEvent] {
        let length = ColmiBytes.u16(v[2], v[3])
        guard length >= 50 else { return [] }
        var index = 6
        var events: [RingDecodedEvent] = []
        var daysAgo = -1
        while daysAgo != 0, index - 6 < length, index < v.count {
            daysAgo = Int(v[index]); index += 1
            index += 1   // skip one unknown byte (observed 0x1e)
            let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) ?? Date()
            for hour in 0...23 {
                guard index + 1 < v.count else { break }
                let t00 = Int(v[index]); index += 1
                let t30 = Int(v[index]); index += 1
                if t00 > 0, let ts = calendar.date(byAdding: .minute, value: hour * 60, to: dayStart) {
                    events.append(.temperatureSample(celsius: Double(t00) / 10.0 + 20.0, timestamp: ts))
                }
                if t30 > 0, let ts = calendar.date(byAdding: .minute, value: hour * 60 + 30, to: dayStart) {
                    events.append(.temperatureSample(celsius: Double(t30) / 10.0 + 20.0, timestamp: ts))
                }
                if index - 6 >= length { break }
            }
        }
        return events
    }

    /// Sleep big-data → a `.sleepTimeline` per day with REM/awake/light/deep stages.
    /// **UNVERIFIED (GadgetBridge-derived):** per-day byte counts and cross-midnight reconstruction.
    private func decodeSleep(_ v: [UInt8], calendar: Calendar) -> [RingDecodedEvent] {
        let packetLength = ColmiBytes.u16(v[2], v[3])
        guard packetLength >= 2, v.count > 7 else { return [] }
        let daysInPacket = Int(v[6])
        var index = 7
        var events: [RingDecodedEvent] = []
        for _ in 0..<daysInPacket {
            guard index + 5 < v.count else { break }
            let daysAgo = Int(v[index]); index += 1
            let dayBytes = Int(v[index]); index += 1
            let sleepStart = ColmiBytes.u16(v[index], v[index + 1]); index += 2
            let sleepEnd = ColmiBytes.u16(v[index], v[index + 1]); index += 2
            let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) ?? Date()
            // Session start: if start > end the session began before midnight (prior day).
            let startOffset = sleepStart > sleepEnd ? sleepStart - 1440 : sleepStart
            let sessionStart = calendar.date(byAdding: .minute, value: startOffset, to: dayStart) ?? dayStart

            var stages: [SleepStage] = []
            var j = 4
            while j < dayBytes, index + 1 < v.count {
                let stageType = v[index]
                let minutes = Int(v[index + 1])
                index += 2
                j += 2
                guard minutes > 0 else { continue }
                let stage = Self.sleepStage(stageType)
                // Expand to one entry per minute so the existing hypnogram (which maps a [SleepStage]
                // timeline) renders proportional blocks.
                stages.append(contentsOf: Array(repeating: stage, count: minutes))
            }
            if !stages.isEmpty {
                events.append(.sleepTimeline(timestamp: sessionStart, stages: stages))
            }
        }
        return events
    }

    static func sleepStage(_ type: UInt8) -> SleepStage {
        switch type {
        case ColmiCommandID.sleepLight: return .light
        case ColmiCommandID.sleepDeep: return .deep
        case ColmiCommandID.sleepREM: return .rem
        case ColmiCommandID.sleepAwake: return .awake
        default: return .unknown
        }
    }
}
