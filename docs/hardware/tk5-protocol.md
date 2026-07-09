---
title: TK5 protocol notes
description: >-
  Byte-level teardown of the TK5's be940 protocol — GATT map, CRC16 framing,
  commands, history records, and sleep decoding.
---

# TK5 Ring Protocol (SmartHealth)

Developer notes for the TK5 ring driver (`PulseLoop/RingProtocol/TK5*.swift`). Reverse-engineered
from a single Android **btsnoop HCI** capture of the **SmartHealth** app
(`com.zhuoting.healthyucheng`, [Play Store](https://play.google.com/store/apps/details?id=com.zhuoting.healthyucheng))
talking to a `TK5 24AA` ring on 2026-07-06.

!!! warning "Experimental — limited support"
    One capture is not a spec. See [TK5 / SmartHealth](tk5.md) for what this does and doesn't mean
    for the readings you'll see in the app.

Fields read straight out of the capture are **verified**; offsets inferred but not independently
confirmed are tagged **UNVERIFIED** here and in code. Every decode routes through `RingEventBridge`,
which range-gates each metric, so a misdecoded byte is dropped rather than persisted.

## GATT map

| Service | Char | Handle | Props | Role |
|---|---|---|---|---|
| `be940000-7333-be46-b7ae-689e71722bd5` | `be940001` | 0x000c | write + indicate | **Command channel** — app writes here and receives command replies here |
| | `be940002` | 0x000f | write-no-resp | unused in capture |
| | `be940003` | 0x0011 | indicate | **Async stream** — live HR/steps/SpO₂ + history records |
| `180D` (Heart Rate) | `2A37` | 0x006e | notify | standard HR — **not subscribed**: emits a cached resting HR (~87 bpm) even off-finger, which masks real readings. Live HR uses the proprietary `06 01` stream instead. |
| `FEE7` | FEC9/FEA1/FEA2 | | | present, unused |
| `AE00` | AE01/AE02 | 0x0082/0x0084 | write / notify | encrypted `fedcba`/"pass" login — see below |

Note `be940001` is **both** the write target and a notify source; `RingBLEClient` discovery
subscribes a `notifyUUIDs` entry even when it also equals `writeUUID`.

## Framing (both be940001 and be940003)

```
[type:1][cmd:1][len:2 LE][payload:N][crc16:2 LE]
```

- `len` = **total** frame length (header + payload + crc).
- CRC = **CRC16/CCITT-FALSE** (poly `0x1021`, init `0xFFFF`, no reflection, no final xor), appended
  **little-endian**. Verified against every frame in the capture.
- Replies echo the same `type`/`cmd`.

Example — set time: `01 00 0e00 ea0707060c220e00 26c7` → `2026-07-06 12:34:14`.

## Timestamps

Seconds since **2000-01-01**, but the ring has **no timezone concept**: `TK5Encoder.setTime` sends
raw local wall-clock fields (see the set-time command above) with no timezone byte, and the ring's
clock just ticks forward in real seconds from whatever instant those fields describe. Decoding
(`TK5Bytes.date`) must therefore un-apply the device's current UTC offset to recover the true
absolute instant — treating the stored seconds as pure UTC (the original approach) silently shifts
every decoded timestamp by a full UTC-offset, which is enough to flip a sleep session onto the
wrong side of the app's 7 PM day boundary for any non-UTC timezone.

## Commands (verified)

| type cmd | meaning | notes |
|---|---|---|
| `01 00` | set time | `[year:2 LE][month][day][hour][min][sec][00]` |
| `02 00` | status | battery at payload[5] (`0x64` = 100%) — **UNVERIFIED** offset, guarded 0…100 |
| `02 01` | device info | 66-byte block; no fixed version offset found |
| `02 24` | history dump start | payload `f0` header marker; records then stream on be940003 |
| `02 26` | history page | pull next page |
| `02 28` | history ack/finish | |
| `03 09` | live status auto-push on/off | `01 00 02` enables, `00 00 02` disables. Once enabled the ring streams `06 00` (steps/distance/calories) continuously while connected — **required** for live step updates. |
| `03 2f` | live measurement on/off | payload `[enable:1][mode:1]`; **mode picks the sensor**: `00`=HR (green LED)→`06 01`, `01`=BP→`06 03`, `02`=SpO₂ (red/IR LED)→`06 02`, `0a`=HRV→`06 03`; stop = `00 <mode>`. (`0c` seen, unidentified.) |

## Async stream (be940003)

| type cmd | meaning | decode | confidence |
|---|---|---|---|
| `06 00` | live status | steps `u16[0]` (verified 635); distance `u16[2]`, calories `u16[4]` | steps verified; rest inferred (max()-safe) |
| `06 01` | live heart rate | `payload[0]` bpm | verified (82→86) |
| `06 02` | live SpO₂ | `payload[0]` % | inferred (values 95–98) |
| `05 15` | history HR record | `[ts:4][hr:1]` | inferred |
| `05 18` | history activity record | `[ts:4][steps:2]…` | steps verified |

## The AE00 login (open question)

The capture shows a separate encrypted handshake on `AE00` (`fedcba` magic frames + AES-128-sized
blocks + ASCII `"pass"`). It is **not implemented** — the AES key isn't recoverable from a single
capture. Two facts bound the risk:

- **Basic connect, time sync, device info, and status returned in plaintext on be940001 *before* the
  AE00 handshake began** — so those work without it.
- The **live stream and history dump happened *after* the handshake** in the capture, because the app
  always does AE00 first. Whether the ring *gates* streaming/history behind AE00 can only be
  confirmed on-device.

If on-device testing shows live/history data never arrives, the AE00 login is the culprit and needs a
follow-up capture (ideally with the key derivation) to implement. Connect + standard-`2A37` HR +
today's steps/battery should work regardless.

## Second capture (2026-07-06, HRV/stress) — partial

A longer capture taken after enabling HRV/stress monitoring surfaced the **enable toggles** and
several **new history record shapes**, but no on-screen values were recorded so the metric↔field
mapping is not yet locked.

**Enable-monitoring writes** — `05 <metric> 02` (payload `0x02` = enable, Colmi-family pref-write
convention), sent as a burst when the user toggled monitoring on; the `05 09` config read-back then
reported the enabled state. Observed metric cmds: `0x40, 0x42, 0x43, 0x44, 0x4e`. The driver now
sends this whole burst on connect (`TK5Encoder.enableAllMonitoring`) so the ring *records* these
metrics — the precondition for sleep/HRV/stress showing up in a later history dump.

**HRV — VERIFIED and decoded.** It rides inside the `05 18` activity record at **payload offset 11**
(one byte, ms), and lives on the `06 03` frame at payload[3]. Confirmed against the app's displayed
values: 48 ms @1:00 and 79 ms @1:32 both matched exactly. The driver now emits HRV history (from
`05 18`) and live HRV (from `06 03`), and `TK5Coordinator` claims `.hrv`.

**Stress — NOT a ring value; app-derived.** The displayed stress scores (33 @1:00, 32 @1:32) appear
*nowhere* in the ring's data as a raw byte, and they track HRV inversely (HRV up ⇒ stress down), so
SmartHealth computes stress from HRV on-device. We don't claim `.stress`; if wanted later, compute it
from HRV rather than expecting a ring field.

**Other new record shapes** (structure only; not yet needed):

| record | shape | notes |
|---|---|---|
| `05 11` | `[start_ts:4][end_ts:4][u16][u16][u16]` | session/day summary window (e.g. 13:00–13:30 → 99, 62, 3) |
| `05 17` | `[ts:4][flag:1][a][b][c]` | co-varying triple (~110/73/66), also live on `06 03` |
| `05 34` | `[ts:4][series:16]` | intraday series; carries the same HRV byte (48) |

## Multi-record history frames (fixed 2026-07-07)

History frames **concatenate many fixed-size records**; decoding only the first hid periodic data.
- `05 15`: packed **6-byte** HR records `[ts:4][flag:1][hr:1]` (e.g. eight hourly overnight samples).
- `05 18`: packed **20-byte** combined-vitals records `[ts:4][steps:2][hr@6][sys@7][dia@8][spo2@9]
  [?@10][hrv@11]…`. We emit periodic **SpO₂ (@9)**, **HRV (@11)**, and **BP (@7/@8** — later verified
  against the app, see below); HR comes from `05 15`. Steps are a *cumulative* daily counter (not
  deltas), emitted as a per-day max rather than an additive bucket.

## Sleep (`05 13`) — VERIFIED

One logical record split across several be940003 frames. **Reassembly:** the header frame starts with
magic `af fa`, total concatenated payload length at bytes [2..3]; buffer until that many bytes arrive.

Layout: 20-byte header `[af fa][totalLen:2][startTs:4][endTs:4]…`, then 8-byte segments
`[stage:1][startTs:4][durationSec:2][pad:1]`. Segments are contiguous → expand to per-minute stages,
emit one `.sleepTimeline`.

**Stage tags verified against the app's on-screen breakdown** (deep 1h33 / light 4h9 / rem 2h10,
window 22:33–06:27, awake 0): `0xf1`=deep, `0xf2`=light, `0xf3`=rem, `0xf4`=awake.

## Not yet decoded

- **Temperature** — enable is sent; no data captured yet.
## Blood pressure — VERIFIED

Two sources, both emitted:
- **Periodic** in `05 18` at offsets 7 (systolic) / 8 (diastolic) — verified 106/70 @6:00.
- **Live** on `06 03` in BP mode (`03 2f 01 01`): `[sys][dia][hr?]…` — verified 111/74, 112/75.

The `06 03` frame is shared between BP (mode 0x01) and HRV (mode 0x0a); the decoder distinguishes by
whether the leading bytes fall in BP range. `.bloodPressure` capability declared; app-side calibration
(offset on read) works even though there's no ring-side BP-calibration command.
