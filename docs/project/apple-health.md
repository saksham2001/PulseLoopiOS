---
title: Apple Health
description: What PulseLoop writes to Apple Health, what it reads back, and why the two directions can never loop.
---

# Apple Health

PulseLoop talks to Apple Health in both directions, and they are **separate opt-ins**:

- **Export** — mirror your ring's data into Health, so other apps can see it.
- **Import** — read data other apps and devices wrote, so PulseLoop can see it.

Bundling them under one switch would make one of them implicit. "Show my ring data elsewhere" and
"let other apps' data into mine" are different decisions with different privacy weight.

Both default **off**. Nothing moves in either direction until you say so.

## Export

Written when enabled, each with its own toggle:

| PulseLoop | HealthKit type |
|---|---|
| Heart rate | `heartRate` |
| Blood oxygen | `oxygenSaturation` |
| HRV | `heartRateVariabilitySDNN` |
| Skin temperature | `bodyTemperature`¹ |
| Respiratory rate | `respiratoryRate` |
| Cardio fitness | `vo2Max` |
| Blood glucose | `bloodGlucose` |
| Blood pressure | `bloodPressure` **correlation**² |
| Sleep stages | `sleepAnalysis` |
| Steps / energy / distance | the matching quantity types |
| Workouts | `HKWorkout` + `HKWorkoutRoute` |
| Meals | dietary energy + macros |

¹ Apple's wrist-temperature type is read-only to third parties, so skin temperature is written as
body temperature.

² Health only recognises a blood-pressure *reading* when systolic and diastolic are saved together
inside an `HKCorrelation`. Saved separately they are stored but never surface — which looks exactly
like a silent failure.

Rows for a metric only appear as a toggle if your ring can actually produce it.

### What is never exported

**Stress and fatigue.** HealthKit has no type for a device-derived wellness score. `HKStateOfMind`
(iOS 17) is a self-reported mood log; writing a ring's 0–100 number into it would misrepresent both.
This isn't a follow-up — there is nothing to map them onto.

Exports are idempotent: every sample carries a deterministic `HKMetadataKeySyncIdentifier`, so
re-running a pass replaces rather than duplicates.

## Import

Read when enabled:

| Source | Becomes |
|---|---|
| `bloodGlucose` | Measurements tagged as coming from Health — this is how **CGM** data arrives |
| `bodyMass` | Your profile weight |

A continuous glucose monitor writes to Health; PulseLoop reads it; from then on it sits in the same
store the coach already queries, beside your ring's sleep and heart rate. Oura's whole
metabolic-health feature is this same read.

Body mass updates the **profile** rather than becoming a measurement row, because that is where the
rest of the app reads weight from (the calorie model, BMI). A second home for it would let the two
disagree.

### What is deliberately not imported

**Steps and workouts.** Both would double-count against what the ring already records — Health's
step count includes the iPhone's own pedometer, and a ring-recorded workout that PulseLoop exported
would come back as a second session. Merging those needs provenance-aware reconciliation that this
doesn't have, so it doesn't pretend to.

## Why the two directions can't loop

This is the invariant that matters most here, and it is enforced on **both** sides.

PulseLoop exports glucose *and* imports it. Left unguarded, one reading would go round forever:
import a CGM value → export it as ours → import it back → export again.

1. **The import excludes this app's own `HKSource`.** Anything PulseLoop wrote to Health is filtered
   out of every read.
2. **Imported rows carry `MeasurementSource.appleHealth`**, and the export path's predicate excludes
   that source. So even if a row somehow arrived, it could never be published back out as if the
   ring had measured it.

Either guard alone would close the loop; both are in place because they fail differently, and a test
pins each.

## Dedup

Imported readings are keyed on **(kind, instant, imported)** — the same rule every other history path
in the app uses. A CGM that revises a reading in place updates the existing row rather than stacking a
second one beside it, and an unchanged re-import writes nothing at all.

An import never edits a *ring* row at the same instant. Those are two different claims about one
moment, and the ring's own reading isn't something an import may overwrite.

## Watermarks

Export and import keep **separate** high-water maps. Clearing one never disturbs the other — a full
re-export must not also re-import a year of glucose.
