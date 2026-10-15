import Foundation

/// The user's own sleep schedule, learned from recent nights — the anchor every window hangs off.
struct CircadianBaseline: Equatable {
    /// Median bedtime, minutes on a −12…+12 h axis centred on midnight.
    let bedtimeMinutesFromMidnight: Double
    /// Median wake time, on the same axis (so an 07:00 wake is +420).
    let wakeMinutesFromMidnight: Double
    let nights: Int

    /// Enough history to call a schedule "usual" — the same seven-night floor the bedtime-consistency
    /// contributor uses.
    static let minNights = 7
    var isEstablished: Bool { nights >= Self.minNights }

    /// Minutes past midnight on a wrapped axis: 23:00 → −60, 01:00 → +60. Shared with
    /// `BedtimeBaseline` so bedtimes are placed identically wherever they are read.
    static func minutesFromMidnight(_ date: Date, calendar: Calendar = .current) -> Double {
        BedtimeBaseline.minutesFromMidnight(date, calendar: calendar)
    }

    static func compute(bedtimes: [Date], wakeTimes: [Date], calendar: Calendar = .current) -> CircadianBaseline? {
        guard !bedtimes.isEmpty, bedtimes.count == wakeTimes.count else { return nil }
        func median(_ dates: [Date]) -> Double {
            let values = dates.map { minutesFromMidnight($0, calendar: calendar) }.sorted()
            let mid = values.count / 2
            return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
        }
        return CircadianBaseline(
            bedtimeMinutesFromMidnight: median(bedtimes),
            wakeMinutesFromMidnight: median(wakeTimes),
            nights: bedtimes.count
        )
    }
}

/// Timing guidance hung off the user's own schedule: when to stop caffeine, when to stop eating,
/// when to start winding down, and when to get light.
///
/// **Anchored on sleep timing, not on sunrise.** Ultrahuman's equivalent windows use location to
/// derive solar times; PulseLoop doesn't, for two reasons. The project's principles keep data on the
/// device and location optional, and the circadian advice these windows encode is *already* phrased
/// relative to your own sleep in the literature — "get bright light within an hour or two of waking",
/// not "at sunrise". A night-shift worker's morning is their morning.
///
/// The one thing this therefore cannot do is tell you whether it is actually light outside. The
/// light window says when your body clock is most responsive to light, not when the sun is up.
struct CircadianWindows: Equatable {
    /// Stop caffeine by this time.
    let caffeineCutoff: Date
    /// Aim to finish eating by this time.
    let lastMealBy: Date
    /// Start winding down from this time.
    let windDownFrom: Date
    /// Get bright light before this time, counted from your usual wake.
    let morningLightBy: Date
    /// Your usual bedtime, for context.
    let usualBedtime: Date
    /// Your usual wake time, for context.
    let usualWake: Date

    /// Caffeine's half-life is roughly 5–6 hours, so a cup eight hours before bed still leaves about
    /// a quarter of it circulating at lights-out. Eight hours is the common recommendation and the
    /// one Ultrahuman's adenosine window is built on.
    static let caffeineCutoffHoursBeforeBed: Double = 8
    /// Late meals raise core temperature and delay sleep onset; three hours is the usual advice.
    static let lastMealHoursBeforeBed: Double = 3
    /// Long enough to matter, short enough that people will actually do it.
    static let windDownHoursBeforeBed: Double = 1
    /// Light lands hardest on the clock soon after waking.
    static let morningLightHoursAfterWake: Double = 2

    /// Builds the windows for the day containing `now`.
    ///
    /// Bedtime is placed on **tonight**: a baseline bedtime of 23:00 means tonight's 23:00, and one of
    /// 00:30 means tomorrow's. Everything is then counted back from there, so the caffeine cutoff for
    /// someone who sleeps at 00:30 lands at 16:30 today rather than yesterday afternoon.
    static func build(
        from baseline: CircadianBaseline, now: Date = Date(), calendar: Calendar = .current
    ) -> CircadianWindows? {
        guard baseline.isEstablished else { return nil }
        let startOfToday = calendar.startOfDay(for: now)

        // Both offsets are measured against the midnight *ending* today, so both are placed the same
        // way: `startOfToday + 24 h + offset`.
        //
        // That single expression is what makes the two sides of midnight agree. A −60 (23:00)
        // bedtime lands on tonight at 23:00; a +30 (00:30) bedtime lands on tomorrow at 00:30 —
        // which is still *tonight's* sleep. Placing a positive offset on today instead would put the
        // caffeine cutoff for a 00:30 sleeper at 16:30 yesterday.
        func placedTonight(_ minutesFromMidnight: Double) -> Date {
            startOfToday.addingTimeInterval((24 * 60 + minutesFromMidnight) * 60)
        }

        let bedtime = placedTonight(baseline.bedtimeMinutesFromMidnight)
        // Wake follows the bedtime it belongs to, so push it a day on if it landed before.
        let wakeCandidate = placedTonight(baseline.wakeMinutesFromMidnight)
        let usualWake = wakeCandidate > bedtime
            ? wakeCandidate
            : wakeCandidate.addingTimeInterval(24 * 3600)

        return CircadianWindows(
            caffeineCutoff: bedtime.addingTimeInterval(-caffeineCutoffHoursBeforeBed * 3600),
            lastMealBy: bedtime.addingTimeInterval(-lastMealHoursBeforeBed * 3600),
            windDownFrom: bedtime.addingTimeInterval(-windDownHoursBeforeBed * 3600),
            // Counted from *this* morning's wake, which is a day before tonight's bedtime.
            morningLightBy: usualWake.addingTimeInterval((morningLightHoursAfterWake - 24) * 3600),
            usualBedtime: bedtime,
            usualWake: usualWake.addingTimeInterval(-24 * 3600)
        )
    }

    /// The windows in display order, with the label and a one-line reason for each.
    func entries() -> [Entry] {
        [
            Entry(kind: .morningLight, time: morningLightBy),
            Entry(kind: .caffeine, time: caffeineCutoff),
            Entry(kind: .lastMeal, time: lastMealBy),
            Entry(kind: .windDown, time: windDownFrom),
        ]
    }

    struct Entry: Equatable, Identifiable {
        let kind: Kind
        let time: Date
        var id: String { kind.rawValue }
    }

    enum Kind: String, CaseIterable {
        case morningLight
        case caffeine
        case lastMeal
        case windDown

        var title: String {
            switch self {
            case .morningLight: return "Get light by"
            case .caffeine: return "Last coffee by"
            case .lastMeal: return "Finish eating by"
            case .windDown: return "Wind down from"
            }
        }

        var reason: String {
            switch self {
            case .morningLight:
                return "Light within a couple of hours of waking is what anchors your body clock to the day."
            case .caffeine:
                return "Caffeine's half-life is about 5–6 hours, so a late cup is still working at lights-out."
            case .lastMeal:
                return "Eating late raises core temperature, which pushes sleep onset back."
            case .windDown:
                return "An hour of lower light and lower stimulation before bed shortens how long you take to drop off."
            }
        }

        var symbol: String {
            switch self {
            case .morningLight: return "sun.max"
            case .caffeine: return "cup.and.saucer"
            case .lastMeal: return "fork.knife"
            case .windDown: return "moon.stars"
            }
        }
    }
}
