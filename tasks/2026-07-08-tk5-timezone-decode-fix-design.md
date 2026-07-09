# TK5 timestamp timezone-decode fix

## Problem

The TK5 ring has no timezone concept. `TK5Encoder.setTime` (`TK5Encoder.swift:10-17`) sets the
ring's clock by sending raw **local** wall-clock fields (year/month/day/hour/minute/second, via
`Calendar.current.dateComponents`) with no timezone byte — the ring just starts ticking forward in
real seconds from whatever instant those fields describe.

`TK5Bytes.date(_:)` (`TK5Protocol.swift:136-139`) decodes the ring's reported seconds by adding a
fixed **UTC**-anchored 2000-01-01 epoch offset and nothing else:

```swift
static func date(_ ringSeconds: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(ringSeconds) + epochOffset)
}
```

Tracing a full encode → tick → decode round trip (with `off` = the device's UTC offset in
seconds, e.g. `-14400` for Eastern Daylight Time):

- Encode at true absolute instant `T0`: the ring is handed local wall-clock fields equal to the
  components of `T0` in local time. Internally the ring stores this as a naive "seconds since
  2000" counter: `ringCounter(T0) = (T0 + off) - epoch2000`.
- The ring's counter ticks in real seconds, so at a later true instant `T1`:
  `ringCounter(T1) = T1 + off - epoch2000`.
- Current decode: `Date(timeIntervalSince1970: ringCounter(T1) + epoch2000) = T1 + off` — an
  absolute instant that is off by a full UTC-offset from the true `T1`.
- When the app then asks `Calendar.current` for local components of that decoded `Date`, the
  offset is applied **again**, so the displayed/derived local time is `trueLocalTime + off` —
  double-counting the offset instead of cancelling it.

Concretely, for a device in Eastern time (`off = -4h` in EDT), a true ~10pm local bedtime decodes
as if it were 6pm. That lands on the wrong side of `Calendar.wakingDay(forSleepStart:)`'s 7pm
day-boundary check (`PulseServices.swift:552-556`), filing the sleep session under *yesterday's*
date instead of today's. The Sleep page's day view requires an exact date match
(`SleepService.sleepRange`, anchor via `dayReferenceNight`) and shows nothing; the Home page's
`SleepService.latestSleep` tolerates sessions up to a day stale and still shows it — which matches
the reported symptom (visible on Home, missing from the Sleep page for that night).

The same `TK5Bytes.date` helper decodes every other TK5 history timestamp too (HR history, BP,
per-day step totals), so the same shift silently affects those, just less visibly than the sharp
day-boundary cutoff sleep sessions hit.

## Fix

Compensate for the offset in `TK5Bytes.date(_:)` by **subtracting** the timezone offset after
adding the epoch (the derivation above shows subtracting — not adding — recovers the true
instant). Add a `timeZone: TimeZone = .current` parameter for testability, matching the existing
`TK5Encoder.setTime(_:calendar:)` convention elsewhere in this codebase:

```swift
static func date(_ ringSeconds: Int, timeZone: TimeZone = .current) -> Date {
    let offset = TimeInterval(timeZone.secondsFromGMT())
    return Date(timeIntervalSince1970: TimeInterval(ringSeconds) + epochOffset - offset)
}
```

Fix the symmetric (currently unused) `ringSeconds(_:)` the same way, for consistency:

```swift
static func ringSeconds(_ date: Date, timeZone: TimeZone = .current) -> Int {
    let offset = TimeInterval(timeZone.secondsFromGMT(for: date))
    return Int(date.timeIntervalSince1970 - epochOffset + offset)
}
```

**Out of scope / untouched:**
- `TK5Encoder.setTime` — it's a faithful capture replay of the ring's expected format; the bug is
  purely in how we decode the ring's response, not in what we send.
- `Calendar.wakingDay(forSleepStart:)` / `SleepService.dayReferenceNight` — already correct; they
  were being fed a mis-decoded `Date`.
- Any change to Colmi/jring decoding — they don't use `TK5Bytes.date` and aren't affected.
- The periodic-resync / `RingSyncCoordinator` gap discussed alongside this bug — tracked
  separately for a distinct branch aimed at an upstream PR, since it applies to all three ring
  types rather than being TK5-specific.

## Testing

Add a unit test in `TK5DecoderTests.swift` that decodes a known `ringSeconds` value under an
explicit non-UTC `TimeZone` (e.g. `America/New_York`, not `.current`, so the test is deterministic
regardless of the CI runner's local timezone) and asserts the recovered local wall-clock time
matches what `TK5Encoder.setTime` would have sent for that same instant — i.e. an encode → decode
round trip through both fixed helpers.

Existing `TK5DecoderTests` are unaffected: none of them currently assert on the decoded `timestamp`
field of a `RingDecodedEvent`, only on the accompanying value (bpm, steps, SpO2, etc.), so this
fix changes no existing test's expected output.

## Non-goals

This spec does not cover the general ring periodic-resync gap (Colmi/jring/TK5 all only refresh
history on connect / manual sync / pull-to-refresh) — that's being designed separately for a
branch intended as an upstream contribution, kept distinct from this TK5-specific correctness fix.
