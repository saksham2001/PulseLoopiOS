---
title: HRV detail
description: The HRV panel — SDNN, RMSSD, pNN50 and LF/HF — where each value comes from, how it is computed, which rings have it, and what PulseLoop deliberately refuses to show.
---

# HRV detail

Every supported ring reports a single **HRV** number. Some also report the panel behind it: the
standard time- and frequency-domain measures that number is summarising.

That panel is what this page documents. It is worth noting that **neither Oura nor Ultrahuman
surfaces it** — both show one HRV figure — so on the right hardware a $20 ring gives you strictly
more autonomic detail than a $349 one.

The decoder is
[`YCBTHealthRecords.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/RingProtocol/YCBTHealthRecords.swift)
and the screen is
[`AutonomicDetailView.swift`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/Views/AutonomicDetailView.swift).
Both are covered by tests that lock every number on this page.

## Where to find it

**Vitals → HRV → HRV detail.**

Deliberately two taps in, and deliberately not on Today or Vitals as cards. These are numbers you
read occasionally to understand a trend, not ones you glance at — six more dashboard tiles would
bury the metrics people actually open the app for. The panel's `MeasurementKind`s have no
`MetricKey`, which is what makes a dashboard card structurally impossible rather than merely
absent today.

## Which rings have it

| Family | HRV scalar | HRV panel |
|---|---|---|
| jring / 56ff | ✅ | ❌ — no body-data record exists |
| Colmi / Yawell (QRing) | ✅ | ❌ — no body-data record exists |
| LuckRing / TK18 | ✅ | ❌ — no body-data record exists |
| Colmi / Yawell (SmartHealth) | ❔ per ring | ❔ per ring |
| TK5 | ❔ per ring | ❔ per ring |
| R10M / LittleMeatball | ❔ per ring | ❔ per ring |

The panel lives entirely in the YCBT **body-data record** (`05 33`), so only the three YCBT
families can produce it at all — and among those it is claimed **per ring**, not per family.

### The gate

`WearableCapability.hrvDetail` rides **`IS_HAS_PRESSURE` (byte 22, bit 6)** of the ring's own
`02 01` capability bitmap. That is the bit the vendor SDK gates the entire `05 33` query on:

```java
if (YCBTClient.isSupportFunction(FunctionConstant.IS_HAS_PRESSURE)) {
    arrayList.add(DATATYPE.Health_History_Body_Data);
}
```

A ring with that bit clear is never asked for the record, so it can no more produce SDNN than it
can produce a stress score — which is why the panel is claimed and withheld together with
`.stress` and `.fatigue`, the two other fields of that same record.

!!! note "Why not `ISHASHRV`?"
    Byte 1 bit 6 governs the **scalar**, which arrives from a different record (`05 09`) and from
    the `06 03` live stream. A ring can have HRV and still have no body-data record to break it
    down, so the panel needs its own capability rather than riding `.hrv`.

The real **R99** (firmware 2.32) is the worked example: byte 22 is `0x20` — bit 5, not bit 6 — and
it NAKs `05 33` outright, so it gets the scalar and no panel.

## The metrics

Byte offsets are within the 28-byte body-data record (`DataUnpack` case 51); `u16` is
little-endian.

| Metric | Offset | Unit | Plausible range | What it is |
|---|---|---|---|---|
| **RMSSD** | `u16` @18 | ms | 1–500 | Root mean square of successive beat-interval differences. The measure most tied to rest and recovery — it tracks parasympathetic ("rest and digest") activity and falls after hard training, alcohol, or a poor night. |
| **SDNN** | `u16` @14 | ms | 1–500 | Standard deviation of beat intervals across the window. Captures slower rhythms than RMSSD, so it moves more with recording length than with any single night. |
| **pNN50** | `u8` @17 | % | 0–100 | Share of consecutive beats differing by more than 50 ms. Moves with RMSSD; another read on parasympathetic activity. |
| **LF power** | `u16` @20 | ms² | 0–50 000 | Power in the low-frequency band. Often called sympathetic, but it reflects a mix including blood-pressure regulation. |
| **HF power** | `u16` @22 | ms² | 0–50 000 | Power in the high-frequency band, driven largely by breathing. Rises with slow, deep breathing and restful sleep. |
| **LF/HF** | *derived* | ratio | 0.01–20 | Balance between the two bands. Commonly read as stress-versus-recovery, though that reading is debated. |

Ranges are enforced in
[`RingEventBridge`](https://github.com/saksham2001/PulseLoopiOS/blob/main/PulseLoop/RingProtocol/RingEventBridge.swift)
before anything is persisted. They are misframe guards, not physiological claims — a value outside
them indicates a misdecoded record, since a ring replays its whole log on every sync and one bad
record would otherwise re-persist forever.

Zero means **absent**, not measured-as-zero: `0` is the ring's "no sample" filler across the whole
panel.

### LF/HF is computed, not read

The record carries its own `lfHf` at **@24** — and PulseLoop ignores it.

It is a single byte standing in for a ratio whose real range is roughly 0.5–3, so it must carry an
implicit scale factor, and the SDK never states one. Rather than guess, the ratio is recomputed:

```
LF/HF = lfPower / hfPower
```

Whatever common scale LF and HF share **cancels in the quotient**, so the derived ratio is correct
even though the absolute powers' unit is inferred.

The captured hardware record the tests are built on confirms the approach: @24 reads `0x0d` = 13,
i.e. 1.3 at a ÷10 scale, against a derived 1200 ÷ 900 = **1.33**. The two agree — which is also
the corroboration that every offset in the table above is right, since a misread would put these
values in the thousands or at zero rather than in ordinary adult resting ranges.

## No zone colouring, and why

Unlike heart rate or SpO₂, these have no population-normal band worth drawing. RMSSD alone spans
roughly an order of magnitude across healthy adults and shifts with age, fitness, posture and
recording length. Painting a green/amber/red band on that would be inventing a threshold — exactly
the black box this project exists to avoid.

Read them as trends against your own history.

## Not exported to Apple Health

HealthKit models HRV as one type, `heartRateVariabilitySDNN`, and has nothing for RMSSD, pNN50 or
spectral power. The one that could map — SDNN — is already occupied by the ring's HRV scalar, and
whether that scalar simply *is* the ring's SDNN is unverified. Exporting both would either
double-report one measurement or silently disagree with itself, so the panel stays in-app until a
hardware session settles which is which.

## What we deliberately do not surface

The same records carry several other fields. They are decoded past, not accidentally missed:

| Field | Where | Why not |
|---|---|---|
| **Load index** | `05 33` @4–5 | Vendor-proprietary composite. No stated scale, no unit, no published definition — nothing to check it against. |
| **Sympathetic tone** | `05 33` @12–13 | Same: a proprietary index, not a standard measure. |
| **Body fat** | `05 09` @15–16 | The ring has no bioimpedance sensor. Any figure here is derived from the profile you typed in, not measured. |
| **Uric acid** | `05 2F` @7–9 | No optical ring can measure uric acid. |
| **Blood ketones** | `05 2F` @10–12 | No optical ring can measure ketones. |
| **Blood lipids** | `05 2F`, four fractions | No optical ring can measure a lipid panel. |

The bottom four are the reason this section exists. Surfacing them would make the app look more
capable and would be straightforwardly dishonest — the hardware cannot measure them, whatever the
firmware reports. (The same reasoning is already applied to the jring's "blood sugar", which is a
profile-derived estimate and is labelled as one everywhere it appears.)

The top two are a softer call: they are real outputs of a real algorithm, but with no definition
to hold them to, showing them would be reporting a number rather than a metric. If the vendor
scale is ever pinned down, they can join the panel.
