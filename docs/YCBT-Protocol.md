---
title: YCBT protocol (TK5 · SmartHealth-Colmi)
description: >-
  Byte-level reference for the Yucheng YCBT ring protocol — framing, CRC, the
  health-history transfer, every record layout, and the commands PulseLoop sends.
  Shared by the TK5 and the SmartHealth-app Colmi rings.
---

# YCBT protocol (TK5 · SmartHealth-Colmi)

Byte-level wire reference for the **Yucheng YCBT** protocol — the language spoken by every ring whose
vendor app is **SmartHealth** (`com.zhuoting.healthyucheng`): the [TK5](hardware/tk5.md), and the
[Colmi units that ship with SmartHealth](hardware/colmi.md#smarthealth-app-colmi-rings) rather than
QRing.

This document is **device-neutral wherever the protocol is** — which is nearly everywhere. The frame
format, the history transfer, the record layouts and the command catalog are the same bytes on every
YCBT device; §0 is the whole of what a *family* gets to differ on.

## 0. The two families that speak it

PulseLoop drives two YCBT families, and the byte stream between them is **identical**. What differs is
only how a ring announces itself and which sensors it happens to carry:

| | TK5 | SmartHealth-Colmi |
|---|---|---|
| **Advertised name** | `TK5 <4 hex>` — unambiguous, so it auto-detects | a Colmi-line name (`R09_ABCD`, `COLMI R10_…`) — **collides with QRing-Colmi**, so the app *asks* (see below) |
| **Manufacturer data** | prefix `10786501` (captured) | expected to contain the `1078` product code; ⚠️ **no capture yet** |
| **SupportFunction bitmap** (`02 01`, §2) | **gates the per-SKU sensors** — temperature, BP (incl. on-demand), stress, fatigue, blood sugar. HRV is *not* gated: it was observed working on a TK5 (48 / 79 ms), and hardware evidence outranks a bit | **gates the per-SKU sensors** — temperature, BP (incl. on-demand), stress, blood sugar, **and HRV**, which the owner's R99 denies four ways |
| **chipScheme** (`02 1b`) | JieLi (3–5), inferred from the `AE00` service | ❓ unknown; only selects the OTA stack, which PulseLoop does not implement (§9) |
| **Support level** | 🧪 Limited | 🧪 Limited — never connected |

Nothing else. There is no per-family opcode, no per-family record layout, and no per-family framing.

**In the source**, that maps 1:1: the whole protocol lives in device-neutral
`PulseLoop/RingProtocol/YCBT*.swift` (`YCBTProtocol` · `YCBTEncoder` · `YCBTDecoder` · `YCBTDriver` ·
`YCBTHistoryTransfer` · `YCBTHealthRecords` · `YCBTSyncEngine`), and each family contributes exactly
one small **coordinator** — `TK5Coordinator.swift` and `ColmiSmartHealthCoordinator.swift` — carrying
its advertisement matcher and its capability set. A third YCBT family would be one more coordinator
and no protocol code at all.

**Why the Colmi one has to ask the user.** The Colmi line is sold with *either* firmware, and the
local name is set by the OEM, not by the app — so a QRing-Colmi and a SmartHealth-Colmi can advertise
the identical `R09_ABCD`. No advertisement-only rule can separate them, so the pairing screen asks
which app came with the ring and the answer — not the scan — picks the driver. See
[Colmi / Yawell](hardware/colmi.md#smarthealth-app-colmi-rings).

## Provenance

| Source | What it settles |
|---|---|
| **Decompiled vendor SDK** — `com.yucheng.ycbtsdk` (v4.0.10), shipped inside the SmartHealth Android app | Opcodes (`CMD.java`), 16-bit dataTypes (`Constants.java`), record parsing (`DataUnpack.java`), framing / send queue / history assembly (`YCBTClientImpl.java`). **Ground truth.** |
| **SmartHealth app layer** — `com.zhuoting.healthyucheng` | Which commands the app actually sends and in what order, the measurement-mode table (one per measure screen), and how a raw field is *displayed* (which is how the temperature and blood-sugar scales were pinned down) |
| **Original Android btsnoop HCI capture** (one TK5 session) | Advertisement identity, GATT topology, and a sanity check that the SDK's bytes are what the ring really sees |

The driver was originally reconstructed from that **single capture** alone. It is now built from the
SDK, with the capture used only for corroboration. Where a capture-derived assumption and the Java
disagreed, **the Java won** — every such case is called out below.

Anything still marked ⚠️ **UNVERIFIED** could not be substantiated from either source and is waiting
on an on-device checkpoint.

---

## 1. Transport

### 1.1 GATT topology *(captured on the TK5; a SmartHealth-Colmi is expected to expose the same characteristics — ⚠️ unconfirmed)*

| Role | UUID |
|---|---|
| Service | `be940000-7333-be46-b7ae-689e71722bd5` |
| Command | `be940001-…` — **write and indicate** (the app writes here *and* gets command replies here) |
| Stream | `be940003-…` — indicate: live vitals and all history data frames |

Both characteristics carry the same frame format; the decoder dispatches on the frame's group byte,
not on which characteristic it arrived on.

The ring also exposes the standard **`180D`/`2A37` Heart Rate** service. PulseLoop deliberately does
**not** subscribe to it: the TK5 emits a cached resting HR (~87 bpm) on it even when off the finger,
which would mask real readings. The vendor app ignores it too — live HR comes solely from the
proprietary `06 01` stream, which reflects actual finger contact.

### 1.2 MTU and fragmentation

The SDK requests an MTU of 500 and chunks at **`MTU − 3`** in both directions. A logical frame longer
than one ATT packet is therefore split across several notifications, and several short frames can
arrive in one notification.

**Reassembly is driven by the declared length field, never by notification boundaries**
(`YCBTFrameAssembler`). Treating one notification as one frame drops every history data frame — this
was one half of why TK5 history never landed.

### 1.3 Frame format

```
[TYPE:1] [CMD:1] [LEN:2 LE] [PAYLOAD:N] [CRC16:2 LE]
```

* **`LEN` is the *total* frame length**, including the 4-byte header and the 2-byte CRC — so
  `LEN = N + 6`, not the payload length.
* **CRC = CRC-16/CCITT-FALSE**: poly `0x1021`, init `0xFFFF`, **no** input/output reflection, **no**
  final XOR, computed over every byte before it, appended **little-endian**.
  Check value: `"123456789"` → `0x29B1`.
* A command's 16-bit `dataType` in the SDK is exactly `(TYPE << 8) | CMD` — e.g. `0x0580` is the
  Health terminal block.

Worked example — request heart-rate history (group `05`, key `06`, empty payload):

```
05 06 06 00 83 20
│  │  └──┴── LEN = 6 (0x0006 LE): 4 header + 0 payload + 2 CRC
│  └─────── CMD  = 0x06  (Health query key: heart rate)
└────────── TYPE = 0x05  (Health group)
            CRC-16/CCITT-FALSE over `05 06 06 00` = 0x2083 → little-endian `83 20`
```

The ring **does not validate the CRC of inbound command frames** (the SDK doesn't either), but it
*does* validate the inner CRC of a bulk history block — that one is load-bearing (§4).

### 1.4 Timestamps

`u32 LE`, **seconds since 2000-01-01**, in the ring's **local wall clock**. The ring has no timezone
concept: its RTC is set from local Y/M/D h:m:s fields and ticks in local time.

Decoding must therefore un-apply the device's UTC offset to recover the true instant, or a later
`Calendar.current` read re-applies the same offset and doubles it. This is exact for same-session
syncs, and can be an hour off across a DST transition that happens between recording and syncing.
(`YCBTBytes.date` / `.ringSeconds`, in `YCBTProtocol.swift`.)

### 1.5 Groups

The `TYPE` byte is the command group. Direction is a property of the group, and getting it wrong is
how the original driver ended up sending device→app opcodes:

| TYPE | Group | Direction | Purpose |
|---:|---|---|---|
| `0x01` | Setting | app → ring | clock, user profile, units, language, all-day monitors |
| `0x02` | Get | app → ring | device info, support bitmap, name, user config, chip scheme |
| `0x03` | AppControl | app → ring | live-measurement start/stop, live-status stream, find device |
| `0x04` | DevControl | **ring → app** | pushes: measurement progress/result, SOS, find-phone, sedentary |
| `0x05` | Health | both | history: queries, data frames, terminal block, ACK |
| `0x06` | Real | **ring → app** | realtime stream: HR, SpO₂, steps, vitals, battery, wear state |

Groups 4 and 6 are **device-originated**. The only `04 xx` frame an app may write is the mandatory
push ACK (§6); it never writes a `06 xx` at all.

---

## 2. Connect handshake (what PulseLoop sends)

In the SmartHealth app's own order (`HomeFragment.getCompile` → `syncSettingData`), rebuilt from the
SDK's definitions rather than replayed from the capture — every payload is derived from the user's
real settings (`YCBTEncoder.startupSequence`).

| # | Frame | Meaning |
|---:|---|---|
| 1 | `01 00` `[year:u16][mon][day][hh][mm][ss][weekday]` | Set clock. **Weekday is Mon = 0 … Sun = 6.** |
| 2 | `02 00` `47 43` | GetDeviceInfo → battery + firmware come back in the reply |
| 3 | `02 01` `47 46` | GetSupportFunction → capability bitmap. The reply is a bit-per-feature map (`ISHASTEMP`, `ISHASBLOOD` = blood *pressure*, `IS_HAS_PRESSURE` = *stress* — and, on that same bit, *fatigue*: it gates the whole `05 33` body-data query the two scores share) parsed by `YCBTSupportFunction`. It can only **add** capabilities a family has pre-approved, never remove one — which is how **both** YCBT families claim their per-SKU sensors (§0) |
| 4 | `02 1b` | GetChipScheme (JieLi vs Nordic vs Realtek — selects the OTA stack; see §8) |
| 5 | `02 03` `47 50` | GetDeviceName |
| 6 | `02 07` `43 46` | GetUserConfig |
| 7 | `01 12` `[languageCode]` | Language (0 = English) |
| 8 | `01 04` `[dist][weight][temp][timeFmt][sugar][uric]` | Units — 0 = metric each; `timeFmt` is **1 for 12-hour** |
| 9 | five `01 xx` `{enable, intervalMin}` | The all-day monitors (§3) |
| 10 | `01 03` `[heightCm][weightKg][sex][age]` | User profile — the ring feeds this into its step/calorie/BP algorithms |
| 11 | `03 09` `01 00 02` | Enable the ring's continuous `06 00` live-status push |

The two-byte tags on the Get frames (`47 43`, `47 46`, …) are cosmetic — the firmware ignores a Get's
payload — but PulseLoop keeps the app's exact bytes so a byte-diff against a capture stays clean.

The history queries (§4) follow, driven by the transfer state machine, not by this list.

---

## 3. Setting group (`0x01`) — the all-day monitors

**These five commands — not any Health-group opcode — are what make the ring record anything between
syncs.** Each takes `{enable, intervalMinutes}`.

| Frame | Monitor |
|---|---|
| `01 0c` `{en, interval}` | Heart rate |
| `01 1c` `{en, interval}` | Blood pressure |
| `01 20` `{en, interval}` | Temperature |
| `01 26` `{en, interval}` | Blood oxygen |
| `01 45` `{en, interval, 0, 0, 0}` | HRV — ⚠️ the trailing three bytes are **UNVERIFIED**; the SDK names only the first two arguments, so they are zero-filled |

**Interval is clamped to ≥ 30 minutes** — the ring's sampler rejects anything faster, and SmartHealth
clamps identically (`if (isRing() && interval < 30) interval = 30`). Vendor default is 60.

Other Setting keys used: `01 00` set time, `01 03` user info, `01 04` units, `01 12` language.

PulseLoop has no all-day *blood-pressure* toggle of its own (no other ring family has one), and the
ring derives BP from the same PPG sweep as heart rate, so `01 1c` rides the HR enable.

---

## 4. Health group (`0x05`) — the history transfer

The whole point of the protocol, and the part the original driver got wrong end to end. One transfer
per record type, strictly sequential: **the ring will not release the next type until the previous
one is acknowledged.**

### 4.1 The sequence

```
app  → 05 <queryKey>                     empty payload — "give me everything you have of this type"
ring → 05 <queryKey>  [recordCount:u16][totalPackets:u32][totalBytes:u32]     (header, payload ≥ 10 B)
ring → 05 <ackKey>    <data>             ×N — payloads CONCATENATE into one buffer
ring → 05 80          [totalPackets:u16][totalBytes:u16][crc16:u16]           (terminal, payload = 6 B)
app  → 05 80          {00}               MANDATORY ACK — 00 = CRC matched, 04 = mismatch
```

Four rules that are easy to get wrong:

1. **The query key and the data key are different.** Heart rate is *queried* with `0x06` and its data
   frames come back on `0x15`. The full table is in §4.3.
2. **The data payloads concatenate.** Records are packed back-to-back into one logical stream and
   then chopped wherever a frame boundary happens to fall, so a record routinely **straddles two
   frames**. Decoding per-frame silently drops every straddling record and misaligns everything
   after it. `DataUnpack.unpackHealthData` is likewise handed one buffer, not one frame.
3. **The terminal CRC is over the reassembled buffer**, not over any frame — same CRC-16/CCITT-FALSE.
4. **The ACK is mandatory and comes first.** `YCBTClientImpl.packetHealthHandle` writes the ACK
   *before* it parses a single record, so a slow decode can never stall the ring. PulseLoop does the
   same. Without the ACK, the ring simply never answers the next query.

A header payload of **≤ 9 bytes means "nothing stored for this type"** — there is no transfer, so
there is nothing to ACK; move on to the next type.

### 4.2 Byte-level example — heart-rate history

```
app  → 05 06 06 00 83 20                             query heart rate
ring → 05 06 10 00  2c 00  06 00 00 00  08 01 00 00  de 7b
                    │      │            └── totalBytes   = 0x108 = 264   (= 44 × 6-byte records)
                    │      └─────────────── totalPackets = 6
                    └────────────────────── recordCount  = 0x2c = 44
ring → 05 15 …data…                                  ×6, payloads concatenate → 264-byte buffer
ring → 05 80 0c 00  06 00  08 01  34 12  7c 49       terminal: 6 packets, 264 bytes, crc16 = 0x1234
app  → 05 80 07 00 00 f3 6a                          ACK, CRC matched  (mismatch → …04 → 77 2a)
```

Then the next query goes out. On a CRC mismatch PulseLoop ACKs `{04}` and re-requests the type
**once**; a second failure drops the type rather than looping the ring forever.

### 4.3 Record types

Query key → ack key → record stride. All nine are requested on connect; a ring that doesn't
implement one answers with a no-data header or a `0xFC` error, both of which skip cleanly — so
querying the full catalog costs nothing.

| Type | Query | Ack | Stride | PulseLoop decodes |
|---|---:|---:|---:|---|
| Sport (activity buckets) | `0x02` | `0x11` | 14 | steps, distance |
| Sleep | `0x04` | `0x13` | *variable* | deep / light / REM / awake timeline |
| Heart rate | `0x06` | `0x15` | 6 | HR |
| Blood pressure | `0x08` | `0x17` | 8 | systolic, diastolic, HR |
| **All** (combined vitals) | `0x09` | `0x18` | 20 | steps, BP, SpO₂, resp. rate, HRV, temp, blood sugar |
| SpO₂ | `0x1A` | `0x22` | 6 | SpO₂ |
| Temperature | `0x1E` | `0x26` | 7 | temperature |
| Comprehensive (metabolic) | `0x2F` | `0x30` | 44 | blood sugar |
| Body data | `0x33` | `0x34` | 28 | HRV, stress, fatigue, VO₂max |

Queried in ascending key order. **Sport before All matters**: sport records are additive buckets that
*assign* a past day's step total, while the All record's step field is a cumulative counter that only
ratchets it up — asking in this order lets the counter have the last word.

Types the SDK can request that PulseLoop deliberately does **not** (no PulseLoop metric maps onto
them): sport-mode workouts `0x2D`, fall `0x29`, health-monitoring `0x2B`, sedentary `0x37`, ambient
light `0x20`, temp+humidity `0x1C`, location `0x35`, power on/off `0x76`.

### 4.4 Record layouts

Offsets are within one record. Every record starts with a `u32 LE` 2000-epoch local timestamp.

**Sport — `0x02`, 14 bytes** (`DataUnpack` case 2)

| @ | Field |
|---:|---|
| 0 | `start:u32` |
| 4 | `end:u32` |
| 8 | `steps:u16` |
| 10 | `distanceMeters:u16` |
| 12 | `calories:u16` |

Interval buckets (each covers start→end), not a running total. ⚠️ **UNVERIFIED**: whether they
partition the whole day or only cover workouts, and whether distance is really metres.

**Sleep — `0x04`, variable** (`DataUnpack` case 4)

Back-to-back **sessions**, each a 20-byte header followed by 8-byte stage segments:

```
header:   [flags:2] [recordLen:u16 @2] [start:u32 @4] [end:u32 @8] [counts/totals @12…19]
              recordLen = the whole session's byte count, INCLUDING this header
segment:  [tag:1] [segStart:u32 LE @1] [durationSeconds:u24 LE @5]
```

* The duration is **u24**, not u16 — a u16 read truncates any segment longer than 18h12m.
* Stage is **`tag & 0x0F`**: 1 = deep, 2 = light, 3 = REM, 4 = awake, 5 = nap. The high nibble is a
  flag mask, so exact-matching the tag byte (`0xF1…0xF4`) is wrong.
* An **unknown tag must be skipped, never terminal**. Breaking out of the segment loop on one lets a
  single nap segment (`0xF5`) truncate the rest of the night.
* The "`af fa` magic" in the older notes was never a magic number: bytes [0] and [1] are unused flag
  bytes and `recordLen` is at [2..3].
* The SDK's segment loop has **no bounds check** against the buffer length (only against `recordLen`)
  and would run off the end of a truncated transfer. PulseLoop clamps to the bytes it actually holds.

**Heart rate — `0x06`, 6 bytes** (case 6) · `[ts:u32][mode@4][hr@5]` — `hr == 0` is an unworn sample.

**Blood pressure — `0x08`, 8 bytes** (case 8) · `[ts:u32][isInflated@4][systolic@5][diastolic@6][hr@7]`

**All / combined vitals — `0x09`, 20 bytes** (case 9)

| @ | Field | | @ | Field |
|---:|---|---|---:|---|
| 0 | `ts:u32` | | 11 | `hrv` |
| 4 | `steps:u16` — **cumulative daily counter** | | 12 | `cvrr` (not decoded) |
| 6 | `heartRate` | | 13–14 | `tempInt`, `tempFrac` |
| 7 | `systolic` | | 15–16 | `bodyFatInt`, `bodyFatFrac` (no metric) |
| 8 | `diastolic` | | 17 | `bloodSugar` |
| 9 | `spo2` | | | |
| 10 | `respiratoryRate` | | | |

HR at @6 is not emitted — the heart-rate history carries the same samples at the same epochs.

**SpO₂ — `0x1A`, 6 bytes** (case 26) · `[ts:u32][type@4][value@5]` — `type` = auto-sampled vs. manual
spot reading; PulseLoop stores both the same way.

**Temperature — `0x1E`, 7 bytes** (case 30) · `[ts:u32][type@4][int@5][frac@6]`. Note the SDK's own
bounds check demands only 5 bytes while the loop advances 7 — it would read out of bounds on a short
tail; PulseLoop's stride-7 slicer drops it.

**Comprehensive — `0x2F`, 44 bytes** (case 47) · `[ts:u32][bloodSugarModel@4][int@5][frac@6]`, then
uric acid (@7–9), ketones (@10–12) and four lipid fractions. Only blood sugar has a PulseLoop metric.

**Body data — `0x33`, 28 bytes** (case 51)

| @ | Field | | @ | Field |
|---:|---|---|---:|---|
| 0 | `ts:u32` | | 14 | `sdnn:u16` |
| 4–5 | load index (int/frac) | | 16 | `vo2max` |
| 6–7 | **HRV** (int/frac) | | 17 | `pnn50` |
| 8–9 | **stress** — the SDK's `pressure` | | 18 | `rmssd:u16` |
| 10–11 | **fatigue** — the SDK's `body` | | 20 / 22 | `lf:u16` / `hf:u16` |
| 12–13 | sympathetic tone | | 24 | `lfHf` |

This record is the proof that the ring **stores** stress and fatigue rather than the app deriving
them from HRV (`BodyData.getPressureValue()` / `getBodyStateValue()` are what the SmartHealth UI
labels "stress" and "fatigue").

### 4.5 Three scaling rules that are not what they look like

**Int/fraction pairs are STRING-CONCATENATED, not `int + frac/10` or `/100`.** The SDK does
`Float.parseFloat(int + "." + frac)` (`DataUnpack` case 30, `BodyData.calculateCompositeValue`, and
SmartHealth's temperature screen). So the fraction's scale is implied by its *digit count*:
`frac = 5` → `.5`, `frac = 50` → `.5`, `frac = 25` → `.25`. Reproducing that exactly is the only way
to land on the number the vendor app shows for the same bytes. Applies to **temperature and HRV**.

**Stress and fatigue are the exception: the app shows them ×10, on a 1…100 scale.** Both UI surfaces
do it — the history list reads `BodyData.getCompositePressure()` = `Integer.parseInt(int + "" + frac)`
and the live screen reads `(int)(Float.parseFloat(int + "." + frac) * 10)`
(`PressureMeasureActivity:66`) — and both then filter to `TransUtils.PRESSURE_VISIBLE_MIN/MAX` = 1…100.
The ring therefore scores 0–10 with one decimal: bytes `(5, 3)` are the **53** SmartHealth puts on
screen, not 5.3. HRV in the same record is *not* one of these — it is milliseconds (the All record
carries the same quantity as one whole byte, and the app's own HRV range is 1…180), so `(45, 6)` is
45.6 ms, not 456. ⚠️ **Fatigue is inferred**: SmartHealth never renders it, so its scale is taken from
stress, whose byte pair is adjacent and identically shaped.

A temperature record with `int == 0` **or `frac == 15`** is the ring's **"never measured" filler**.
The captured All records carry `tempInt = 0, tempFrac = 15`, but SmartHealth's chart drops on the
fraction *independently of the integer* (`TemperatureActivity`: `int <= 42 && int >= 33 && frac != 15`)
— so a record left with a stale integer (`36, 15`) is a filler too, and would otherwise decode to a
36.15 °C reading that no plausibility range can catch.

**Blood sugar is in TENTHS of mmol/L**, not whole mmol/L. SmartHealth stores the comprehensive
record's value as `integer * 10 + fraction` and the All record's *single byte* into the **same** DB
column, then filters that column to 11…333 — whose float twins are 1.1 and 33.3 mmol/L. So a raw 55
is 5.5 mmol/L ≈ 99 mg/dL. PulseLoop persists mg/dL, so it converts `raw / 10 × 18.016`.
⚠️ **UNVERIFIED**: no captured record carried a non-zero value; the scale is inferred from the app's
DB column and chart filter, not from observed bytes.

---

## 5. Realtime group (`0x06`) — ring → app stream

Arrives unprompted on the stream characteristic. Never ACKed.

| Frame | Payload | PulseLoop |
|---|---|---|
| `06 00` | `[steps:u16][distance:u16][calories:u16]` — cumulative day totals | steps verified against the capture; ⚠️ distance/calories offsets **UNVERIFIED** (capture-inferred) |
| `06 01` | `[bpm]` | live HR (verified) |
| `06 02` | `[spo2]` | live SpO₂, from the mode-`0x02` red/IR sweep |
| `06 03` | `[SBP@0][DBP@1][hr@2][hrv@3][spo2@4][tempInt@5][tempFrac@6]` | **one fixed layout** — the live feed for *both* the BP and the HRV sweep |
| `06 13` | `[ts:u32][worn]` | wear state — ⚠️ **UNVERIFIED polarity** (nonzero taken as worn); debug feed only |
| `06 15` | `[chargingStatus][percent]` | battery push — keeps battery fresh without polling `02 00` |

`06 03` was previously decoded with a "BP-vs-HRV shape heuristic". There are no two shapes: the BP
screen and the HRV screen in SmartHealth both subscribe to this one dataType and each reads its own
fixed offsets. In BP mode the ring fills @0/@1 and zeroes @3; in HRV mode the reverse. Emitting each
field iff it carries a value decodes both cases *and* recovers the HR that the BP sweep also
measures, which the heuristic was throwing away.

### 5.1 Starting a live measurement — `03 2f {enable, mode}`

The **mode byte selects the sensor/LED**. One mode runs at a time.

| Mode | Metric | Streams back on |
|---:|---|---|
| `0x00` | Heart rate (green LED) | `06 01` |
| `0x01` | Blood pressure | `06 03` |
| `0x02` | SpO₂ (red/IR LED) | `06 02` |
| `0x03` | Respiratory rate | — |
| `0x04` | Temperature | — |
| `0x05` | Blood sugar | — |
| `0x06` / `0x07` / `0x09` | Uric acid / ketone / blood fat | — |
| `0x0A` | HRV | `06 03` |
| `0x0C` | Stress | — |

**The stop echoes its own mode — it is not `{0x00, 0x00}`.** Every SmartHealth measure screen passes
its own type in *both* directions (`BaseMeasureActivity.playStopMeasure` → `appStartMeasurement(type, …)`).
The capture's `03 2f 00 00` was simply the HR screen's stop with mode 0. Stopping an SpO₂ sweep with
mode 0 tells the ring to stop *heart rate* — which is exactly the bug this replaced.

```
03 2f 08 00 01 00  4f 1b     start HR
03 2f 08 00 00 00  7e 28     stop  HR
03 2f 08 00 01 02  0d 3b     start SpO₂   (stop = …00 02)
```

**The ring answers a start with a verdict — one status byte, and no mode.** `0x00` = started; anything
else is the firmware declining. The SDK never names the code (`packetAppControlHandle` falls through to
`onDataResponse(bArr[last], …)`), and because the reply doesn't echo the mode, the only way to know
*which* measurement was refused is to remember the start you sent — which is what `YCBTDriver` does,
handing the mode to the decoder so it can emit `.measurementRejected(mode:)`.

The owner's R99 (firmware 2.32) is why this matters: it has no HRV sensor and says so four ways — a
clear `ISHASHRV` bit, `0xFC` on the HRV monitor (`01 45`), `0xFC` on the body-data history (`05 33`),
and here:

```
app  → 03 2f 08 00 01 0a          start HRV
ring → 03 2f 07 00 01             status 0x01 — refused
```

Treating that as an ordinary ack is what made PulseLoop poll a ring that had already said no for the
full 45-second measurement window before giving a generic failure. Observed timings for the sweeps it
*does* run, start frame → value, all on the same ring: **HR ~19 s · SpO₂ 38 s · BP ~12 s** (which is why
the SpO₂ window is 60 s and not 40 s — 38 s was landing inside a 40 s window by two seconds).

### 5.2 Other AppControl commands PulseLoop sends

```
03 09 09 00 01 00 02  a0 de     enable the continuous 06 00 live-status push (…00 00 02 disables)
03 00 09 00 01 05 02  b7 69     find device — make the ring buzz
```

⚠️ **UNVERIFIED**: the find-device arguments. `appFindDevice(i2, i3, i4)` sends its three arguments
verbatim and the SDK never names them; `{1, 5, 2}` is what SmartHealth's own "find ring" button
passes. First suspect if the ring doesn't buzz.

---

## 6. DevControl group (`0x04`) — the push ACK contract

Group 4 is **ring → app**. The ring **retransmits a push until the app acknowledges it**, so:

> **Every non-error `04 <key>` frame must be answered with `04 <key> {00}` — before it is decoded.**

`YCBTClientImpl.packetDevControlHandle` sends `sendData2Device(dataType, {0})` *before* it parses the
payload, and PulseLoop does the same: a slow decode must never be able to stall the ring.

```
ring → 04 13 …                    measurement status push
app  → 04 13 07 00 00  e1 9d      ACK
```

| Key | Push | PulseLoop |
|---:|---|---|
| `0x00` | Find phone | ACK + log (no product surface) |
| `0x05` / `0x17` | SOS / SOS with GPS | ACK + log |
| `0x0E` | **MeasurementResult** — `[measureType][result]`; 1 = success, 2 = failed, else cancelled | ACK + log. **Carries no measured value** — SmartHealth reacts to a success by re-reading *history*, which is where the reading actually lands |
| `0x13` | **MeasurementStatus** (1043) — `[type][state]` then that type's value; `type` is the same mode byte from `03 2f` | ACK + decode the reading. ⚠️ the `state` byte has no enum anywhere in the SDK, so it is ignored |
| `0x16` | Sedentary reminder | ACK + log |

Two deliberate divergences from the SDK:

* **Error frames are never ACKed.** A 1-byte `0xFB…0xFF` payload is a rejection, not a push (§7). The
  SDK returns early for groups 4 and 6 on one, before the push handler runs. ACKing it would answer a
  rejection as though it were a push.
* **PulseLoop ACKs *every* non-error key**, where the SDK only ACKs the keys in its own table. An
  unrecognised push still needs its retransmissions stopped — that is the entire point of the ACK —
  and an ACK for a key the ring never pushed is inert.

The historical `04 0e 00` "bond nudge" in the capture was never a command: it was SmartHealth
*auto-ACKing a MeasurementResult push*. Replaying it on connect did nothing.

---

## 7. Error frames

Any group, any command: a **1-byte response payload in `0xFB…0xFF`** is a status, not data
(`YCBTClientImpl.isError`). It must be checked *before* any offset is read, because a 1-byte error
payload is otherwise indistinguishable from a short header.

| Byte | Meaning | Handling |
|---:|---|---|
| `0xFB` | Unsupported command (group not implemented) | history: skip the type **and stop asking for it this session** |
| `0xFC` | Unsupported key (cmd not implemented on this firmware) | same — this is how an absent sensor announces itself |
| `0xFD` | Length error | history: skip the type, advance |
| `0xFE` | Data error | skip, advance |
| `0xFF` | CRC error | skip, advance |

---

## 8. Never send these

| Bytes | What they actually are |
|---|---|
| **`05 40` … `05 4E`** | The Health **DELETE** opcodes. PulseLoop used to send `05 40/42/43/44/4E` believing they enabled monitoring. **They erase the ring's stored history.** The real enables are the five `01 xx` monitors (§3). |
| **`02 24` / `02 26` / `02 28`** | `GetCardInfo` / `GetSleepStatus` / `GetMeasurementFunction` — not history queries. The real history path is §4. |
| **Anything on the `AE00` service** | JieLi RCSP (§9). Not part of the health protocol. |
| Any `04 xx` other than the push ACK | Group 4 is device→app. The only legitimate app write is `04 <key> {00}`. |
| Any `06 xx` | Group 6 is device→app, full stop. |

---

## 9. The AE00 service — JieLi RCSP, deliberately not implemented

The ring exposes a second service, `0000ae00` (write `ae01`, notify `ae02`), on which the capture
showed an encrypted `FE DC BA …` / `02 "pass"` handshake. It looked like a login gating the health
data. **It is not.**

It is **JieLi RCSP** — the chipset vendor's own challenge-response auth, a subsystem entirely
separate from the Yucheng health protocol (`com/jieli/jl_rcsp/impl/RcspAuth.java`,
`YCBT…/p060jl/WatchManager.java`):

* `FE DC BA` is the JieLi RCSP frame magic; `02 "pass"` is `RcspAuth.getAuthOkData()`.
* It is **gated on the chip scheme** (`02 1b` → 3/4/5 = JieLi) and it authorizes the **JieLi feature
  set only: OTA / firmware update, watch-face (dial) upload, and log extraction.**
* The YC health commands on `be940001` are **plaintext, CRC-framed and carry no auth of any kind** —
  they are an independent code path in the SDK. Bind/unbind at the YC layer
  (`AppControl.BindDevice = 6`) are ordinary plaintext commands, not cryptographic.
* The key and algorithm are **native**: `getEncryptedAuthData()` is a `native` method inside
  `libjl_rcsp.so`, with no Java implementation. It is not recoverable from the decompile.

**PulseLoop implements none of it, and never will unless OTA is in scope.** Since PulseLoop does not
do firmware updates or watch faces, there is nothing behind that handshake it wants.

The one residual risk, stated honestly: the SDK proves the two paths are *independent*, but it cannot
prove a given **firmware** doesn't refuse YC commands until RCSP auth completes. The capture showed
plaintext health traffic with no AE00 exchange, so the evidence points the right way — but a ring
that NAKs every `05 xx` until `02 "pass"` would be a documented hard stop. This is the top item on
the on-device checkpoint.

---

## 10. Where PulseLoop deliberately diverges from SmartHealth

| | SmartHealth | PulseLoop |
|---|---|---|
| **After a sync** | Deletes the records off the ring (`05 40…4E`) so the next sync is small | **Never deletes.** The ring replays its entire log on every sync. |
| **Deduplication** | Implicit — the ring forgets what was uploaded | **App-side upsert on `(kind, timestamp)`.** A history sample re-persists onto the same row; a re-sync is idempotent. |
| **Activity totals** | — | Sport buckets upsert by start epoch (day = sum of distinct buckets); the All record's cumulative counter is a per-day `max` ratchet. Both are idempotent under replay. |

Not deleting is the safer trade: a delete that races a failed decode destroys data that exists
nowhere else, and it makes the vendor app and PulseLoop mutually destructive on the same ring. The
cost is a longer sync as the ring's log fills.

**History horizon.** `RingEventBridge` drops any history sample, sleep session or activity timestamp
outside a **~8-day window** (`now − 8 days … now + 1 hour`). A ring's log can hold records stamped
under a *previous* clock — which decode hours or days out of place — and because history rows upsert,
one misdecoded record doesn't merely flicker: it re-persists on every future sync. Every decoded
metric is additionally **range-gated per kind** in the bridge (the record decoders only drop the
ring's "no sample" fillers; the plausible ranges live in exactly one place), so a misdecode is
dropped rather than stored as garbage.

---

## 11. Open questions for the on-device checkpoint

Everything marked ⚠️ above, in priority order:

1. **AE00 gating** — do `05 xx` queries answer before any RCSP auth? (§9)
2. **Blood-sugar scale** — cross-check one non-zero reading against SmartHealth. (§4.5)
3. **Temperature scale** — confirm a real reading lands at ~36.x °C under the string-concat rule.
4. **Stress / fatigue magnitude** — read one `05 33` record and compare against SmartHealth's own
   stress number. Stress is decoded on the app's 1…100 scale (`(5,3)` → 53); **fatigue's scale is
   inferred from stress**, since the app never renders fatigue. HRV from the same record must stay in
   milliseconds (`(45,6)` → 45.6). (§4.5)
5. **Find-device arguments** `{1, 5, 2}` — does the ring buzz? (§5.2)
6. **Per-mode stop** — does an SpO₂/HRV sweep actually end on `03 2f {00, mode}`? (LED still on ⇒ no.)
7. **HRV monitor tail bytes** — the three zero-filled bytes of `01 45`. (§3)
8. **Sport records** — whole-day buckets or workouts only? Distance in metres?
9. **Wear-state polarity** (`06 13`), the `sex` byte polarity in `01 03`, the `06 00`
   distance/calories offsets, and the `04 13` `state` byte.

Until these are settled the TK5's `supportLevel` stays **`.limited`** — the driver is now built from
the vendor SDK rather than one capture, but "reads correctly from the SDK" is not the same claim as
"verified against the hardware", and the badge should mean the latter.

**The SmartHealth-Colmi carries all nine plus three of its own**, because no unit has ever been
connected: whether its advertisement really carries the `1078` marker (and whether it withholds the
QRing service UUIDs), what its `02 01` bitmap actually claims, and — the one that could be a hard stop
— whether *its* firmware answers `05 xx` before any AE00/RCSP auth. Its matching constants are
therefore a *hint* with a user-declared override behind them, not a decision: see
[Colmi / Yawell → SmartHealth-app Colmi rings](hardware/colmi.md#smarthealth-app-colmi-rings).

---

See the [TK5 hardware page](hardware/tk5.md) and the
[SmartHealth-Colmi section](hardware/colmi.md#smarthealth-app-colmi-rings) for the devices themselves,
or the [hardware overview](hardware/index.md) for the cross-ring comparison.
