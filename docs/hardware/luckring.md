---
title: TK18 / LuckRing
description: >-
  The ~$10 LuckRing-app ring family (Shenzhen Coolwear/Kewo OEM, "K6" protocol,
  company ID 0xFF64), sold as TK18/TK18A and white-labeled under SIMSONLAB and
  other brands. HR, SpO₂, HRV, temperature, BP trend, sleep, steps.
---

# LuckRing / TK18

**PulseLoop support: 🧪 Limited — TK18 is the tested unit**

A ~$10 commodity smart ring family built by the **Shenzhen Coolwear (Kewo)** OEM
and white-labeled under many storefront brands — the unit PulseLoop was tested
against was sold as a **SIMSONLAB** ring on Shein, but the hardware identifies
itself as **TK18** and pairs with Coolwear's **LuckRing** app. It speaks a custom
cleartext protocol (vendor SDK name "K6") on service `F618` that shares nothing
with the other ring families. As far as we know this is the first public
reverse-engineering of this family.

!!! warning "Limited support — one unit tested"
    TK18 is the only hardware-tested unit of the `0xFF64` family. The protocol and
    record layouts come from the vendor SDK and are unit-tested against fixture
    bytes, but a few scales and toggles still want a confirmed on-device reading
    (noted in the capability table). Every decoded metric is range-gated before
    storage, so a misdecode is dropped rather than saved as garbage.

## At a glance

| | Detail |
|---|---|
| **SoC** | Unknown (not published; no public teardown) |
| **Bluetooth** | BLE 5.3 (per the TK18A wholesale listing) |
| **PPG sensor** | Unknown (HR/SpO₂ + skin temperature) |
| **Accelerometer** | Yes (steps, sleep) |
| **Battery / life** | 15 mAh · 3–4 days (TK18A); a 20 mAh / ~7-day variant exists |
| **Charging** | Magnetic cable (no case), ~60 min full charge |
| **Waterproof** | "5ATM" claimed |
| **Weight / size** | ~5 g · 2.5 mm wall · US sizes 7–13 |
| **Price** | ~$10 retail (wholesale $10.70–11.80) |
| **Protocol** | Custom "K6" (`F618` service), fixed 20-byte frames, cleartext |
| **App** | LuckRing (iOS + Android) |
| **Advertised name** | `TK18`; manufacturer company ID `0xFF64` |
| **Custom firmware** | ❌ None known |

## Manufacturer

- **Shenzhen Coolwear Technology Co., Ltd.** (est. 2020, Longhua District, Shenzhen) —
  app-package alias **"Kewo"** (`com.kewo.coolring`); watch/wearable ODM
- Runs the **LuckRing** app and the `luckring.coolwear.fit` backend; same developer
  ships Coolwear / CoolWear Pro / CoolWear MAX-01 / 灵犀·魔戒 (Lingxi Magic Ring)
- Holds FCC ID **2BKWA-L01** ("Smart Ring") — grant details not publicly retrievable
- Wholesale channel: listed as model **TK18A** by Shenzhen IU Smart Technology
  (~$11, explicitly "works with LuckRing")
- Retail white-labels observed: **SIMSONLAB** (Shein), **Yoidesu** and unbranded
  "LuckRing App" rings (Amazon/eBay)
- LuckRing app: Google Play since July 2024 (~79k downloads, ~2.2★), App Store
  id6472891975 (~2.1★) — the low ratings are the vendor app; the hardware is fine
  once driven directly

## Hardware

| Component | Detail |
|---|---|
| **SoC** | Unknown — never published, no FCC internal photos available |
| **PPG sensor** | Unknown (green LED HR, red/IR SpO₂, plus skin temperature) |
| **Accelerometer** | Yes (steps, sleep staging) |
| **Battery** | 15 mAh (TK18A listing) or 20 mAh (LuckRing-branded manual) — at least two variants |
| **Material** | Stainless steel shell, glue-poured (epoxy) body |
| **Weight** | ~5 g |
| **Waterproof** | "5ATM" claimed (treat skeptically at this price) |
| **Sizes** | US 7–13 (18–22.1 mm inner diameter) |

## Protocol

Reverse-engineered from the decompiled LuckRing Android app (vendor SDK
`ce.com.cenewbluesdk`, internal family "K6"). No public documentation existed
before this work. The full wire spec lives in the repo at
`tasks/luckring-protocol.md`.

| Property | Value |
|---|---|
| **Service UUID** | `0000f618-0000-1000-8000-00805f9b34fb` |
| **Write characteristic** | `0000b002-...` (write-without-response only) |
| **Notify characteristic** | `0000b001-...` |
| **Secondary service** | `FF12` (chars `FF14`/`FF15`) — believed OTA, unused |
| **Frame size** | Fixed 20 bytes, little-endian |
| **CRC** | Disabled — the vendor always sends `0x0000` |
| **Epoch** | True UTC Unix seconds |
| **Encryption** | None (cleartext); binding is a plaintext TLV bundle |
| **Standard BLE services** | Heart Rate Service (`0x180D`) — deliberately ignored |
| **Identification** | Manufacturer company ID `0xFF64` (not a Bluetooth SIG assignment) |

The SDK's PID table names sibling families **618 / 818 / 118 / 518 / S2** (service
`F618` = the 618 family), so other LuckRing-app rings should pair too — PulseLoop
matches the same signals the vendor app does (the `0xFF64` company ID / `F618`
service, no name whitelist). A non-TK18 sibling still pairs but gets generic ring
art and a fallback name.

## Capabilities

| Capability | Status | Notes |
|---|:---:|---|
| Heart rate — spot / live / history | ✅ | BPM |
| SpO₂ — spot / history | ✅ | |
| HRV — spot / history | ✅ | ms |
| Steps / distance | ✅ | Distance/calorie units unverified; calories dropped |
| Sleep (light / deep / awake) | ✅ | No REM; "movement" entries render as light sleep |
| Battery level | ✅ | In-band, with charging flag |
| Find device | ✅ | |
| Auto-monitoring config | ✅ | Firmware default is **off** — PulseLoop pushes the HR/SpO₂ interval config on every connect, or the ring never logs on its own |
| Skin temperature | 🧪 | `value/10 °C` — awaiting a confirmed on-device reading |
| Blood pressure | 🧪 | The ring accepts the command but streamed no reading in testing — possibly unsupported on this SKU. No cuff calibration — treat as a trend |
| Stress | 🧪 | Record layout unconfirmed; range-gated |
| REM sleep | ❌ | Protocol has no REM stage |
| Blood sugar | ❌ | The vendor opcode is a placeholder — the app's value is an estimate, not a sensor |
| Menstrual cycle | ❌ | User-entered calendar data in the vendor app, not a sensor |
| Continuous background sync | ❌ | Read while connected only |
| FW update via app | ❌ | Out of scope |

!!! info "PulseLoop never wipes the ring"
    The vendor SDK has a destructive clear-history opcode; PulseLoop never sends
    it. The ring replays its whole log on every sync, and PulseLoop dedupes
    app-side (upserts by kind + timestamp / bucket / night), so re-syncs never
    duplicate.

### What the TK18 CANNOT do

- REM sleep detection (protocol has light/deep/awake/movement only)
- Real blood sugar (app-side estimate, no device measurement)
- Continuous streaming while disconnected (logs on its own schedule; read on connect)

## Known models

- **TK18 / TK18A** — the tested unit; ~$10 on Shein (as SIMSONLAB), ~$11 wholesale
- Unbranded "LuckRing App" rings and **Yoidesu**-branded units on Amazon/eBay
- SDK PID families 618 / 818 / 118 / 518 / S2 — untested siblings, expected to pair

## Firmware

- The advertisement carries a board/version string (observed: `WB39_1_2_0`) with no
  public footprint — no FCC teardown, firmware repo, or update URL is known
- Device-info reply reports a 5-part dotted version (customer.hardware.code.picture.font)
- OTA is in-band / via the `FF12` service in the vendor app; not implemented in PulseLoop

## Background behavior

- The ring only logs autonomously after the auto-monitoring config is pushed
  (firmware default: off) — PulseLoop sends it on every connect
- No keepalive needed; the link stays up and history re-syncs every 30 minutes
  while connected, plus a post-workout vitals pass
- History horizon: PulseLoop drops samples older than ~8 days on ingest

## Hackability

**🥉 Newly documented**

- ✅ Protocol reverse-engineered from the decompiled vendor app (this repo:
  `tasks/luckring-protocol.md` + the `LuckRing*` driver sources)
- ✅ Cleartext BLE, no encryption, no CRC
- ❌ No public teardown, FCC internals, SoC identification, or custom firmware
- ❌ No other open-source implementation exists (checked Gadgetbridge, ATC rings)
- **Price:** ~$10

---

See the [SIMSONLAB page](simsonlab.md) for the *unsupported* LA380-YJ, or the
[hardware overview](index.md) for the full cross-manufacturer comparison tables.
