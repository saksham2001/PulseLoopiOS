import Foundation

/// The switch that decides whether raw BLE packets (`RawPacketRow`) are persisted and exported.
///
/// DEBUG builds always capture — the packet feed is the daily protocol-debugging tool. Release
/// builds capture **only while the user has switched it on** in Privacy & Data → Diagnostics. The
/// release path exists for exactly one workflow: a remote tester on TestFlight pairing a ring
/// family nobody on the project has in hand (RWfit is the first), where the diagnostics export's
/// hex rows are the only way to see what the ring actually said. Raw packets encode health
/// readings, so the toggle is off by default, visibly labelled, and the captured rows can be
/// cleared from the same screen.
enum RawPacketCapture {
    static let defaultsKey = "diagnostics.captureRawPackets"

    /// Whether the persistence subscriber should store packets right now.
    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return userOptedIn
        #endif
    }

    /// The release-build opt-in, as shown by the Privacy & Data toggle.
    static var userOptedIn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
