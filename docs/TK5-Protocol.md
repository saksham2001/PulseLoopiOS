# TK5 Ring Protocol (SmartHealth)

Developer notes for the TK5 ring driver (`PulseLoop/RingProtocol/TK5*.swift`). Reverse-engineered
from a single Android **btsnoop HCI** capture of the **SmartHealth** app
(`com.zhuoting.healthyucheng`, [Play Store](https://play.google.com/store/apps/details?id=com.zhuoting.healthyucheng))
talking to a `TK5 24AA` ring on 2026-07-06.

Fields read straight out of the capture are **verified**; offsets inferred but not independently
confirmed are tagged **UNVERIFIED** here and in code. Every decode routes through `RingEventBridge`,
which range-gates each metric, so a misdecoded byte is dropped rather than persisted.

## GATT map

| Service | Char | Handle | Props | Role |
|---|---|---|---|---|
| `be940000-7333-be46-b7ae-689e71722bd5` | `be940001` | 0x000c | write + indicate | **Command channel** — app writes here and receives command replies here |
| | `be940002` | 0x000f | write-no-resp | unused in capture |
| | `be940003` | 0x0011 | indicate | **Async stream** — live HR/steps/SpO₂ + history records |
| `180D` (Heart Rate) | `2A37` | 0x006e | notify | standard-BLE fallback live HR (auth-independent) |
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

Seconds since **2000-01-01 UTC** (add 946684800 for Unix). Confirmed against the capture's
wall-clock time.

## Commands (verified)

| type cmd | meaning | notes |
|---|---|---|
| `01 00` | set time | `[year:2 LE][month][day][hour][min][sec][00]` |
| `02 00` | status | battery at payload[5] (`0x64` = 100%) — **UNVERIFIED** offset, guarded 0…100 |
| `02 01` | device info | 66-byte block; no fixed version offset found |
| `02 24` | history dump start | payload `f0` header marker; records then stream on be940003 |
| `02 26` | history page | pull next page |
| `02 28` | history ack/finish | |
| `03 2f` | live stream on/off | `0100` on / `0000` off |

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

## Not yet decoded

- **Sleep** — no sleep record has appeared in *any* capture (ring never worn overnight). The enable
  burst now records it once worn; the record format still needs a fresh overnight capture (or the
  app's displayed sleep breakdown) to decode. Likely a `05 xx` shape with nighttime timestamps.
- **Temperature** — enable is sent; no data captured yet. Blood pressure: no sensor evidence.
