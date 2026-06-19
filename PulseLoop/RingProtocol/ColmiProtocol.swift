import Foundation

/// Colmi R02 (Yawell) protocol primitives: UUIDs, opcodes, 16-byte checksummed framing, and the
/// decoder/encoder. Reconstructed from GadgetBridge's `yawell/ring` package — see
/// `docs/ColmiR02-Protocol.md`. Byte layouts that could not be verified against a physical ring are
/// tagged `// UNVERIFIED (GadgetBridge-derived)`.
///
/// This is intentionally *separate* from the jring's `RingProtocol.swift`: the two share nothing at
/// the wire level (different UUIDs, 16-byte checksummed frames vs 20-byte unchecked, a second
/// big-data channel). Decoded output is normalized into the shared `RingDecodedEvent` so the rest of
/// the app stays device-agnostic.

enum ColmiUUIDs {
    // Service variants — a given R02 firmware exposes V1 (Nordic-UART style) and/or V2.
    static let serviceV1 = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"
    static let serviceV2 = "de5bf728-d711-4e47-af26-65e3012a5dc7"
    static let write = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"       // normal commands
    static let command = "de5bf72a-d711-4e47-af26-65e3012a5dc7"     // big-data requests
    static let notifyV1 = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"    // normal notifications
    static let notifyV2 = "de5bf729-d711-4e47-af26-65e3012a5dc7"    // big-data notifications
}

enum ColmiCommandID {
    static let setDateTime: UInt8 = 0x01
    static let battery: UInt8 = 0x03
    static let phoneName: UInt8 = 0x04
    static let displayPref: UInt8 = 0x05
    static let powerOff: UInt8 = 0x08
    static let preferences: UInt8 = 0x0a
    static let syncHeartRate: UInt8 = 0x15
    static let autoHRPref: UInt8 = 0x16
    static let realtimeHeartRate: UInt8 = 0x1e
    static let goals: UInt8 = 0x21
    static let autoSpo2Pref: UInt8 = 0x2c
    static let packetSize: UInt8 = 0x2f
    static let autoStressPref: UInt8 = 0x36
    static let syncStress: UInt8 = 0x37
    static let autoHRVPref: UInt8 = 0x38
    static let syncHRV: UInt8 = 0x39
    static let autoTempPref: UInt8 = 0x3a
    static let syncActivity: UInt8 = 0x43
    static let findDevice: UInt8 = 0x50
    static let manualHeartRate: UInt8 = 0x69
    static let notification: UInt8 = 0x73
    static let bigDataV2: UInt8 = 0xbc
    static let factoryReset: UInt8 = 0xff

    static let prefRead: UInt8 = 0x01
    static let prefWrite: UInt8 = 0x02
    static let prefDelete: UInt8 = 0x03

    // 0x73 notification subtypes
    static let notifNewHR: UInt8 = 0x01
    static let notifNewSpo2: UInt8 = 0x03
    static let notifNewSteps: UInt8 = 0x04
    static let notifBattery: UInt8 = 0x0c
    static let notifLiveActivity: UInt8 = 0x12

    // big-data types
    static let bigDataTemperature: UInt8 = 0x25
    static let bigDataSleep: UInt8 = 0x27
    static let bigDataSpo2: UInt8 = 0x2a

    // sleep stage types
    static let sleepLight: UInt8 = 0x02
    static let sleepDeep: UInt8 = 0x03
    static let sleepREM: UInt8 = 0x04
    static let sleepAwake: UInt8 = 0x05
}

/// A normal (non-big-data) 16-byte Colmi frame: 15 content bytes + a trailing checksum byte equal to
/// `(Σ content bytes) & 0xff`.
struct ColmiPacket {
    let bytes: [UInt8]

    /// Build a framed 16-byte packet from logical content (≤15 bytes), appending the checksum.
    static func frame(_ content: [UInt8]) -> Data {
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = min(content.count, 15)
        for i in 0..<count { buffer[i] = content[i] }
        var checksum = 0
        for i in 0..<15 { checksum = (checksum + Int(buffer[i])) & 0xff }
        buffer[15] = UInt8(checksum)
        return Data(buffer)
    }

    /// Validate a received 16-byte frame's checksum. Returns nil if the length or checksum is wrong.
    init?(validating data: Data) {
        guard data.count == 16 else { return nil }
        let arr = [UInt8](data)
        var checksum = 0
        for i in 0..<15 { checksum = (checksum + Int(arr[i])) & 0xff }
        guard UInt8(checksum) == arr[15] else { return nil }
        self.bytes = arr
    }
}

// MARK: - Little-endian helpers (mirroring GadgetBridge's BLETypeConversions)

enum ColmiBytes {
    static func u16(_ a: UInt8, _ b: UInt8) -> Int {
        Int(a) | (Int(b) << 8)
    }
    static func u32(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a) | (Int(b) << 8) | (Int(c) << 16) | (Int(d) << 24)
    }
    /// 24-bit LE (GadgetBridge passes a 0 high byte to toUint32).
    static func u24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
        Int(a) | (Int(b) << 8) | (Int(c) << 16)
    }
}
