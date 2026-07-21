import Foundation
@preconcurrency import CoreBluetooth

/// Reassembles CRP command replies (`fdd3`) that span multiple BLE notifications. A logical frame
/// starts with `FD DA …` and its declared total length (`CRPProtocol.frameLength`) tells us when it
/// is complete. Mirrors the vendor's `g1/a.k()`. One assembler instance per connection — a fresh
/// `CRPDriver` is built on every connect, so state always starts clean.
final class CRPFrameAssembler {
    private var buffer: [UInt8] = []
    private var expected = 0

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
///   - `2a37` → standard HR-measurement stream
///   - `fdd3` → framed `FD DA …` command replies (already reassembled by `CRPFrameAssembler`)
///
/// Unverified-against-hardware layouts are decoded conservatively: anything whose byte layout isn't
/// confirmed from the decompile is emitted as `.commandAck` rather than fabricating a metric value.
/// Extend `decodeFramedReply` as more command replies are confirmed.
enum CRPDecoder {

    static func decode(_ data: Data, from characteristic: CBUUID, now: Date = Date()) -> [RingDecodedEvent] {
        switch characteristic {
        case CRPUUIDs.stepsNotifyCBUUID:
            return decodeCurrentSteps(data, now: now)
        case CRPUUIDs.heartRateMeasureCBUUID:
            return decodeHeartRateMeasure(data, now: now)
        default:
            return CRPProtocol.isFrameStart(data) ? decodeFramedReply(data, now: now) : []
        }
    }

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

    /// Standard HR characteristic (`2a37`). From `g1/a.B`: bpm at byte[1], validated by the `0x0400`
    /// marker at bytes[2..3] (little-endian: byte[3] high).
    private static func decodeHeartRateMeasure(_ data: Data, now: Date) -> [RingDecodedEvent] {
        let b = [UInt8](data)
        if b.count < 2 { return [] }
        let bpm = Int(b[1])
        let markerOk = b.count < 4 || ((Int(b[3]) << 8) | Int(b[2])) == 0x0400
        if !markerOk || bpm <= 0 { return [] }
        return [.heartRateSample(bpm: bpm, timestamp: now)]
    }

    /// Framed `fdd3` reply: `FD DA 10 <len> <group> <cmd> <payload>`. v1 acknowledges recognised
    /// command echoes; richer metric replies (HR/SpO2 results, history) are decoded as more layouts
    /// are confirmed against the decompile/hardware.
    private static func decodeFramedReply(_ frame: Data, now: Date) -> [RingDecodedEvent] {
        let b = [UInt8](frame)
        if b.count < CRPProtocol.headerSize { return [] }
        let group = Int(b[4])
        let cmd = Int(b[5])
        // Only the command echo is confirmed for the v1 command set; treat as an ack so the
        // raw-notify/debug feed still records it without inventing a metric value.
        return [.commandAck(commandId: UInt8(truncatingIfNeeded: (group << 4) | (cmd & 0x0F)))]
    }

    /// Little-endian unsigned 3-byte int at `offset`.
    private static func le3(_ b: [UInt8], _ offset: Int) -> Int {
        Int(b[offset]) | (Int(b[offset + 1]) << 8) | (Int(b[offset + 2]) << 16)
    }
}
