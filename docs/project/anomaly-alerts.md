---
title: Proactive anomaly alerts
description: Every pattern PulseLoop will interrupt you for — the exact signal, threshold, and gates behind each one.
---

# Proactive anomaly alerts

Most of what PulseLoop tells you, you asked for. Anomaly alerts are the exception: they arrive
unprompted, so the bar for firing one is deliberately high.

This page documents every detector — the signal, the threshold, and every gate. PulseLoop's
principles commit to "documented metrics and an auditable coach, no black boxes", and an alert you
can't inspect is indistinguishable from a guess.

!!! info "Off by default"
    Proactive alerts are opt-in (**Settings → Notifications**) and only run when the coach is set to
    Apple's on-device model, so an alert never triggers a paid cloud call on a background data event.

The implementation is [`CoachAnomalyDetector.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Coach/Notifications/CoachAnomalyDetector.swift),
covered by unit tests that lock every number on this page.

## Rules that apply to all alerts

- **At most one alert per detection pass.** When several patterns trip at once, the highest-priority
  one wins — see [Precedence](#precedence).
- **At most one alert per kind per day**, deduped on `anomaly:<kind>` in `CoachNotificationRecord`.
- **A missed alert beats a false alarm.** Every threshold below is set so that noise stays silent,
  accepting that some genuine events go unremarked.
- **No alert diagnoses anything.** Copy describes what was measured and offers a benign next step.

## The detectors

### 1. Low blood oxygen — `lowSpO2`

| | |
|---|---|
| **Signal** | Lowest SpO₂ reading in the last 12 hours |
| **Fires when** | `min(SpO₂) < 90%` |
| **Gates** | At least 3 readings in the window |
| **Rings** | Any with an SpO₂ sensor |

The multi-reading gate exists because a single low sample is far more often a finger moving against
the sensor than genuine desaturation.

### 2. Short sleep — `poorSleep`

| | |
|---|---|
| **Signal** | Last night's total sleep |
| **Fires when** | `0 < totalMinutes < 300` (under 5 hours) |
| **Gates** | A sleep session exists for the night |
| **Rings** | Any with sleep tracking |

The 5-hour cut is absolute rather than relative to your sleep goal: the message is about a night
short enough to matter physiologically, not about missing a target you set.

### 3. Resting heart-rate drift — `restingHRDrift`

| | |
|---|---|
| **Signal** | Last night's resting HR vs. your learned 30-day baseline |
| **Fires when** | `lastNight − baseline ≥ 5 bpm` |
| **Gates** | Baseline established · ≥ 10 overnight samples · night no more than 2 days old |
| **Rings** | Any with heart rate — every supported family |

#### How both numbers are computed

Both sides use the **10th percentile** of heart-rate samples, interpolated. Using one definition for
both is the whole point: comparing a night's *mean* against a 30-day *percentile* would produce a
difference that is mostly an artefact of the two formulas.

```
baseline   = p10( HR samples over the last 30 days )   # RestingHRBaselineService
lastNight  = p10( HR samples between sleep start and sleep end )
drift      = lastNight − baseline
```

The night is bounded by the **sleep session itself**, not a fixed clock window, so a late night or a
shift worker's schedule is measured over the hours actually slept.

#### Why 5 bpm

An elevated resting heart rate is the signal that moves first under infection, alcohol, heat, and
under-recovery — typically about a day before you notice anything. Five bpm is the usual
consumer-wearable threshold: below it, the night-to-night noise in an optical ring's overnight
sampling swamps the effect.

#### Why only upward

A resting HR *below* baseline is usually good news — improving fitness, or a genuinely restful
night — and is not something to interrupt anyone about.

#### Why the sample floor is 10

A YCBT-family ring floors its all-day measurement interval at 30 minutes, so a full night yields
roughly 14 samples; a Colmi at the default 5-minute cadence yields roughly 84. Ten keeps the
detector usable on both while still refusing to call a handful of readings a resting heart rate.

#### Why the baseline can be missing

`RestingHRBaselineService` stores `nil` until it has **≥ 20 samples spanning ≥ 7 days**. Until then
there is nothing trustworthy to compare against and this detector stays silent — it does not fall
back to a population average.

### 4. Health Watch — `healthWatch`

| | |
|---|---|
| **Signal** | Five overnight signals, each against its own 30-day baseline |
| **Fires when** | The night scores **major** (see below) |
| **Gates** | At least 2 signals had an established baseline |
| **Rings** | Any — it uses whichever signals your ring can produce |

PulseLoop's equivalent of Oura's Symptom Radar or Ultrahuman's Sleep Screener. **It never names a
condition, and the copy names the mundane explanations first** — alcohol, a warm room, and a hard
session the day before all look identical to the early hours of an infection.

#### The signals, and their direction

Only the side that indicates strain counts. A resting HR below baseline, an HRV above it, or a
cooler night are not warning signs, and flagging them would turn good news into an alert.

| Signal | Direction | Notable | Strong |
|---|---|---|---|
| Skin temperature | above baseline | +0.5 °C | +1.0 °C |
| Resting heart rate | above baseline | +5 bpm | +10 bpm |
| HRV | below baseline | −15 % | −30 % |
| Breathing rate | above baseline | +2 brpm | +4 brpm |
| Blood oxygen | below baseline | −2 pts | −4 pts |

HRV's knots are proportional rather than absolute because HRV spans roughly an order of magnitude
across healthy adults; the rest are absolute steps.

#### Scoring

Each signal scores 0 (normal), 1 (notable) or 2 (strong). The night's total decides:

| Total | Status | Alert? |
|---|---|---|
| 0–1 | No signs of strain | — |
| 2 | Minor signs | No — card and coach only |
| ≥ 3 | Major signs | Yes |

**A single notable signal never counts.** One reading nudging past its knot is a warm duvet or one
restless hour; the whole point of a multi-signal detector is that it waits for agreement. A single
*strong* signal scores 2 and lands at minor — a full degree of overnight temperature rise is not
noise, but it is not enough to interrupt for on its own either.

**Only `major` fires an alert.** Minor means two signals nudged past their knots, which happens after
a glass of wine often enough that alerting on it would train you to dismiss the ones that matter.

#### How the values and baselines are built

Both are measured **over the night itself**, bounded by the sleep session rather than a fixed clock
window — so a late night or a shift schedule is measured over the hours actually slept.

- Heart rate uses the **10th percentile** of the night, matching how the long-run resting baseline is
  built, so the two are the same quantity. Every other signal uses the night's mean.
- A baseline is the **median of the preceding nights' figures** — not a mean of every sample. One
  night the ring recorded four times as often as usual would otherwise dominate a raw sample mean,
  and a single feverish night would drag the very baseline it needs to be judged against.
- A baseline needs **7 nights**; a night's figure needs **6 readings** (a YCBT ring floors its
  interval at 30 minutes, so a full night is only ~14 samples there).

#### On the Today screen

The card is **conditional**: a clear night renders nothing at all. A permanent "all clear" tile would
be clutter on an already-dense grid, and would train people to stop reading it.

## Precedence

`detect` returns at most one anomaly, checked in this order:

1. `lowSpO2` — the most clinically meaningful of the four.
2. `poorSleep` — fires right after a sleep download, when it is most actionable.
3. `healthWatch`.
4. `restingHRDrift`.

Sleep outranks the two baseline detectors because a short or broken night usually raises resting HR
as well — when both trip, the sleep alert names the cause while the others would restate its
consequence.

Health Watch outranks resting-HR drift because **drift is one of its own signals**. When both trip,
the multi-signal result is strictly the better-corroborated message about the same night, and firing
the single-signal one instead would understate what was actually seen. Drift still fires on its own
when resting HR moved and nothing corroborated it — or when it was the only signal with a baseline
at all, which a ring with fewer sensors reaches while Health Watch is still short of two.

## What is deliberately not a detector

- **Temperature deviation on its own**, and **HRV drops on their own.** Both are real illness
  signals, but each is far too noisy alone — a warm room moves temperature, and HRV swings
  night-to-night in healthy people. They belong inside Health Watch, where they only speak when
  something else agrees, and that is where they now live.
- **Anything resembling a diagnosis.** No detector names a condition, and none ever will on
  wellness-grade optical hardware. Health Watch reports that signals moved together and lists the
  ordinary explanations first.
