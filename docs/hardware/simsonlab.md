---
title: SIMSONLAB
description: >-
  The SIMSONLAB LA380-YJ — not supported by PulseLoop. Unknown protocol on a
  Phyplus PHY6222 SoC with no public reverse engineering.
---

# SIMSONLAB

**PulseLoop support: ❌ Not supported (this model)**

!!! tip "SIMSONLAB sells more than one ring — the LuckRing-app ones *are* supported"
    SIMSONLAB is a retail brand (SHARE AUDIO HONG KONG LIMITED) that sources rings from at least two
    OEMs. This page is about the **LA380-YJ** (a Phyplus PHY6222 ring on an unknown protocol, paired
    with the *SIMSONLAB* app), which is not supported. The SIMSONLAB-branded rings that pair with the
    **LuckRing** app are a different OEM's hardware (Shenzhen Coolwear/Kewo, advertising as `TK18`) and
    **are** supported — see **[LuckRing / TK18](luckring.md)**. Check which app your ring came with.

The SIMSONLAB LA380-YJ uses a completely different, undocumented BLE protocol on a
Phyplus PHY6222 SoC. There's no public reverse engineering, so it isn't
compatible with any of PulseLoop's existing drivers. It's documented here for
reference and in case the protocol is ever decoded.

!!! warning "Why it isn't supported"
    Unknown, custom BLE protocol — different from both the `56ff` and QRing
    families — with no public reverse engineering or datasheet to work from.

## Manufacturer

- **SHARE AUDIO HONG KONG LIMITED** (developer of SIMSONLAB app)
- Product appears on Shein, AliExpress, TikTok
- Model: **LA380-YJ** (2025)

## Hardware

| Component | Detail |
|---|---|
| **CPU** | Phyplus PHY6222 |
| **SoC architecture** | ARM Cortex-M0 32-bit |
| **Bluetooth** | BLE 5.1 |
| **Memory** | 512 KB built-in, 64 KB SRAM, 128 KB–8 MB flash |
| **HR sensor** | HX3602 |
| **Battery** | 15 mAh (magnetic charging) |
| **Standby** | 10–15 days |
| **Weight** | ~5 g |
| **Material** | Stainless steel outer, epoxy resin body |
| **Waterproof** | IP68 |
| **App** | SIMSONLAB app (iOS + Android) |

## Protocol

- **Unknown** — completely different from both 56ff and QRing
- Custom BLE protocol (likely)
- Not compatible with PulseLoop's existing drivers

## HX3602 Sensor

- Generic/low-cost heart rate sensor
- Used across many cheap Chinese wearables (SIMSONLAB rings, NKX19 watches, DaintyDelight smartwatches)
- No standalone public datasheet found
- LED configuration unknown (likely single wavelength vs VC30F's dual red+green)
- No independent accuracy testing available

---

See the [hardware overview](index.md) for the rings PulseLoop *does* support.
