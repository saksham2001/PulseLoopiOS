---
title: Sleep score
description: How PulseLoop scores a night — every contributor, weight, and threshold, documented.
---

# Sleep score

The sleep score answers one question: **how good was last night?** A single number from 0 to 100,
computed on your device from what your ring actually recorded.

This page documents the whole algorithm. PulseLoop's principles commit to "documented metrics and
an auditable coach, no black boxes", and a sleep score you can't inspect is exactly the thing
competitors charge a subscription for.

The implementation is
[`SleepInsights.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/SleepInsights.swift),
covered by unit tests that lock every number here. **Algorithm version: 2.**

## Bands

| Score | Label |
|---|---|
| 85–100 | Excellent |
| 70–84 | Good |
| 55–69 | Fair |
| 0–54 | Needs work |

## Contributors

Five signals, worth 100 points between them.

| Contributor | Points | What's measured |
|---|---|---|
| Duration | 30 | Total sleep time — time in bed minus minutes tagged awake |
| Deep sleep | 25 | Deep as a share of the night |
| REM sleep | 20 | REM as a share of the night |
| Restfulness | 15 | Share of the night spent awake |
| Bedtime consistency | 10 | How far tonight's bedtime sat from your own recent median |

### Thresholds

Each contributor earns full points inside its **ideal** band, 65% of its points at the **soft**
knot, and zero at or beyond **hard**, interpolating linearly between.

| Contributor | ideal | soft | hard |
|---|---|---|---|
| Duration | 7–9 h asleep | 6 h / 9.5 h | 4 h / 12 h |
| Deep sleep | 13–23% | 5% / 35% | 0% / 45% |
| REM sleep | 20–25% | 15% / 30% | 5% / 40% |

Restfulness and bedtime consistency use their own curves:

| Awake share | Points |
|---|---|
| ≤ 10% | full |
| 20% | 35% of full |
| ≥ 35% | zero |

| Bedtime drift | Points |
|---|---|
| ≤ 30 min | full |
| 60 min | 55% of full |
| ≥ 120 min | zero |

The 30-minute knot is where circadian-regularity research stops calling a schedule regular. Two
hours is roughly a timezone — by then it's a different night, not a late one.

## Missing data is never scored as zero

This is the most important rule in the algorithm.

If your ring can't produce a signal, that signal is **removed from the denominator** rather than
scored as zero:

```
score = 100 × (points earned) ÷ (points available)
```

The score also reports its **coverage** — what fraction of the full 100-point picture it rested on.

What that means per ring:

| Situation | Available | Result |
|---|---|---|
| REM-capable ring, a week of history | 100 | Full score |
| jring (no REM stage in its `0x11` timeline) | 80 | Scored out of 80 |
| First week of use (no bedtime baseline yet) | 90 | Scored out of 90 |
| jring, first week | 70 | Scored out of 70 |
| No usable wake signal | −15 | Restfulness withheld |

A score is only produced when **at least 50 points** were available; below that there isn't enough
of a night to describe.

This is what makes one number comparable across hardware: an ideal night scores the same on a jring
as on a Colmi, rather than the jring being permanently docked 20 points for a sensor it never had.

## What changed in v2

### Duration is now time asleep, not time in bed

`SleepSession.totalMinutes` is the wall-clock span — `SleepSegmentation` sets it from `end − start`.
v1 scored that directly, so a night with 8 hours in bed and 90 minutes awake was credited as 8 hours
of sleep. Awake minutes now come off the top.

On a ring with no usable wake signal there is nothing to subtract, so the whole span stands in — which
makes duration read slightly generous on that hardware. Stated here rather than left implicit.

### REM is scored

Both the Colmi big-data timeline (stage `0x04`) and the YCBT timeline (tag `3`) report REM, and both
decoders always stored it — but v1 never scored it, and told the coach no ring could see it.

### Light sleep is reported but no longer scored

Once deep and REM are both scored, light is their residual — scoring it too counts the same night
twice. Its v1 band (ideal 50–60%) was calibrated for a no-REM decoder that lumped REM minutes into
light, so on a REM-capable ring it was scoring the same night harshly for a split that was correct.

`lightPct` is still reported for display.

### Sleep efficiency is deliberately absent

Efficiency is total sleep time ÷ time in bed. Since `totalMinutes` **is** time in bed, that works out
to exactly `1 − awake %` — the restfulness contributor restated. Adding it would double-weight the
same signal while looking like a sixth independent one.

Oura can score both because it separates "total sleep time" from "time in bed" using data these rings
don't provide.

### Bedtime consistency is new

Computed from your own median bedtime over the previous 14 nights (needing at least 7), on a wrapped
axis centred on midnight — so a 23:40 and a 00:20 bedtime average to midnight rather than to noon.

Days are collapsed first so each contributes one bedtime: a collapsed day's start is the earliest of
its sessions, which is the night itself, since an afternoon nap starts later in the same waking day.

**The night being scored is excluded from its own baseline.** Including it would drag the median
toward it and forgive exactly the drift the contributor exists to notice.

## No migration was needed

The sleep score is not stored: the production sync path
(`PulseEventBus`, `SleepSegmentation`) creates every `SleepSession` with a nil score, and every
screen calls `SleepScore.calculate` live from the stage blocks. Only demo data and imported archives
carry a stored score.

So v2 took effect everywhere the moment it shipped, with no recompute pass. `algorithmVersion` is
still stamped on every result, so a future change that *does* need one has the hook already.
