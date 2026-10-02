import Foundation

/// One deframed legacy (`0x7E`) event, as surfaced to `RWfitDriver.ingest`.
enum RWfitLegacyInbound: Equatable {
    /// A complete data frame (single-packet, or a fully reassembled multi-packet payload). The driver
    /// must app-ACK it (`ackNeeded` accompanies it) and decode it.
    case frame(cmd: UInt8, payload: [UInt8])
    /// The device ACKed one of our commands: `0xFE` with `[serHi, serLo, cmd, status]`
    /// (`x5/d.java i()`). Releases the command gate.
    case deviceAck(cmd: UInt8, serial: Int, status: UInt8)
    /// A frame (or one chunk of a multi-packet frame) arrived and must be app-ACKed with the given
    /// serial — emitted *before* the corresponding `.frame`, mirroring the vendor's ACK-before-parse
    /// order (`x5/d.java h()`).
    case ackNeeded(cmd: UInt8, serial: Int)
    /// A frame failed its XOR checksum; NACK it (status `0x02`) so the device retransmits.
    case checksumFailed(cmd: UInt8, serial: Int)
}

/// Legacy (`0x7E` / "Realtek") wire codec: framing, serials, XOR checksums, ACK frames, and inbound
/// multi-packet reassembly. Byte-for-byte port of `x5/d.java` (`CmdHandlerUtils`).
///
/// Header (single-packet, 8 bytes): `7E 01 cmd flags dataLen serHi serLo xor`. Multi-packet sets
/// flag bit 3 and inserts `totalBE(2) currentBE(2)` at [8..11] (current is 1-based); each chunk
/// carries its own dataLen and XOR. Serials run 1…65535 and wrap.
@MainActor
final class RWfitLegacyCodec {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Outbound serial counter (`x5/d.java` `this.e`, incremented per queued command).
    private var serial: Int = 0
    /// In-flight inbound multi-packet reassembly, keyed by cmd id (`x5/d.java` `f19809c`).
    private var partials: [UInt8: [(index: Int, chunk: [UInt8])]] = [:]

    /// Reset all cross-frame state. Call on connect/disconnect — a chunk left from a dropped link
    /// must never complete a frame on the next one.
    func reset() {
        partials.removeAll()
        // Serials deliberately keep counting: the vendor never resets them mid-session, and a fresh
        // link accepts any serial (it is an echo token, not a sequence check).
    }

    private func nextSerial() -> Int {
        serial = serial >= 65535 ? 1 : serial + 1
        return serial
    }

    // MARK: - Encode

    /// Frame one logical command, returning the serial it was stamped with so the command gate can
    /// match the device's `0xFE` ACK against it. All PulseLoop commands fit a single packet (dataLen
    /// is one byte and our largest payload — the bind userId — is well under 255); the vendor only
    /// multi-packets file transfers, which we don't do.
    func encode(cmd: UInt8, payload: [UInt8]) -> (frame: Data, serial: Int) {
        precondition(payload.count <= 0xff, "legacy payload exceeds single-frame capacity")
        let serial = nextSerial()
        var frame: [UInt8] = [0x7e, 0x01, cmd, 0x00, UInt8(payload.count)]
        frame.append(contentsOf: RWfitBytes.packU16BE(serial))
        frame.append(payload.isEmpty ? 0x00 : RWfitBytes.xorChecksum(payload))
        frame.append(contentsOf: payload)
        return (Data(frame), serial)
    }

    /// Build the app→device ACK for an inbound frame: cmd `0xFF`, payload `[serHi, serLo, cmd,
    /// status]` where the serial is the *inbound* frame's (`x5/d.java b()`). Status 0 = OK,
    /// 2 = checksum failure (asks the device to retransmit). The ACK frame's own header serial is
    /// freshly assigned, exactly as the vendor's `j((byte) -1, …)` path does.
    func ack(cmd: UInt8, serial inboundSerial: Int, status: UInt8) -> Data {
        let ser = RWfitBytes.packU16BE(inboundSerial)
        return encode(cmd: RWfitLegacyCommand.appAck, payload: [ser[0], ser[1], cmd, status]).frame
    }

    // MARK: - Decode

    /// Deframe one notification. Returns every event it produced (ACK requests first, then frames).
    func decode(_ data: Data) -> [RWfitLegacyInbound] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x7e else { return [] }

        let cmd = bytes[2]
        let isMultiPacket = (bytes[3] >> 3) & 1 == 1
        let dataLen = Int(bytes[4])
        let serial = RWfitBytes.u16BE(bytes, 5)
        let checksum = bytes[7]

        if !isMultiPacket || bytes.count <= 9 {
            guard bytes.count >= 8 + dataLen else { return [] }
            let payload = Array(bytes[8..<(8 + dataLen)])
            if dataLen > 0, checksum != RWfitBytes.xorChecksum(payload) {
                return [.checksumFailed(cmd: cmd, serial: serial)]
            }
            if cmd == RWfitLegacyCommand.deviceAck {
                guard payload.count >= 4 else { return [] }
                return [.deviceAck(cmd: payload[2], serial: RWfitBytes.u16BE(payload, 0), status: payload[3])]
            }
            return [.ackNeeded(cmd: cmd, serial: serial), .frame(cmd: cmd, payload: payload)]
        }

        // Multi-packet: `totalBE currentBE` at [8..11], chunk at [12...]. Each chunk is ACKed on its
        // own and buffered; the combined payload is surfaced when all chunks are in
        // (`x5/d.java h()`, multi-packet branch — including its sort by current index).
        guard bytes.count >= 12 + dataLen else { return [] }
        let total = RWfitBytes.u16BE(bytes, 8)
        let current = RWfitBytes.u16BE(bytes, 10)
        let chunk = Array(bytes[12..<(12 + dataLen)])
        if dataLen > 0, checksum != RWfitBytes.xorChecksum(chunk) {
            return [.checksumFailed(cmd: cmd, serial: serial)]
        }

        var events: [RWfitLegacyInbound] = []
        if cmd != RWfitLegacyCommand.deviceAck {
            events.append(.ackNeeded(cmd: cmd, serial: serial))
        }
        var collected = partials[cmd] ?? []
        collected.append((index: current, chunk: chunk))
        partials[cmd] = collected
        if current == total, collected.count == total {
            let payload = collected.sorted { $0.index < $1.index }.flatMap(\.chunk)
            partials[cmd] = nil
            events.append(.frame(cmd: cmd, payload: payload))
        }
        return events
    }
}
