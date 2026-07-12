import Foundation

/// The timezone offset we last told the jring about.
///
/// The jring's RTC holds **local wall-clock** seconds, because `RingEncoder.makeTimeSyncCommand`
/// sends `utcEpoch + utcOffset` (matching the vendor SDK, which caches the same offset in its `d1`
/// field). Every timestamp the ring stamps onto a history record is therefore a local-wall-clock
/// epoch, and must have that offset subtracted back off to recover a true instant.
///
/// These two halves must always move together: changing the encoder without the decoder — or vice
/// versa — shifts all history by the UTC offset.
///
/// One instance is created per connection by `JringDriver` and shared with the driver's
/// `RingDecoder` and `JringSyncEngine`, so the offset used to decode a reply is always the one that
/// connection actually sent. It is a reference type so both hold the same latched value, and it
/// inherits the project's `MainActor` default isolation (the whole BLE path already runs there).
final class JringClock {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Seconds east of UTC, DST included — the vendor's `TimeZone.getDefault().getOffset(now)`.
    private(set) var offsetSeconds: TimeInterval

    init(timeZone: TimeZone = .current, now: Date = Date()) {
        offsetSeconds = TimeInterval(timeZone.secondsFromGMT(for: now))
    }

    /// Latch the offset that is about to go out on the wire in an 0x01 time-sync command.
    func capture(timeZone: TimeZone = .current, now: Date = Date()) {
        offsetSeconds = TimeInterval(timeZone.secondsFromGMT(for: now))
    }

    /// Convert a ring-stamped local-wall-clock epoch into a true `Date`.
    func date(fromRingEpoch raw: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(raw) - offsetSeconds)
    }
}
