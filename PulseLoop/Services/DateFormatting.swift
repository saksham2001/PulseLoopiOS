import Foundation

// Two jobs that look identical at the call site and fail in opposite directions when confused.
// Both bugs below are invisible on a default US device, which is why they survived this long.

extension DateFormatter {
    /// A formatter for strings that are **identifiers, not display text**: coach summary scope keys,
    /// notification dedupe keys, export filenames, and the date arguments the coach emits and parses
    /// back.
    ///
    /// A `DateFormatter` takes its calendar from the user's locale. On a device set to the Buddhist
    /// or Japanese calendar (Settings → General → Language & Region → Calendar), `"yyyy-MM-dd"`
    /// renders 1 Aug 2026 as `2569-08-01` / `8-08-01`. For display that is correct and wanted; for a
    /// key it is a bug — the string stops matching keys written before the setting changed, stops
    /// sorting chronologically against them, and stops being a date the model can parse back.
    ///
    /// Pinning `en_US_POSIX` + Gregorian is the fix, and the combination `BatteryAlertMonitor` has
    /// always used for its own alert-dedupe key.
    ///
    /// `timeZone` defaults to the device's, matching the "local day" these keys have always meant.
    static func stableKey(_ format: String, timeZone: TimeZone = .current,
                          calendar: Calendar = Calendar(identifier: .gregorian)) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// A formatter for text the **user reads**, built from a locale template rather than a literal
    /// pattern.
    ///
    /// `"jmm"` resolves to `9:30 PM` or `21:30` according to the device's 24-Hour Time setting,
    /// where a hard-coded `"h:mm a"` forces 12-hour on everyone — including the large share of the
    /// world that has never used it. Templates also reorder fields per locale, so `"MMMd"` gives
    /// `Aug 1` or `1 Aug` as appropriate.
    ///
    /// Field *letters* still matter (`j` hour, `mm` minute, `MMM` abbreviated month); only their
    /// order and the 12/24-hour choice are handed to the locale.
    static func localizedTemplate(_ template: String, locale: Locale = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        // Must follow the locale assignment: the template is resolved against it.
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// Whether `locale` renders times on a 12-hour clock, and so has an AM/PM marker to place.
    ///
    /// Read from the locale's own resolution of the `j` ("locale-preferred hour") template — the
    /// same thing Settings → General → Date & Time → 24-Hour Time flips. Callers need this only when
    /// the *layout* depends on the marker existing; for plain formatting, `localizedTemplate("jmm")`
    /// already does the right thing on both.
    static func usesTwelveHourClock(locale: Locale = .current) -> Bool {
        (dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
    }
}
