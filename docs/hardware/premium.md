---
title: Premium Rings
description: >-
  Oura, Ultrahuman, and RingConn — premium rings not currently supported by
  PulseLoop. Ultrahuman's protocol is documented and on the roadmap.
---

# Premium Rings

**PulseLoop support: ❌ Not currently supported**

These rings compete with Oura on hardware quality but mostly without the
subscription lock-in. None are supported by PulseLoop today, though the
[Ultrahuman Ring Air](#ultrahuman-ring-air) is the most promising candidate — its
protocol is fully documented and it's on the [roadmap](../project/roadmap.md).

| Ring | Why it isn't supported (yet) |
|---|---|
| **Oura Gen 3/4** | Encrypted BLE, proprietary protocol, subscription required |
| **Ultrahuman Ring Air** | Not yet implemented — but the protocol *is* documented |
| **RingConn Gen 2 / Air** | No public protocol, no reverse engineering |

## Oura Ring (Gen 3 / Gen 4)

| Component | Gen 3 (2021) | Gen 4 (2024) |
|---|---|---|
| **SoC** | Nordic nRF52840 (Cortex-M4F, 64 MHz, 1 MB flash, 256 KB RAM) | Nordic nRF52840 |
| **PPG** | 2× green LED + red/IR multi-chip LED + 2× photodiodes | 2 clusters × green/red/IR LEDs + 3× photodiodes, 18-path multi-wavelength |
| **Temperature** | NTC thermistor (indirect) | NTC thermistor (indirect) |
| **Accelerometer** | 3-axis | 3-axis |
| **Battery** | 16 mAh (Grepow YE160723G) | 26 mAh |
| **Battery life** | 4–7 days | Up to 8 days |
| **Battery management** | TI BQ25120A | Unknown |
| **Charging** | Wireless inductive | Wireless inductive |
| **Price** | $299+ (discontinued) | $349 + **$5.99/mo subscription required** |
| **BLE** | Encrypted, proprietary | Encrypted, proprietary |
| **Open docs** | ❌ Completely closed | ❌ Completely closed |

**Hackability:** ❌ Fully locked down — encrypted BLE, proprietary protocol, no
public docs, subscription-gated features.

## Ultrahuman Ring Air

| Component | Detail |
|---|---|
| **BLE SoC** | Nordic nRF52840 (Cortex-M4F, 64 MHz, 1 MB flash, 256 KB RAM, BLE 5.0) |
| **Coprocessor** | STM32G0 (STMicro) — dedicated sensor DSP |
| **Sensors** | PPG (HR, HRV, SpO₂), skin temperature, 3-axis accelerometer |
| **Battery** | ~4–6 days |
| **Price** | $349, **no subscription** |
| **Open docs** | ✅ BLE protocol fully documented by Gadgetbridge |

**Dual-MCU architecture:** The nRF52840 handles BLE + main processing, while the STM32G0 coprocessor runs sensor data processing and power management — arguably more capable than Oura's single-MCU design.

**BLE Protocol (Gadgetbridge):**

- Device name: `UH_XXXXXXXXXXXXXXXX`
- Device State service: `86f61000-f706-58a0-95b2-1fb9261e4dc7` — battery level, charging state, temperature
- Command service: `86f65000-f706-58a0-95b2-1fb9261e4dc7` — opcodes for set time, get recordings, airplane mode, reset, power saving
- All opcodes and payload formats documented

**Hackability:** 🥈 Protocol-documented.

- ✅ Full BLE protocol documented on [Gadgetbridge](https://gadgetbridge.org/internals/specifics/ultrahuman-protocol/)
- ✅ Every service UUID, opcode, and payload layout is public
- ✅ You can write a custom app that talks directly to the ring — no vendor app needed
- ❌ Custom firmware unlikely — nRF52840 typically has readback protection enabled

!!! tip "On the roadmap"
    Because the Ultrahuman protocol is fully public, it's the most realistic
    premium ring for PulseLoop to add next. See the
    [roadmap](../project/roadmap.md).

## RingConn Gen 2 / Gen 2 Air

| Component | Detail |
|---|---|
| **Sensors** | PPG (HR, HRV, SpO₂), skin temperature, 3-axis accelerometer |
| **Battery** | 10+ days (class-leading) |
| **Price** | Gen 2: $299 / Gen 2 Air: **$199**, **no subscription** |
| **Open docs** | ❌ No known reverse engineering or public protocol docs |

**Hackability:** ❌ Fully locked down — no known reverse engineering, no public
protocol docs.

## Premium Ring Comparison

| | Oura Gen 4 | Ultrahuman Air | RingConn G2 Air |
|---|---|---|---|
| **SoC** | nRF52840 | nRF52840 + STM32G0 | Unknown (likely Nordic) |
| **Architecture** | Cortex-M4F | Cortex-M4F + Cortex-M0 | Unknown |
| **PPG** | Custom 18-path | Multi-LED | Multi-LED |
| **Temperature** | NTC thermistor | ✅ Skin temp | ✅ Skin temp |
| **Battery** | 8 days | 4–6 days | 10+ days |
| **Subscription** | **$5.99/mo required** | ❌ None | ❌ None |
| **Price** | $349 + sub | $349 | $199 |
| **Protocol open** | ❌ | ✅ (Gadgetbridge) | ❌ |
| **Custom firmware** | ❌ | ❌ (nRF locked) | ❌ |

---

See the [hardware overview](index.md) for the rings PulseLoop currently supports.
