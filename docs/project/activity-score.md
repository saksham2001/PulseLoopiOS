---
title: Movement score & training load
description: How PulseLoop scores a day's movement and weighs this week's training against the last month — every contributor, weight, and threshold.
---

# Movement score & training load

Two numbers on the Activity tab, both computed on your device.

- The **movement score** answers "how well did I move today?" — PulseLoop's equivalent of Oura's
  Activity Score or Ultrahuman's Movement Index.
- **Training load** answers "is this week in line with my recent normal?"

Both are documented in full here. PulseLoop's principles commit to "documented metrics and an
auditable coach, no black boxes".

Implementations:
[`ActivityScore.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/ActivityScore.swift)
and
[`TrainingLoad.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/TrainingLoad.swift)
(pure maths), with
[`ActivityScoreService.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/ActivityScoreService.swift)
reading the store. Unit tests lock every number on this page.

---

## Movement score

**Algorithm version: 1.** Bands: Very active ≥ 85, Active ≥ 70, Light ≥ 45, Restful below.

### Contributors

| Contributor | Points | Measured against |
|---|---|---|
| Steps | 35 | Your daily step goal |
| Active minutes | 30 | Your daily active-minutes goal |
| Active energy | 20 | Your daily calorie-burn goal |
| Movement through the day | 15 | The hours your ring actually observed |

Everything is scored **against your own goals**, not a population target. The goals already exist
and are already editable in Settings; a score built on a fixed 10,000 steps would tell a marathoner
and someone recovering from surgery the same thing.

### The goal curve

```
fraction = actual ÷ goal

fraction ≥ 1.0   → full points
fraction = 0.6   → 65% of points
fraction = 0     → 0
```

…interpolating linearly between those knots.

**Exceeding a goal is never penalised.** Overreaching is what training load is for; a movement score
that docked you for a long hike would be actively misleading.

### Movement through the day

A day that hits its step goal in one gym session and then sits for twelve hours is a different day
from one that moves throughout, and this is the only contributor that can tell them apart.

An hour counts as active if it contains at least **250 steps** — the widely used stand-hour
convention rather than a threshold invented here. Only hours between **08:00 and 22:00** are
considered; nobody should be scored for not walking at 4 a.m.

The denominator is the hours your ring **actually reported buckets for**, not a flat 14. A ring taken
off at lunchtime isn't scored for the afternoon it never saw.

### Missing data is never scored as zero

A contributor with no data leaves the denominator rather than being scored as zero:

```
score = 100 × (points earned) ÷ (points available)
```

| Situation | Available | Why |
|---|---|---|
| Full day, ring reports intraday buckets | 100 | — |
| Ring-history day (no trustworthy calories) | 80 | `ActivityDaily.calories` is blanked for ring-history rows |
| Ring reports only daily totals | 85 | No intraday buckets to judge regularity from |
| Both of the above | 65 | — |

A score is only produced when **at least 50 points** were available.

The energy exclusion is deliberate and pre-existing: the ring's calorie field is unverified, so
`buildTodaySummary` already blanks it for ring-history days. Scoring it would put weight on a number
the app explicitly doesn't stand behind.

---

## Training load

### The model

**Edwards' summated heart-rate zones**, not Banister's TRIMP:

```
load = Σ (minutes in zone i × weight i)     weights: 1, 2, 3, 4, 5
```

Zone floors are fractions of maximum heart rate — 0%, 60%, 70%, 80%, 90% — the same boundaries the
workout summary screen already draws, so the two can never disagree. Maximum heart rate is the plain
`220 − age`, falling back to 190 when age is unknown.

Banister's TRIMP needs a reliable average heart rate over a bounded session. PulseLoop's all-day data
is sparse, irregularly spaced, and has no session boundaries, so Edwards — which only needs time in
each zone — degrades far more gracefully.

The result is **unitless**: a weighted minute count, not an energy figure. A day of gentle walking
lands in the tens; a hard hour lands in the low hundreds.

### The gap cap

Each reading is credited the interval to the next one, capped at about twice the median spacing and
never more than five minutes.

Without that cap, two all-day readings twelve hours apart would be credited as twelve hours of
zone-1 work — turning an overnight sampling gap into the biggest session of the week. A ring sampling
every 5 minutes credits its full interval; a YCBT ring floored at 30 minutes credits five of each
thirty, which understates load rather than inventing it.

### Acute vs chronic

```
acute   = mean daily load over the last 7 days
chronic = mean daily load over the last 28 days
ratio   = acute ÷ chronic
```

| Ratio | Band |
|---|---|
| < 0.8 | Detraining |
| 0.8 – 1.3 | Steady |
| 1.3 – 1.5 | Building |
| > 1.5 | Spike |

These are the sports-science convention — roughly 0.8–1.3 is the range associated with lowest injury
risk in the literature. Presented as guidance, not a verdict: the evidence base is contested and was
built on athletes with far better data than an optical ring provides.

### Days with no data are excluded, not counted as rest

This is the most important rule here. A week the ring wasn't worn is **not** a week of recovery, and
averaging in zeros would manufacture a "detraining" reading out of a charging cable.

Both means are taken over the days that actually carried readings. A ratio is withheld entirely until
at least **14 of the 28 chronic days** have data — below that the chronic average is really a
short-window average wearing a long window's name, and dividing one by the other says nothing.

---

## Where they appear

Both live on the **Activity tab**, under the rings they summarise — not on Today, which is already a
dense tile grid. The contributor breakdown is disclosed on tap, so the card stays one line tall until
asked.

The card is absent entirely on a day with no activity row: there is nothing to score yet, and an
empty dial reads as a zero.
