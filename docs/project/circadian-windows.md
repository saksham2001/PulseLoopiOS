---
title: Circadian windows
description: When to stop caffeine, finish eating, wind down and get light — every offset and where it comes from.
---

# Circadian windows

Four times on the Sleep tab, hung off your own sleep schedule: when to stop caffeine, when to finish
eating, when to start winding down, and when to get light.

Ultrahuman's equivalent windows are one of the most-cited reasons people pick it over Oura. This is
the same idea, computed on your device from nights you already recorded.

Implementation:
[`CircadianWindows.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/CircadianWindows.swift).
Unit tests lock every offset and every midnight case.

## The windows

| Window | Offset | Why |
|---|---|---|
| Get light by | wake **+ 2 h** | Light lands hardest on the body clock soon after waking. |
| Last coffee by | bedtime **− 8 h** | Caffeine's half-life is ~5–6 h, so a cup 8 h before bed still leaves roughly a quarter circulating at lights-out. |
| Finish eating by | bedtime **− 3 h** | Late meals raise core temperature, which pushes sleep onset back. |
| Wind down from | bedtime **− 1 h** | Long enough to matter, short enough that people actually do it. |

## Anchored on your sleep, not on sunrise

Ultrahuman derives its windows from solar times, which needs your location. PulseLoop doesn't, for
two reasons:

1. **Privacy.** The project's principles keep data on the device and location optional. Requiring
   coordinates to show four times would be a poor trade.
2. **It's what the advice actually says.** The circadian guidance these windows encode is already
   phrased relative to your own sleep — "get bright light within an hour or two of waking", not "at
   sunrise". Someone who wakes at 13:00 still benefits from light at 13:00.

The consequence, stated plainly: **the light window cannot tell you whether it is actually light
outside.** It says when your body clock is most responsive to light, not when the sun is up. On a
dark winter morning that means a lamp, and the app can't know the difference.

A night-shift schedule — asleep at 09:00, awake at 17:00 — produces a coherent set of windows for
exactly this reason, where a sunrise-based one would produce nonsense.

## Learning your schedule

The anchor is a **median bedtime and wake time over your last 14 nights**, needing at least 7.

- Days are collapsed first so each contributes one bedtime and one wake.
- Only sessions of **3 hours or more** count. A 20-minute afternoon nap's start and end are not a
  schedule, and would otherwise drag both medians.
- Medians, not means, so one very late night doesn't move your usual.
- Times are averaged on an axis **wrapped around midnight**, so a 23:40 and a 00:20 bedtime average
  to midnight rather than to noon.

Nothing renders until the schedule is established — no window is shown built on three nights.

## The midnight case

Both offsets are measured against the midnight *ending* today, so both are placed identically:

```
time = startOfToday + 24 h + offsetMinutes
```

That one expression is what makes the two sides of midnight agree. A −60 (23:00) bedtime lands on
tonight at 23:00; a +30 (00:30) bedtime lands on tomorrow at 00:30 — which is still *tonight's*
sleep. Placing a positive offset on today instead would put the caffeine cutoff for a 00:30 sleeper
at 16:30 **yesterday**, which is the bug the tests were written to catch (and did).

## Where it appears

The **Sleep** tab, under the night it was learned from — not Today, which is already a dense grid.
Only on today's view: yesterday's page shows the night, not tomorrow's plan.

Each window's reason is disclosed on tap. Four bare times with no explanation would be instructions
rather than guidance, and these are guidance — general rules of thumb applied to your schedule, not
findings from your data.
