---
title: TK5 / SmartHealth
description: >-
  The TK5 ring (SmartHealth app) — the Yucheng YCBT protocol. Broad metric support.
---

# TK5 / SmartHealth

**PulseLoop support: 🧪 Limited — the protocol is confirmed on hardware, this ring isn't**

The TK5 pairs with the **SmartHealth** app (`com.zhuoting.healthyucheng`) and speaks the **Yucheng
YCBT** protocol on a `be940` service — nothing in common at the wire level with the
[56ff / Jring](jring.md) or [Colmi / Yawell QRing](colmi.md) families.

!!! warning "Limited support — the protocol is proven, the TK5 hasn't been re-tested"
    The YCBT stack is confirmed working on real hardware — but on a *sibling* ring, the
    [Colmi R09](colmi.md#smarthealth-app-colmi-rings), not on a TK5. Pairing, the handshake, history
    sync and live measurements all check out there, and both rings run the identical driver.

    What's still open here is TK5-*specific*: a few scales and payloads (blood sugar, temperature,
    find-device) need one confirmed reading — see
    **[Needs on-device confirmation](#needs-on-device-confirmation)**. Every decoded metric is
    range-gated before storage, so a misdecode is dropped rather than saved as garbage.

## Not the only ring that speaks it

The TK5 is one of **two** ring families PulseLoop drives over YCBT. The other is
**[Colmi rings that ship with SmartHealth](colmi.md#smarthealth-app-colmi-rings)** instead of QRing.
The protocol is byte-identical, so they share the whole driver (the device-neutral `YCBT*` core); each
family adds only a coordinator with its advertisement matcher and capability set. They differ in two
ways:

| | TK5 | SmartHealth-Colmi |
|---|---|---|
| **Advertisement** | `TK5 <4 hex>` — unambiguous, so it auto-detects | a Colmi-line name, which a *QRing* Colmi can also carry, so PulseLoop asks which app the ring came with |
| **SupportFunction bitmap** (`02 01`) | gates temperature, BP, stress, fatigue, blood sugar. HRV is **not** gated — it was observed working on this ring | gates those *and* HRV, which the tested R09 denies |

A fix to any `YCBT*` file fixes both rings; a regression in one breaks both.

## At a glance

| | Detail |
|---|---|
| **SoC** | JieLi (chip scheme 3/4/5 — inferred from the `AE00` RCSP service; exact part ❓) |
| **Bluetooth** | BLE (version ❓) |
| **PPG sensor** | ❓ Unknown — green LED for HR, red/IR for SpO₂ |
| **Accelerometer** | Yes (steps decoded; part ❓) |
| **Battery / life** | ❓ Unknown |
| **Waterproof** | ❓ Unknown |
| **Price** | ❓ Unknown |
| **Protocol** | Yucheng **YCBT** — variable-length frames, CRC16/CCITT-FALSE, cleartext |
| **App** | SmartHealth (`com.zhuoting.healthyucheng`) |
| **Advertised name** | `TK5 <4 hex>` — e.g. `TK5 24AA` |
| **Custom firmware** | ❓ Unknown |

## Protocol

| Property | Value |
|---|---|
| **Service** | `be940000-7333-be46-b7ae-689e71722bd5` |
| **Command char** | `be940001` — write **and** indicate (the app writes here and gets replies here) |
| **Stream char** | `be940003` — indicate: live vitals and all history data frames |
| **Frame** | `[type:1][cmd:1][len:2 LE][payload:N][crc16:2 LE]`, `len` = total frame length |
| **CRC** | CRC16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no reflection), little-endian |
| **Epoch** | Seconds since 2000-01-01, in the ring's **local wall-clock** (no timezone concept) |
| **Fragmentation** | Frames split across notifications at `MTU−3`; reassembled by the declared length |
| **History** | `05 <key>` query → header → concatenated data frames → `05 80` terminal → **mandatory `05 80 {00}` ACK** |
| **Encryption** | None on the health protocol. The `AE00` service is JieLi RCSP — see [below](#the-ae00-service) |

## Capabilities

Everything here is decoded from the vendor SDK and covered by unit tests against fixture bytes. The
right-hand column is the honest one: what a physical ring still has to confirm.

**Ring-declared vs. baseline.** The rows marked **🔓 ring-declared** are no longer promised by the app
at all: they are offered only if *this* unit's `02 01` capability bitmap sets their bit
(`YCBTSupportFunction` → `TK5Coordinator.bitmapGatedCapabilities`). Everything else is a **baseline**
promise — the app claims it unconditionally, and the bitmap can only ever *add*, never remove.

| Capability | Status | Needs on-device confirmation | Notes |
|---|:---:|---|---|
| Heart rate — spot | 🧪 | — | `03 2f` mode `00` → `06 01` stream; the standard `180D` char is deliberately ignored (see below) |
| Heart rate — live | 🧪 | — | verified against the capture (climbed 82→86) |
| Heart rate — history | 🧪 | — | `05 06` query, 6-byte records |
| SpO₂ — spot | 🧪 | — | red/IR LED, `03 2f` mode `02` |
| SpO₂ — history | 🧪 | — | dedicated `05 1A` log **and** the All record. Not separately gated: no bit names it — it is one of the SpO₂ sources `ISHASBLOODOXYGEN` already grants |
| Steps / distance / calories | 🧪 | distance & calories byte offsets in the `06 00` live push | live push + `05 02` history buckets + the All record's cumulative counter |
| Sleep (light / deep / awake) | 🧪 | — | `05 04` timeline; stage = `tag & 0x0F` |
| REM sleep | 🧪 | — | stage tag `3` — a stage *inside* the timeline `ISHASSLEEP` grants, so no bit names it and it is not gated |
| HRV | 🧪 | the three tail bytes of the `01 45` monitor enable | spot (`03 2f` mode `0a`) + the All and body-data records. **Baseline — observed on the ring** (see above) |
| Blood pressure — spot | 🔓 | per-mode stop (`03 2f {00, 01}`) | ring-declared (`ISHASTESTBLOOD`, byte 15 bit 2). `03 2f` mode `01`; no cuff calibration, so treat as a trend, not a number |
| Blood pressure — history | 🔓 | — | ring-declared (`ISHASBLOOD`, byte 0 bit 0). Dedicated `05 08` log + the All record |
| Skin temperature | 🔓 | one real reading (the string-concat scale) | ring-declared (`ISHASTEMP`, byte 8 bit 0). Dedicated `05 1E` log + the All record; monitor enabled by `01 20` |
| Stress | 🔓 | — | ring-declared (`IS_HAS_PRESSURE`, byte 22 bit 6). **Ring-stored**, from the body-data record (`05 33`) — the SDK's `pressure` field |
| Fatigue | 🔓 | — | ring-declared on the **same bit as stress**: no `ISHASFATIGUE` exists, but the vendor app gates the whole `05 33` query on `IS_HAS_PRESSURE`, and fatigue (the SDK's `body` field) is a field of that one record. No body data ⇒ neither score |
| Blood sugar | 🔓 | **one real reading — the scale is inferred, not observed** | ring-declared (`ISHASBLOODSUGAR`, byte 17 bit 3). All record @17 and the comprehensive record (`05 2F`); tenths of mmol/L → mg/dL |
| Respiratory rate | 🧪 | — | All record @10 |
| VO₂max | 🧪 | raw byte taken unscaled | body-data record @16 |
| Battery level | 🧪 | — | in-band: `02 00` reply payload[5], plus the unprompted `06 15` push |
| Find device | 🧪 | **the command's three payload bytes** | `03 00 {01, 05, 02}` — the app's literal arguments; the SDK never names them |
| Measurement intervals | 🧪 | — | five `01 xx {enable, interval}` monitors; floored at the firmware's 30-min minimum |
| Periodic re-sync while connected | ✅ | — | every 30 min (SmartHealth's own cadence), plus a post-workout vitals pass |
| Continuous background sync | ❌ | — | the ring is only read while connected |
| FW update via app | ❌ | — | out of scope — would require the JieLi RCSP auth (see below) |

## Needs on-device confirmation

The open items, in priority order. Each is range-gated in code, so a wrong guess degrades to "no
reading", never to a wrong reading:

1. **Blood-sugar scale** — the tenths-of-mmol/L reading is inferred from SmartHealth's database
   column and chart filter, not from an observed non-zero record. Cross-check one reading.
2. **Temperature scale** — the int/fraction pair is *string-concatenated* (`5` → `.5`, `25` → `.25`),
   not divided. Confirm a real reading lands at ~36.x °C.
3. **Find-device payload** — `{1, 5, 2}` replays the app's own button; the SDK never names the
   arguments. First suspect if the ring doesn't buzz.
4. **Per-mode stop** — an SpO₂/HRV sweep is stopped with its *own* mode byte. If the LED stays on
   afterwards, this is the line to look at.
5. **HRV monitor tail bytes** — `01 45 {enable, interval, 0, 0, 0}`; only the first two arguments are
   named in the SDK, so the rest are zero-filled rather than guessed.
6. **Sleep** — the multi-session timeline is decoded from the SDK and unit-tested, but no YCBT ring has
   been worn overnight yet.

## The AE00 service

The ring exposes a second service, `AE00`, carrying an encrypted `FE DC BA …` / `02 "pass"`
handshake. It looks like a login gating the health data. **It is not** — and that is now settled on
hardware, not just from the SDK.

It is **JieLi RCSP** — the chipset vendor's challenge-response auth, an entirely separate subsystem
from the Yucheng health protocol. It authorizes the **JieLi feature set only: OTA / firmware update,
watch-face upload, and log extraction.** The health commands on `be940001` are plaintext, CRC-framed
and carry no auth of any kind. The AES key lives in a native library (`libjl_rcsp.so`) and is not
recoverable from the decompile.

This was the project's one potential hard stop: the SDK proves the two code paths are independent, but
it cannot prove a given *firmware* doesn't refuse health commands until RCSP auth completes. The
[Colmi R09](colmi.md#smarthealth-app-colmi-rings) answered that — it reports **chip scheme 4 (JieLi)**
and every health command, history query and measurement still answered **in plaintext, with no AE00
exchange at all**. PulseLoop implements none of RCSP, and doesn't need to.

## How PulseLoop diverges from SmartHealth

**We never delete records off the ring.** SmartHealth issues the Health-Delete opcodes (`05 40…4E`)
after a sync, so its next sync is small. PulseLoop doesn't: a delete that races a failed decode
destroys data that exists nowhere else, and it makes the vendor app and PulseLoop mutually
destructive on the same ring.

The consequence is that **the ring replays its entire log on every sync**, so deduplication is
app-side: every history sample upserts on `(kind, timestamp)`, activity buckets upsert by start
epoch, and the cumulative step counter is a per-day `max` ratchet. All three are idempotent under
replay, so a double-sync produces no duplicates. The cost is a longer sync as the ring's log fills.

## Known limitations
- **~8-day history horizon.** `RingEventBridge` drops any history sample, sleep session or activity
  timestamp outside `now − 8 days … now + 1 hour`. A ring's log can hold records stamped under a
  *previous* clock, which decode hours or days out of place — and because history rows upsert, one
  misdecoded record wouldn't merely flicker, it would re-persist on every future sync. Records older
  than the window are therefore not imported.
- **No background sync while disconnected.** The ring keeps logging on its own schedule (that's what
  the `01 xx` monitors are for), but PulseLoop only reads it while connected: on connect, every 30
  minutes thereafter, and after a workout.
- **No firmware updates or watch faces.** Both live behind the JieLi RCSP auth (see above) and are
  out of scope.
- **Standard heart-rate service is deliberately ignored.** The TK5 exposes `180D`/`2A37`, but it
  emits a cached resting HR (~87 bpm) even off-finger, which would mask real readings. Live HR comes
  solely from the proprietary `06 01` stream, as in the official app.
- **Timestamps are timezone-naive.** The ring stores local wall-clock seconds with no timezone byte,
  so the decoder un-applies the device's UTC offset to recover the true instant. This is exact for
  same-session syncs and can be an hour off across a DST transition.

---

See the [SmartHealth-app Colmi rings](colmi.md#smarthealth-app-colmi-rings) that share this driver,
or the [hardware overview](index.md) for the cross-manufacturer comparison.
