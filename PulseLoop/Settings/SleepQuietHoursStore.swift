import Foundation

/// The opt-in "sleep quiet hours" schedule (Android #79/#80): ignore sleep the ring records outside
/// a daily clock window. A still wrist reads as sleep, so an evening on the sofa lands as a phantom
/// record and the night runs an hour high; the wearer knows their bedtime, the sensor guesses.
///
/// **Minute-level, not record-level.** A record is trimmed to the minutes inside the window
/// (`keptMinutes`) rather than accepted or declined by its start: the ring often opens one record on
/// the sofa and runs it straight on into the real night.
///
/// **Drop-on-import, and not recoverable.** Trimmed minutes are never written, so widening the
/// window later can't bring back what was skipped — the alternative (import everything, hide
/// outside the window) would leave the ring's figure and the displayed one forever disagreeing.
/// Off by default for exactly this reason. Android's Bedtime/DND source is an Android platform
/// feature and isn't ported: on iOS the clock schedule is the only source.
struct SleepQuietHours: Codable, Equatable {
    var enabled = false
    /// Window start, minutes of the local day (default 22:00).
    var startMinutes = 22 * 60
    /// Window end, minutes of the local day (default 07:00).
    var endMinutes = 7 * 60

    static let `default` = SleepQuietHours()
    static let storageKey = "pulseloop.sleepquiethours.v1"

    init() {}

    init(enabled: Bool, startMinutes: Int, endMinutes: Int) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    /// Tolerant decode: a missing key falls back to its default, so a blob from an older build is
    /// never discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SleepQuietHours.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        startMinutes = try c.decodeIfPresent(Int.self, forKey: .startMinutes) ?? d.startMinutes
        endMinutes = try c.decodeIfPresent(Int.self, forKey: .endMinutes) ?? d.endMinutes
    }

    /// The stored schedule, read at use time so a settings change applies from the next record.
    static func load(from defaults: UserDefaults = .standard) -> SleepQuietHours {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(SleepQuietHours.self, from: data) else { return .default }
        return value
    }

    /// Which minutes of a ring record starting at `start` with `count` stage minutes to keep, as
    /// indices into its stages: the whole record when the schedule is off, else the clock window's
    /// longest stretch (`keptMinutes`). Nil drops the record.
    func keptMinutes(start: Date, count: Int, calendar: Calendar = .current) -> Range<Int>? {
        guard count > 0 else { return nil }
        guard enabled else { return 0..<count }
        return Self.keptMinutes(start: start, count: count, startMinutes: startMinutes,
                                endMinutes: endMinutes, calendar: calendar)
    }

    // MARK: Window arithmetic

    /// Does local minute-of-day `minuteOfDay` fall inside the window `start`→`end`? Inclusive at the
    /// start, exclusive at the end — a 07:00 record belongs to the day. A window whose start equals
    /// its end covers the whole day, which disables trimming without a second flag.
    static func covers(start: Int, end: Int, minuteOfDay: Int) -> Bool {
        if start == end { return true }
        return start < end ? (start..<end).contains(minuteOfDay) : (minuteOfDay >= start || minuteOfDay < end)
    }

    /// The longest contiguous stretch of a record's minutes inside the window. Longest-stretch rather
    /// than every in-window minute because the window is one daily interval: a record long enough to
    /// touch two of them must not bridge the hole between with a record that was never contiguous.
    /// Nil when no minute is inside.
    static func keptMinutes(start: Date, count: Int, startMinutes: Int, endMinutes: Int,
                            calendar: Calendar = .current) -> Range<Int>? {
        guard count > 0 else { return nil }
        var best: Range<Int>?
        var runStart: Int?
        for i in 0...count {
            let inside = i < count && covers(start: startMinutes, end: endMinutes,
                                             minuteOfDay: minuteOfDay(start.addingTimeInterval(Double(i) * 60), calendar: calendar))
            if inside, runStart == nil { runStart = i }
            if !inside, let from = runStart {
                if (i - from) > (best?.count ?? 0) { best = from..<i }
                runStart = nil
            }
        }
        return best
    }

    /// Local wall-clock minute of the day.
    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// Observable, `UserDefaults`-backed store for the quiet-hours schedule (the Settings binding).
/// Follows the `NutritionPrefsStore` pattern; the import reads `SleepQuietHours.load()` directly.
@MainActor
@Observable
final class SleepQuietHoursStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = SleepQuietHoursStore()

    private let defaults: UserDefaults

    var prefs: SleepQuietHours {
        didSet {
            guard let data = try? JSONEncoder().encode(prefs) else { return }
            defaults.set(data, forKey: SleepQuietHours.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = SleepQuietHours.load(from: defaults)
    }
}
