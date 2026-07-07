import Foundation

/// Builds *logical* TK5 commands — `[type, cmd, payload…]` without the length field or CRC, which
/// `TK5Driver.frame(_:)` appends. The connect handshake is a faithful replay of the exact byte
/// sequence the SmartHealth app sent on connect (only the time command is regenerated), which is the
/// safest way to reproduce known-good ring behavior for the fields we can't independently decode.
struct TK5Encoder {
    /// Set the ring clock: `01 00` + `[year:2 LE][month][day][hour][min][sec][00]`.
    /// Verified against the capture (`ea07 07 06 0c 22 0e 00` = 2026-07-06 12:34:14).
    func setTime(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(c.year ?? 2000)
        return [TK5FrameType.config, TK5Command.setTime,
                UInt8(year & 0xff), UInt8((year >> 8) & 0xff),
                UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0), 0x00]
    }

    /// The connect handshake, in order, as the SmartHealth app issued it (time regenerated). These are
    /// replayed verbatim because the ring expects this exact sequence; the 2-byte tokens on the `0x02`
    /// commands are constants observed in the capture.
    /// UNVERIFIED (capture-inferred): whether those tokens are session-stable across reconnects.
    func startupSequence(date: Date = Date()) -> [[UInt8]] {
        var seq: [[UInt8]] = []
        seq.append(setTime(date))
        seq.append(logical("02", "01", "4746"))   // device info
        seq.append(logical("02", "1b", ""))        // (post-info probe)
        seq.append(logical("02", "00", "4743"))    // status (battery lives here)
        seq.append(logical("02", "07", "4346"))
        seq.append(logical("02", "03", "4750"))
        // Calibration/preference register reads — harmless, mirror the app's connect probe.
        for cmd in ["02", "04", "06", "08", "09", "33"] { seq.append(logical("05", cmd, "")) }
        // Config writes the app pushes every connect (exact bytes; meanings not independently decoded).
        seq.append(logical("01", "12", "00"))
        seq.append(logical("01", "04", "010100010000"))
        seq.append(logical("01", "0c", "013c"))
        seq.append(logical("01", "09", "003132"))
        seq.append(logical("01", "03", "aa40002b"))
        seq.append(logical("04", "0e", "00"))       // bond nudge
        seq.append(contentsOf: enableAllMonitoring())
        seq.append(enableLiveStatus())
        return seq
    }

    /// Enable the ring's **live status auto-push** (`03 09 01 00 02`). Once sent, the ring streams
    /// `06 00` status frames (current step count / distance / calories) on be940003 continuously while
    /// connected — verified in the captures, where the first `06 00` appears immediately after this
    /// command and then repeats for the rest of the session. Without it the app only sees the one-time
    /// history dump, so today's live step count never updates. (`03 09 00 00 02` disables it.)
    func enableLiveStatus() -> [UInt8] { logical("03", "09", "010002") }

    /// Enable the ring's all-day background monitoring for the extra metrics. Each `05 <metric> 02`
    /// write turns one metric's auto-sampling on (`0x02` = enable, the Colmi-family pref-write
    /// convention); the second capture showed the SmartHealth app send exactly this burst when the
    /// user toggled HRV/stress/temperature/SpO₂/sleep monitoring on, and the `05 09` config read-back
    /// then reported the enabled state. Sending them on connect makes the ring *record* these metrics
    /// so a later history dump has something to return (notably: sleep, once worn overnight).
    /// UNVERIFIED (capture-inferred): the exact metric↔cmd mapping. We enable the whole observed set so
    /// nothing is missed; each is an idempotent, individually-acked pref-write.
    func enableAllMonitoring() -> [[UInt8]] {
        ["40", "42", "43", "44", "4e"].map { logical("05", $0, "02") }
    }

    // MARK: - History dump

    /// Begin the history dump. `02 24` + `f0` (header marker); records then stream on be940003.
    func historyStart() -> [UInt8] { logical("02", "24", "f0") }
    /// Request the next history page. `02 26` (no payload).
    func historyPage() -> [UInt8] { [TK5FrameType.device, TK5Command.historyPage] }
    /// Acknowledge / finish the history dump. `02 28` + token.
    func historyAck() -> [UInt8] { logical("02", "28", "4746") }

    // MARK: - Live actions

    /// Live measurement start/stop via `03 2f` with a `[enable:1][mode:1]` payload. The **mode byte
    /// selects the sensor**, verified against the capture: mode 0x00 = heart rate (green LED) → `06 01`
    /// stream, 0x02 = SpO₂ (red/IR LED) → `06 02`, 0x0a = HRV → `06 03`. Stop is mode-agnostic
    /// (`00 00`). Using the wrong mode lights the wrong LED and yields no reading, so each metric must
    /// use its own start.
    func heartRateStart() -> [UInt8] { logical("03", "2f", "0100") }
    func spo2Start() -> [UInt8] { logical("03", "2f", "0102") }
    func hrvStart() -> [UInt8] { logical("03", "2f", "010a") }
    func liveStreamStop() -> [UInt8] { logical("03", "2f", "0000") }

    /// Find-device / bond nudge (`04 0e`). Best-effort; the TK5 has no confirmed vibrate command in
    /// the capture, so this is the closest observed "poke the ring" frame.
    func findDevice() -> [UInt8] { logical("04", "0e", "00") }

    // MARK: - Helpers

    /// Assemble a logical command from hex strings for `type`, `cmd`, and `payload`.
    private func logical(_ type: String, _ cmd: String, _ payload: String) -> [UInt8] {
        var out: [UInt8] = [UInt8(type, radix: 16) ?? 0, UInt8(cmd, radix: 16) ?? 0]
        var i = payload.startIndex
        while i < payload.endIndex {
            let next = payload.index(i, offsetBy: 2)
            if let b = UInt8(payload[i..<next], radix: 16) { out.append(b) }
            i = next
        }
        return out
    }
}
