---
title: LuckRing / TK18
description: >-
  The LuckRing / TK18 family (the "K6" vendor SDK, company ID 0xFF64), rebuilt
  from the decompiled LuckRing Android app. TK18 is the hardware-tested unit.
---

# LuckRing / TK18

**PulseLoop support: 🧪 Limited — reconstructed from the vendor SDK; TK18 is the tested unit**

The **TK18** pairs with the **LuckRing** Android app and speaks a fixed-20-byte, cleartext protocol the
vendor SDK calls **"K6"** (`ce.com.cenewbluesdk`). It advertises the manufacturer company ID **`0xFF64`**
and a service **`F618`** — nothing in common at the wire level with the [56ff / Jring](jring.md),
[Colmi / Yawell QRing](colmi.md), or [TK5 / SmartHealth YCBT](tk5.md) families.

PulseLoop's driver is reconstructed from the **decompiled LuckRing Android app**, whose BLE stack is the
`ce.com.cenewbluesdk` vendor SDK (internal family "K6").

!!! warning "Limited support — one unit tested"
    TK18 is the only hardware-tested unit of the whole `0xFF64` family, so support is **Limited**. The
    protocol, framing, and every record layout come from the vendor SDK and are covered by unit tests
    against fixture bytes, but a handful of scales and toggles still want one confirmed reading — see
    **[Needs on-device confirmation](#needs-on-device-confirmation)**. Every decoded metric is
    range-gated before storage, so a misdecode is dropped rather than saved as garbage.

## Not just the TK18

The `0xFF64` LuckRing family covers a range of PID variants (the SDK names PID families **618 / 818 /
118 / 518 / S2**), sold under **simsonlab** and other brands. They all speak the identical K6 protocol,
so PulseLoop drives the whole family with one stack: the coordinator matches the family-exclusive
signals (the `F618` service or the `0xFF64` company ID — the same signal the vendor app matches on, with
no name whitelist), and any unit that isn't a TK18 still pairs, but gets the generic ring art and a
fallback name.

!!! note "simsonlab sells two different rings"
    The [SIMSONLAB **LA380-YJ**](simsonlab.md) (a PHY6222 ring on an unknown protocol) is **not**
    supported. The simsonlab-branded rings that pair with the **LuckRing** app are a different product
    and **are** supported here.

## At a glance

| | Detail |
|---|---|
| **SoC** | ❓ Unknown |
| **Bluetooth** | BLE (version ❓) |
| **PPG sensor** | ❓ Unknown — green LED for HR, red/IR for SpO₂ |
| **Accelerometer** | Yes (steps decoded; part ❓) |
| **Battery / life** | ❓ Unknown |
| **Waterproof** | ❓ Unknown |
| **Price** | ❓ Unknown |
| **Protocol** | "K6" — fixed **20-byte** packets, little-endian, **no CRC**, cleartext |
| **App** | LuckRing (Android) |
| **Advertised name** | `TK18` (± a ` `/`_`/`-` suffix); manufacturer company ID `0xFF64` |
| **Custom firmware** | ❓ Unknown |

## Protocol

| Property | Value |
|---|---|
| **Service** | `0000f618-0000-1000-8000-00805f9b34fb` |
| **Notify char** | `0000b001…` (CCCD) — every reply / data frame arrives here |
| **Write char** | `0000b002…` — every 20-byte packet is written here |
| **Frame** | Fixed **20 bytes**. Head: `[0]=0 [1]=devType [2]=#pages [3]=seq [4]=cmdType [5]=dataType [6..7]=CRC16(=0) [8..9]=len LE [10..19]=payload[0..9]`. Continuation: `[0]=page [1..19]=19 payload bytes` |
| **CRC** | **Disabled** — the vendor sends `0x0000` and never checks it |
| **Epoch** | **True UTC** Unix seconds (unlike the TK5/jring local-wall-clock clocks) |
| **ACK rule** | The app ACKs a device-initiated **SEND** (`cmdType 1`) with `[4]=4, len=1, payload[0]=1`; it never ACKs an ACK or a SEND_NO_ACK |
| **Binding** | The **MixInfo** TLV bundle (dataType 110); no crypto, no auth |
| **History** | Sequential per-type `REQUEST`; the streams carry **no terminal marker**, so the pager advances when a type's frames settle and skips a type that never answers |
| **Encryption** | None |

The full wire spec — opcodes, record layouts, the MixInfo TLV, and the ACK rules — is in the repo at
`tasks/luckring-protocol.md`.

## Capabilities

Everything here is decoded from the vendor SDK and covered by unit tests against fixture bytes. The
right-hand column is the honest one: what a physical ring still has to confirm.

**No bitmap gating (yet).** Unlike the [TK5](tk5.md), this family declares its whole capability set as a
**baseline** — the K6 `FUNCTION_CONTROL` (dataType 22) bitmap is obfuscated in the decompile, so no
capability can yet be deferred to the connected unit. Capabilities the physical TK18 refuses should be
**pruned** from `LuckRingCoordinator` once on-device testing confirms them.

| Capability | Status | Needs on-device confirmation | Notes |
|---|:---:|---|---|
| Heart rate — spot / live | 🧪 | the real-HR start opcode (24 vs 21) | toggle `24`; the stream returns on dataType `7` (envelope + 5-byte `[time][bpm]` records). The standard `180D` char is deliberately ignored |
| Heart rate — history | 🧪 | — | dataType `8`, same 5-byte records |
| SpO₂ — spot / live | 🧪 | — | toggle `20`; 5-byte `[time][spo2]` records |
| SpO₂ — history | 🧪 | — | dataType `40` (the all-day log) |
| Steps / distance | 🧪 | distance & calorie **units** | 20-byte sport records (`[start][steps][dist u24][cal u24][dur u24]`), live `4` + history `5`, stored as summed buckets. Calories are dropped |
| Sleep (light / deep / awake) | 🧪 | the type-5 (movement) mapping | paged timeline (dataType `6`); types 1/3/5→light, 2→deep, 4 ends the session |
| HRV — spot / history | 🧪 | — | toggle `45` / history `42`; 5-byte `[time][value]` records |
| Skin temperature | 🧪 | one real reading (the `/10` scale) | toggle `46` / history `47`; `[time][value]/10 °C` |
| Blood pressure — spot / history | 🧪 | — | toggle `18` / history `41`; 6-byte `[time][sys][dia]` records; no cuff calibration, so treat as a trend |
| Stress | 🧪 | the body-recovery record layout | dataType `52`/`53`; range-gated, so a misread is dropped |
| Battery level | 🧪 | — | in-band: dataType `3` reply (`[percent][charging]`) |
| Find device | 🧪 | — | dataType `11` |
| Auto-monitoring config | 🧪 | whether the ring honors the interval byte | dataType `128`: `[autoHR][hr24h][interval min][autoO2][0×4]`. The firmware default is **off**, so PulseLoop pushes this on every connect — without it the ring never logs history on its own |
| Periodic re-sync while connected | ✅ | — | history is re-runnable while connected, plus a post-workout vitals pass |
| Continuous background sync | ❌ | — | the ring is only read while connected |
| FW update via app | ❌ | — | out of scope |

**Deliberately not claimed:** blood sugar (the vendor's opcode is a `999` placeholder — no real record),
menstrual cycle (user-entered, not a sensor), REM sleep (K6 has no REM stage), fatigue, and a
combined-vitals sweep.

## Needs on-device confirmation

The open items, in priority order. Each is range-gated in code, so a wrong guess degrades to "no
reading", never to a wrong reading:

1. **Real-HR start opcode** — the toggle uses `24` (the vendor's `K6_DATA_TYPE_REAL_HR`); if the ring
   doesn't stream HR on the first Measure, try `21` (`HR_CONTROL`).
2. **Sport distance / calorie units** — the 20-byte layout is solid, but the units are unverified;
   `.activityBucket` drops calories anyway.
3. **Sleep type-5 (movement)** — mapped to light sleep; cross-check against the vendor app's hypnogram.
4. **Temperature scale** — `[time][value u16]/10`; confirm a real reading lands at ~36.x °C.
5. **First-pair token** — the bundle's `120 {1,0}` triggers the ring's pairing animation and is sent only
   once (latched in `UserDefaults`); if a reconnect re-triggers it, the latch is the line to look at.
6. **Capability bitmap** — capture the `devSync` (dataType 9) / `FUNCTION_CONTROL` (22) TLV from the
   debug feed so the obfuscated bitmap can be mapped and the baseline moved behind a gate.

## How PulseLoop diverges from LuckRing

**We never wipe records off the ring.** The K6 SDK has a destructive `cleanData` (dataType 207) opcode;
PulseLoop never sends it. The consequence is that the ring replays its whole log on every sync, so
deduplication is app-side: every history sample upserts on `(kind, timestamp)`, activity buckets upsert
by start epoch, and sleep upserts by night. All are idempotent under replay, so a re-sync produces no
duplicates.

## Known limitations

- **One unit tested.** TK18 is the only `0xFF64` ring run against this driver; the open items in
  [Needs on-device confirmation](#needs-on-device-confirmation) keep support at "Limited". See
  [Contributing](../project/contributing.md) if you own one.
- **~8-day history horizon.** `RingEventBridge` drops any history sample, sleep session, or activity
  timestamp outside `now − 8 days … now + 1 hour`.
- **No background sync while disconnected.** The ring keeps logging on its own schedule, but PulseLoop
  only reads it while connected: on connect, every 30 minutes thereafter, and after a workout.
- **Standard heart-rate service is deliberately ignored.** The ring exposes `180D`, but live HR comes
  solely from the proprietary stream, which reflects real finger contact — the same choice the TK5
  driver makes.

---

See the [SIMSONLAB page](simsonlab.md) for the *unsupported* LA380-YJ, or the
[hardware overview](index.md) for the cross-manufacturer comparison.
