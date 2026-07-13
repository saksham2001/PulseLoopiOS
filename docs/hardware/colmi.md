---
title: Colmi / Yawell
description: >-
  The $15–30 Colmi/Yawell ring family (R02/R0x/R1x/H59) — sold with either the
  QRing app (Nordic-UART protocol) or the SmartHealth app (Yucheng YCBT). Both supported.
---

# Colmi / Yawell

**PulseLoop support: ✅ Supported & tested** — with either app

The QRing family — manufactured by Yawell and most commonly sold under the
**Colmi** brand. These $15–30 rings speak a Nordic-UART–based protocol and bring
sensors the cheaper [56ff / Jring](jring.md) lacks: skin temperature, REM sleep,
HRV, stress, and continuous background sync.

!!! info "The same ring is sold with two apps — PulseLoop supports both"
    A Colmi ring ships with **either QRing or SmartHealth**, and the two speak completely different
    BLE protocols. The box tells you which; the ring itself doesn't, so **PulseLoop asks you when you
    pair** ([details](#the-pairing-app-type-picker)). Pick wrong and it's a 20-second dead end with a
    one-tap fix — never a broken ring.

    | | Protocol | Covered by |
    |---|---|---|
    | **QRing** app | Nordic-UART (`6e40fff0` / `de5bf728`) | this page, down to [Hackability](#hackability) |
    | **SmartHealth** app | Yucheng YCBT (`be940`) — the [TK5](tk5.md)'s protocol | [SmartHealth-app Colmi rings](#smarthealth-app-colmi-rings) |

## At a glance

| | Detail |
|---|---|
| **SoC** | Realtek RTL8762 family (Realtek AB2026 on R11) |
| **Bluetooth** | BLE 5.0 |
| **PPG sensor** | Vcare VC30F (red + green dual LED) on R10/R11/R12 |
| **Accelerometer** | STK8321 / ST LIS2DOC |
| **Battery / life** | 15–18 mAh · ~4–7 days |
| **Waterproof** | IP68 / 3ATM–5ATM (varies by model) |
| **Price** | $15–30 |
| **Protocol** | Nordic-UART QRing (`6e40fff0` / `de5bf728`), 16-byte frames, cleartext |
| **App** | QRing (R11 also: Da Rings) |
| **Custom firmware** | ✅ on R02/R03 (BXMicro); ⚠️ unknown on R10/R12 |

## Manufacturer

- **Shenzhen Yawell Intelligent Technology Co., Ltd.** (est. 2016, Shenzhen)
- 3 factories, 16 assembly lines, 500+ workers, 100+ R&D engineers
- Largest smart ring factory in South China (5,000 m², established 2024)
- 150K+ monthly smart ring shipments
- OEM/ODM for Lenovo, Nokia, Skyworth, Noise, Titan, Fire Boltt
- First smart ring launched: 2023
- Official app: **QRing** (by Yawell)
- **Colmi** (Shenzhen Colmi Technology Co., Ltd.) is the most popular licensed brand selling Yawell's QRing rings
- Website: [yawellfit.com](https://www.yawellfit.com/), [colmi.com](https://www.colmi.com/)

## Protocol (QRing firmware)

| Property | Value |
|---|---|
| **BLE family** | Nordic-UART (`6e40fff0` / `de5bf728`) |
| **App** | QRing |
| **Frame size** | 16 bytes (checksum) |
| **Encryption** | None |

A SmartHealth-flavoured unit speaks none of this — see
[SmartHealth-app Colmi rings](#smarthealth-app-colmi-rings).

## Models — QRing platform

| Model | CPU | Bluetooth | Battery | Waterproof | Display | Sensors | Notes |
|---|---|---|---|---|---|---|---|
| **R02** | Realtek RTL8762 | BLE 5.0 | Varies | IP68/3ATM | No | Unknown | Entry-level, "highly supported" per Gadgetbridge |
| **R03** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R06** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R07** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R09** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R10** | RTL8762 ESF | BLE 5.0 | 17 mAh | 5ATM | No | Vcare VC30F + STK8321 | Charging case: 200 mAh |
| **R12** | Realtek RTL8762 | BLE 5.0 | 15/18 mAh | IP68 + 1ATM | Yes | Vcare VC30F + ST LIS2DOC | Newest (2025), 4g weight |

### Yawell-branded QRing models

- R05, R10, R11, H59 — all use the same QRing protocol

## Colmi R11 — QRing-Compatible with Fidget Shell

The Colmi R11 uses a Realtek AB2026 SoC rather than the RTL8762 found in other QRing models,
but speaks the same Nordic-UART QRing protocol. It pairs with both the **Da Rings** app and the
**QRing** app.

| Component | Detail |
|---|---|
| **CPU** | Realtek AB2026 |
| **Bluetooth** | BLE 5.0 |
| **PPG sensor** | Vcare VC30F (red + green dual LED) |
| **Accelerometer** | STK8321 (3-axis MEMS) |
| **Battery** | 15 mAh (sizes 8–9) / 18 mAh (sizes 10–13) |
| **Charging case** | 200 mAh |
| **Waterproof** | IP68 + 5ATM |
| **Build** | Stainless steel casing with fidget-spinner outer shell |
| **Apps** | Da Rings or QRing (Android 5.1+ / iOS 12.0+) |

PulseLoop matches R11 rings via the `R11C?_[0-9A-F]{4}$` pattern in the Colmi QRing driver.
Capabilities should match the R10 (same VC30F + STK8321 sensor pair).

## Sensors

### Vcare VC30F

The VC30F is the PPG bio-sensor used in R10, R11, and R12:

- **Red + green LED emitters** — dual wavelength for HR and SpO₂
- **Integrated photodiode** — detects reflected light with ambient light rejection
- **Analog front-end (AFE)** — filters and amplifies raw signal
- **Digital controller** — outputs processed pulse data
- Available on JLCPCB's parts library (traceable component)
- Real-world accuracy: within 1 BPM of medical-grade BP monitor (per R12 review)

### ST LIS2DOC (R12) / STK8321 (R10, R11)

3-axis MEMS accelerometer for:

- Step counting and gesture detection
- Wear detection (wake on motion)
- Raw acceleration data for sleep and activity algorithms

## Capabilities per model (QRing firmware)

| Capability | R10 | R12 | R11 | Other QRing¹ |
|---|---|---|---|---|
| **Heart rate — spot** | ✅ | ✅ | ✅ | 🧪 |
| **Heart rate — history** | ✅ | ✅ | ✅ | 🧪 |
| **Heart rate — live** | ✅ | ✅ | ✅ | 🧪 |
| **SpO₂ — history** | ✅ | ✅ | ✅ | 🧪 |
| **SpO₂ — spot** | —² | —² | —² | —² |
| **Steps / distance / calories** | ✅ | ✅ | ✅ | 🧪 |
| **Sleep stages** (light/deep/awake) | ✅ | ✅ | ✅ | 🧪 |
| **REM sleep** | ✅ | ✅ | ✅ | 🧪 |
| **HRV** | ✅ | ✅ | ✅ | 🧪 |
| **Stress** | ✅ | ✅ | ✅ | 🧪 |
| **Body temperature** | ✅ | ✅ | ✅ | 🧪 |
| **Battery level** | ✅ | ✅ | ✅ | 🧪 |
| **Find device** | ✅ | ✅ | ✅ | 🧪 |
| **Blood pressure** | ❌ | ❌ | ❌ | ❌ |
| **Blood sugar** | ❌ | ❌ | ❌ | ❌ |

¹ R02, R03, R06, R07, R09 + Yawell R05, R10, R11, H59
² Colmi family has no on-demand SpO₂ reading; SpO₂ is all-day background only
³ Colmi has no blood pressure or blood sugar support. Its `userPreferences` (gender/age/height/weight) is for general health metric tuning only — not for BP/BS computation.

### What the Colmi family CAN do (that 56ff cannot)

- REM sleep detection
- Body temperature (skin temperature sensor)
- HRV
- Stress scoring
- Continuous background sync (autonomous notifications while worn)

---

## SmartHealth-app Colmi rings

**PulseLoop support: ✅ Tested on the Colmi R09** — other models implemented, untested

Some Colmi rings ship with **SmartHealth** (`com.zhuoting.healthyucheng`) instead of QRing: same brand,
same product numbers, often the same box — but the firmware speaks the **Yucheng YCBT** protocol
(`be940`), which has nothing in common at the wire level with QRing's Nordic-UART frames. It is the
[TK5](tk5.md)'s protocol byte for byte, so these rings run the same shared driver.

### Which rings

| Ring | Status |
|---|---|
| **Colmi R09** (advertises `R99 54DC`) | ✅ Tested — pairs, syncs, HR + SpO₂ + blood pressure |
| Colmi R10 | 🧪 Implemented, untested |
| Any other Colmi / Yawell model | ❔ Possible — which app a ring ships with is a seller choice, not a hardware one, and the *same* model number is sold both ways. If yours came with SmartHealth it should just work |

Every SmartHealth ring seen so far advertises as `<MODEL> <4 hex>` — with a **space** (`R99 54DC`,
`TK5 24AA`) — where QRing rings use an **underscore** (`R02_A1B2`). PulseLoop uses that to pre-select
the picker, but your pick always wins.

### The pairing app-type picker

The ring can't be asked which app it came with, so PulseLoop **asks you**. Under every Colmi card in
*Add your ring* there's a segmented picker — *"Which app came with your ring?"* — with **QRing** (the
default) and **SmartHealth**. It chooses the driver, and the card's capability chips and support badge
follow it. jring and TK5 show no picker: those ship with exactly one app.

**If you pick wrong**, the driver looks for services the ring doesn't have, the connect stalls, and
after **20 seconds** PulseLoop says so — *"This ring didn't answer as a SmartHealth ring…"* — with a
one-tap **"Try as QRing"** that flips the picker and re-dials. Nothing wrong is saved. (Only pairing
times out; a background reconnect to a ring you've already paired keeps waiting, as it should.)

### Capabilities

**The ring decides.** The handshake asks what sensors it has (`02 01` → its capability bitmap) and
PulseLoop offers only those, so two Colmi rings on the identical protocol correctly show different
cards. The bitmap can only *add* from a pre-approved list — a garbled reply never takes one away.

The R09 shows why that matters: it reports **no HRV, temperature, stress or blood sugar** — but it
*does* have blood pressure, including calibration.

| Capability | QRing-Colmi | SmartHealth-Colmi (R09) |
|---|:---:|:---:|
| Heart rate — history / live / spot | ✅ | ✅ |
| SpO₂ — history | ✅ | ✅ |
| SpO₂ — **spot** | ❌ (all-day only) | ✅ (takes ~40 s) |
| Steps / distance / calories | ✅ | ✅ |
| Sleep, incl. REM | ✅ | 🧪 untested |
| Blood pressure — spot + history | ❌ | ✅ ¹ |
| Battery · find device · measurement intervals | ✅ | ✅ |
| HRV | ✅ | ❌ ¹ |
| Skin temperature · Stress | ✅ | ❌ ¹ |
| Blood sugar | ❌ | ❌ ¹ |
| Power off / factory reset | ✅ | ❌ |
| Continuous background sync | ✅ | ❌ — read only while connected |

¹ **Ring-declared.** A different SmartHealth-Colmi that sets the bit would get these cards. The R09
leaves them clear, and backs that up on the wire — it refuses the HRV commands outright.

### 🧪 Still unconfirmed

**Sleep** is the one significant path no SmartHealth-Colmi has exercised yet. Everything else above is
confirmed on the R09 — including that its JieLi chip needs **no `AE00` auth**: every health command
answered in plaintext.

---

## Hackability

### 🏆 Full-Stack Hackable: Colmi R02 / R03 / R06

Per Hackaday's deep-dive by Aaron Christophel, the Colmi R02 is the most hacker-friendly ring:

| What | Detail |
|---|---|
| **Custom firmware** | Flashable via BLE OTA — **no signing, no encryption** |
| **Debug interface** | SWD pads accessible (scrape epoxy to expose) |
| **MCU** | BXMicro chip, 512 KB flash, 200 KB RAM |
| **SDK** | [BXMicro SDK3](https://gitee.com/BXMicro/SDK3) |
| **Reference FW** | [atc1441/ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring) |
| **App protocol** | Documented in PulseLoop + Gadgetbridge |
| **Price** | $15–25 |

The manufacturer publishes firmware update images with no authenticity checks — upload whatever you want over BLE. Combined with SWD debugging, this is the closest thing to an open-source smart ring in production.

### 🥉 Protocol-Documented: the wider QRing family

- ✅ BLE protocol reverse-engineered (PulseLoop + Gadgetbridge)
- ✅ Nordic-UART based, unencrypted
- ✅ Custom app possible (PulseLoop already does it)
- ⚠️ Custom firmware: confirmed possible on R02/R03 (BXMicro); unknown for R10/R12 (Realtek RTL8762)
- **Price:** $15–30

---

See the [hardware overview](index.md) for the full cross-manufacturer comparison
tables, the [Jring / 56ff](jring.md) page for the cheaper option, or — if your Colmi came with the
SmartHealth app — the [TK5](tk5.md) page, whose driver it shares.
