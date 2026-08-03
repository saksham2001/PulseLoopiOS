---
title: Readiness score
description: How PulseLoop computes your daily readiness score — every contributor, weight, and threshold, documented.
---

# Readiness score

Readiness answers one question each morning: **how recovered are you today?** It is a single
number from 0 to 100, computed entirely on your device from data your ring already collects.

This page documents the whole algorithm. That is deliberate — PulseLoop's principles commit to
"documented metrics and an auditable coach, no black boxes", and a recovery score you can't
inspect is exactly the thing competitors charge a subscription for.

The implementation lives in [`ReadinessScore.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/ReadinessScore.swift)
(pure maths) and [`ReadinessService.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/ReadinessService.swift)
(reading your data). Both are covered by unit tests that lock every number on this page.

## Bands

| Score | Band |
|---|---|
| 85–100 | Primed |
| 70–84 | Ready |
| 55–69 | Moderate |
| 0–54 | Rest needed |

## Contributors

Five signals, worth 100 points between them. Four are judged against **your own baseline**, not
against a population average — what counts as a good HRV for you is not what counts as a good HRV
for anyone else.

| Contributor | Points | What's measured | Compared against |
|---|---|---|---|
| HRV | 30 | Mean HRV across the night (ms) | Your 30-day overnight median |
| Resting heart rate | 25 | The night's 10th-percentile HR (bpm) | Your learned resting-HR baseline |
| Sleep | 30 | Your sleep score for that night (0–100) | Absolute |
| Skin temperature | 10 | Mean skin temperature across the night (°C) | Your 30-day overnight median |
| Training load | 5 | Yesterday's active/workout minutes | Your trailing 7-day average |

Sleep is the one absolute contributor, because the [sleep score](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Services/SleepInsights.swift)
already encodes population-normal ranges for duration and stage balance. Scoring it against a
personal baseline as well would double-count the same normalisation.

### Thresholds

Each contributor earns full points at or better than **ideal**, 55% of its points at **soft**, and
zero at or beyond **hard**, interpolating linearly between those knots.

| Contributor | ideal | soft | hard |
|---|---|---|---|
| HRV | at or above baseline | 15% below | 40% below |
| Resting heart rate | at or below baseline | 5 bpm above | 12 bpm above |
| Sleep | score ≥ 88 | score 65 | score 30 |
| Skin temperature | within 0.2 °C | 0.6 °C off | 1.2 °C off |
| Training load | ≤ 1.2× your usual | 1.8× | 3.0× |

Two deliberate asymmetries:

- **HRV above your baseline and resting HR below it are never penalised.** Some recovery models
  treat an unusually high HRV as a warning sign (parasympathetic overshoot). That isn't
  falsifiable from a consumer ring, so PulseLoop doesn't guess.
- **Skin temperature is symmetric.** A deviation in either direction is a signal, so the score
  uses the absolute difference.

The 55% knee is harsher than the sleep score's 65%. A recovery score that never drops below 65
tells you nothing on the days you most need it to.

## Missing data is never scored as zero

This is the most important rule in the algorithm.

If your ring didn't capture a signal last night, that signal is **removed from the denominator**
rather than scored as zero:

```
score = 100 × (points earned) ÷ (points available)
```

So a night where skin temperature is missing is scored out of 90 points, not penalised 10. The
score also reports its **coverage** — what fraction of the full 100-point picture it was based on —
so a 78 from a partial night is never silently presented as equivalent to a 78 from a complete one.

A score is only produced when **at least 50 points are available** *and* at least one of HRV or
sleep is present. Resting heart rate and temperature qualify recovery; they don't describe it.

What that means per device:

| Situation | Available | Result |
|---|---|---|
| Colmi, all baselines established | 100 | Full-fidelity score |
| Colmi, no temperature reading that night | 90 | Scored, coverage 0.90 |
| Ring with sleep + HR but no HRV | 55 | Scored, coverage 0.55 |
| Any ring in its first week | < 50 | "Learning your baseline" |
| Ring with neither HRV nor sleep | — | No readiness tile at all |

## Baselines

A deviation is only meaningful once there's something to deviate from. PulseLoop reuses the
existing `BaselineStats` machinery, which considers a baseline established after roughly **a week
of wear with at least 20 samples**.

Until then the contributor is treated as **missing, not as "at baseline"** — scoring a deviation
against three days of data would look authoritative while being noise.

| Baseline | Window | Notes |
|---|---|---|
| HRV | 30 days of overnight readings | Excludes the night being scored |
| Skin temperature | 30 days of overnight readings | Excludes the night being scored |
| Resting heart rate | Learned separately, 30-day 10th percentile | Shared with the auto heart-rate zones |
| Training load | Trailing 7 days | Needs ≥ 4 days of history; excludes the day being judged |

Every baseline window **excludes the day it is judging**. Otherwise a night would be partly
averaged into its own baseline and could never deviate from it.

## The overnight window

Daytime readings describe what you were doing, not how you recovered, so every overnight signal is
read from the night itself:

- **Normally**: the span of that night's sleep session — which is resolved to the *longest* session
  of the day, so a nap is never mistaken for the night.
- **If sleep wasn't decoded**: a fixed 22:00–08:00 window. A ring that captured HRV and heart rate
  overnight but failed the sleep decode should still produce a score.

Resting heart rate uses the night's 10th percentile rather than its mean — the same statistic the
baseline it's compared against uses, so the two are like for like.

## Training load

Yesterday's load is the **larger** of the day's active minutes and its recorded workout time —
never their sum. A tracked run usually also generates active minutes, and adding them would
double-count the same hour of effort. Workout time excludes any paused periods.

## Storage and versioning

Each morning's score is stored with its full contributor breakdown, so history keeps its *why* and
the trend chart doesn't recompute months of data on every render. Recomputing an old morning
against today's baseline would produce a different — and wrong — answer.

Every stored row records the `algorithmVersion` that produced it. Changing any weight or threshold
on this page requires bumping that version, which invalidates stored rows so they recompute,
rather than silently reinterpreting old scores under new rules.

Readiness scores are included in the full-data JSON export (format version 2 and later).

## Known limitations

Stated plainly, because the point of this page is that you can judge the number for yourself:

- **The resting-HR baseline is an all-day 10th percentile**, not an overnight-only one. It's
  dominated by sleep values in practice — your lowest heart rate of the day *is* during sleep — and
  reusing it avoids a second baseline pipeline. An overnight-only variant is a candidate refinement.
- **The weights are informed judgement, not a validated clinical model.** They're documented here
  precisely so they can be argued with and improved.
- **Training load is a blunt instrument** at 5 points: minutes only, with no notion of intensity.
  A proper training-load model is separate roadmap work.
