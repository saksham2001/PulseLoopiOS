import XCTest
@testable import PulseLoop

/// Covers the split between date strings that are **keys** (`DateFormatter.stableKey`) and date
/// strings the **user reads** (`DateFormatter.localizedTemplate`).
///
/// Both directions are invisible on a default US device, so they need pinning rather than eyeballing:
/// a key that follows the device calendar silently stops matching stored keys, and a display string
/// that ignores the device clock silently shows 12-hour time to a 24-hour user.
final class DateFormattingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Keys stay Gregorian

    /// The exact regression: a formatter that inherits a non-Gregorian calendar renders 2026 as the
    /// Buddhist year 2569, so the key stops matching every key written before the setting changed.
    /// `stableKey` must be immune to that.
    func testStableKeyIgnoresANonGregorianCalendar() {
        let august1st2026 = date(2026, 8, 1)

        // What the old code produced on a Thai device, reproduced explicitly so the test doesn't
        // depend on ICU's default calendar for any particular locale.
        let deviceCalendarFormatter = DateFormatter()
        deviceCalendarFormatter.locale = Locale(identifier: "th_TH")
        deviceCalendarFormatter.calendar = Calendar(identifier: .buddhist)
        deviceCalendarFormatter.timeZone = utc
        deviceCalendarFormatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(deviceCalendarFormatter.string(from: august1st2026), "2569-08-01",
                       "Precondition: a Buddhist-calendar formatter renders a different year")

        XCTAssertEqual(DateFormatter.stableKey("yyyy-MM-dd", timeZone: utc).string(from: august1st2026),
                       "2026-08-01")
    }

    /// Keys must also sort chronologically as plain strings, which a two-era mix would break.
    func testStableKeysSortChronologicallyAsStrings() {
        let formatter = DateFormatter.stableKey("yyyy-MM-dd", timeZone: utc)
        let keys = [date(2026, 8, 1), date(2025, 12, 31), date(2026, 1, 1)].map(formatter.string(from:))
        XCTAssertEqual(keys.sorted(), ["2025-12-31", "2026-01-01", "2026-08-01"])
    }

    @MainActor
    func testCoachDateStringsRoundTripThroughTheirOwnParser() {
        let noon = date(2026, 8, 1)
        let key = CoachDataAccess.localDateString(noon)
        XCTAssertEqual(key.count, 10, "Coach day keys are YYYY-MM-DD: \(key)")

        let parsed = CoachDataAccess.parseLocalDate(key)
        XCTAssertNotNil(parsed)
        // Parsing a day key yields that day's local midnight, which re-renders to the same key.
        XCTAssertEqual(CoachDataAccess.localDateString(parsed!), key)
    }

    func testNotificationDedupeKeyIsGregorian() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        XCTAssertEqual(CoachNotificationRecord.dateKey(for: date(2026, 8, 1), calendar: calendar), "2026-08-01")
    }

    func testShareCardFilenameCarriesAGregorianDate() {
        let filename = ShareCardRenderer.filename(activityLabel: "Trail Run", date: date(2026, 8, 1))
        XCTAssertTrue(filename.hasSuffix(".png"), filename)
        XCTAssertTrue(filename.contains("2026-08-"), "Expected a Gregorian year in \(filename)")
    }

    // MARK: - Display follows the device

    /// A hard-coded "h:mm a" showed 12-hour time to everyone. The template has to resolve per locale.
    func testLocalizedTemplateFollowsTheLocaleClock() {
        let evening = date(2026, 8, 1, hour: 21, minute: 30)

        let twelveHour = DateFormatter.localizedTemplate("jmm", locale: Locale(identifier: "en_US"))
        twelveHour.timeZone = utc
        let twelveHourText = twelveHour.string(from: evening)
        XCTAssertTrue(twelveHourText.contains("9:30"), twelveHourText)
        XCTAssertTrue(twelveHourText.uppercased().contains("PM"), twelveHourText)

        let twentyFourHour = DateFormatter.localizedTemplate("jmm", locale: Locale(identifier: "de_DE"))
        twentyFourHour.timeZone = utc
        let twentyFourHourText = twentyFourHour.string(from: evening)
        XCTAssertTrue(twentyFourHourText.contains("21:30"), twentyFourHourText)
        XCTAssertFalse(twentyFourHourText.uppercased().contains("PM"), twentyFourHourText)
    }

    func testUsesTwelveHourClockTracksTheLocale() {
        XCTAssertTrue(DateFormatter.usesTwelveHourClock(locale: Locale(identifier: "en_US")))
        XCTAssertFalse(DateFormatter.usesTwelveHourClock(locale: Locale(identifier: "de_DE")))
    }

    /// Sleep bed/wake times are the most visible clock text in the app.
    func testSleepClockTimeIsNotHardCodedToTwelveHour() {
        let formatted = SleepFormat.clockTime(date(2026, 8, 1, hour: 23, minute: 15))
        if DateFormatter.usesTwelveHourClock() {
            XCTAssertTrue(formatted.uppercased().contains("M"), formatted)
        } else {
            XCTAssertFalse(formatted.uppercased().contains("AM"), formatted)
            XCTAssertFalse(formatted.uppercased().contains("PM"), formatted)
        }
    }
}
