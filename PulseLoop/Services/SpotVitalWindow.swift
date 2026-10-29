import Foundation

/// The streamed values of one on-demand HRV / stress / temperature measurement, and the rule for when
/// they have settled into a reading.
///
/// ## The vendor's rule
///
/// QRing's three measure screens (`HrvActivity`, `DayPressureFragment`, `TemperatureActivity` in
/// decompiled-qring-official/) share one shape: a 75 s countdown, then every value above zero replaces
/// the one on screen and re-posts the finishing step one second ahead (`removeCallbacks` +
/// `postDelayed(…, 1000)`). The measurement therefore ends **one second after the ring stops
/// streaming**, on the last value it streamed.
///
/// A Ring 2 Pro capture shows the ring doing its part: after ~25 s of zero-valued warm-up frames it
/// streams a value about every 0.5 s for a few seconds (HRV: eleven values over 5.5 s), then goes
/// quiet, and QRing stops ~1.2 s later. The ring's `0x6A` stop acknowledgement echoes that same last
/// value — so the last sample is also the ring's own answer.
struct SpotVitalWindow {
    /// QRing's `postDelayed(…, 1000)`.
    static let quietInterval: TimeInterval = 1

    private var vital: SpotVital?
    private var last: Double?
    private var lastAt: Date?

    mutating func begin(_ vital: SpotVital) {
        self.vital = vital
        last = nil
        lastAt = nil
    }

    /// Keep `value` if it belongs to the run in flight and is plausible; returns whether it was kept.
    @discardableResult
    mutating func collect(_ vital: SpotVital, value: Double, at time: Date) -> Bool {
        guard vital == self.vital, RingEventBridge.isPlausible(kind: vital.kind, value: value) else { return false }
        last = value
        lastAt = time
        return true
    }

    var receivedReading: Bool { last != nil }

    /// The last plausible value streamed, or nil if none arrived.
    var settled: Double? { last }

    /// True once a value has arrived and the ring has been quiet for `quietInterval` since.
    func isSettled(at now: Date) -> Bool {
        guard last != nil, let lastAt else { return false }
        return now.timeIntervalSince(lastAt) >= Self.quietInterval
    }
}
