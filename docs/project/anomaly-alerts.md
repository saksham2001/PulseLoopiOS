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

## Precedence

`detect` returns at most one anomaly, checked in this order:

1. `lowSpO2` — the most clinically meaningful of the three.
2. `poorSleep` — fires right after a sleep download, when it is most actionable.
3. `restingHRDrift`.

Drift is last **by design**. A short or broken night usually raises resting HR as well, so when both
trip, the sleep alert names the cause while drift would only restate its consequence. This is a
choice between two messages about the same night, not a suppressed alert.

## What is deliberately not a detector

- **Temperature deviation.** Ring skin temperature is a strong illness signal, but not every
  supported ring has the sensor, and a single-signal temperature alert produces too many false
  alarms from a warm room or a duvet. It belongs in a multi-signal detector, not on its own.
- **HRV drops.** HRV is noisy enough night-to-night that a single-night drop is usually not a
  signal, and it moves for the same reasons resting HR does — so an HRV alert would mostly
  double-report drift.
- **Anything resembling a diagnosis.** No detector names a condition, and none ever will on
  wellness-grade optical hardware.
