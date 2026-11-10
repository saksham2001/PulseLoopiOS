import Foundation

/// One on-demand HR or SpO₂ measurement on a CRP ring (COLMI R11 / "Da Rings"), and the rule for when it
/// is over.
///
/// ## Why CRP doesn't use `HRSampleWindow`
///
/// The R11 answers a spot HR start (`group 1 / cmd 9`) or SpO₂ start (`cmd 11`) with a **single terminal
/// result frame** — ~15–17 s after start for HR, ~48 s for SpO₂ — and then sends nothing more. The
/// vendor treats every cmd-9/11 frame as the end of the measurement. Run through `HRSampleWindow` (six
/// samples, a 3 s contact gap), a valid reading was one sample and always failed.
///
/// ## The rule
///
///  - The first result frame decides: a value in band (HR 40–200, SpO₂ 70–100) is the reading; an empty
///    payload, 0, `0xFF` or anything out of band is the ring saying it got none.
///  - A not-worn push (`group 3 / cmd 7 [00]`, or the bridged wear state) fails it at once, as does a link
///    drop.
///  - The deadline counts from when the start command was **written**, not when it was queued: the ring
///    can't have started before then. A start that is never written within `dispatchTimeout` fails too,
///    so nothing waits on a write that never happens.
///  - History traffic (group 2) never ends a measurement; only the result frame for this kind does.
///  - The first verdict wins: a wear-state drop after a good reading can't turn it into a failure.
struct CRPSpotMeasurement {
    enum Kind: Equatable {
        case heartRate, spo2

        /// The result frame's `group 1` command (the same number as the start command).
        var resultCmd: Int { self == .heartRate ? CRPCommands.cmdResultHR : CRPCommands.cmdResultSpO2 }
        var validRange: ClosedRange<Int> { self == .heartRate ? 40...200 : 70...100 }
        /// Ceiling from the write, set around the R11's ~15–17 s (HR) and ~48 s (SpO₂).
        var window: TimeInterval { self == .heartRate ? 30 : 60 }
    }

    enum Failure: Equatable {
        case notWorn, noReading, disconnected, timedOut, notDispatched
    }

    enum Verdict: Equatable {
        case reading(Int)
        case failed(Failure)
    }

    /// How long the start command may wait to be written before the measurement fails.
    static let dispatchTimeout: TimeInterval = 15

    let kind: Kind
    /// Tells this measurement's late write callback apart from the next one's.
    let id = UUID()
    private let queuedAt: Date
    private(set) var writtenAt: Date?
    private(set) var verdict: Verdict?

    init(kind: Kind, queuedAt: Date = Date()) {
        self.kind = kind
        self.queuedAt = queuedAt
    }

    /// The start command left the queue (`true`) or could not be written (`false`).
    mutating func noteStartWritten(_ written: Bool, at now: Date = Date()) {
        if written {
            if writtenAt == nil { writtenAt = now }
        } else {
            decide(.failed(.notDispatched))
        }
    }

    /// One incoming notification. Only a whole `group 1` result frame for this kind, or a not-worn push,
    /// decides anything.
    mutating func ingest(_ frame: Data) {
        let b = [UInt8](frame)
        guard b.count >= CRPProtocol.headerSize, CRPProtocol.isFrameStart(frame),
              CRPProtocol.frameLength(frame) == b.count else { return }
        let group = Int(b[4]), cmd = Int(b[5])
        let payload = b.dropFirst(CRPProtocol.headerSize)
        if group == CRPCommands.groupPower, cmd == CRPCommands.cmdWearState, payload.first == 0 {
            decide(.failed(.notWorn))
        } else if group == CRPCommands.groupDevice, cmd == kind.resultCmd {
            if let value = payload.first.map(Int.init), kind.validRange.contains(value) {
                decide(.reading(value))
            } else {
                decide(.failed(.noReading))
            }
        }
    }

    mutating func noteWorn(_ worn: Bool) {
        if !worn { decide(.failed(.notWorn)) }
    }

    mutating func noteDisconnected() {
        decide(.failed(.disconnected))
    }

    /// The verdict, applying the deadlines as of `now`.
    mutating func check(at now: Date = Date()) -> Verdict? {
        if let writtenAt {
            if now.timeIntervalSince(writtenAt) >= kind.window { decide(.failed(.timedOut)) }
        } else if now.timeIntervalSince(queuedAt) >= Self.dispatchTimeout {
            decide(.failed(.notDispatched))
        }
        return verdict
    }

    private mutating func decide(_ verdict: Verdict) {
        if self.verdict == nil { self.verdict = verdict }
    }
}
