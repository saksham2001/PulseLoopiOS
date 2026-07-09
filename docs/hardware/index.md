---
title: Supported Hardware
description: >-
  Hardware specs, capabilities, and hackability for every smart ring PulseLoop
  supports — shared across the iOS and Android ports.
---

# Supported Hardware

PulseLoop is built around a **device-agnostic driver layer**, so each supported
ring declares exactly what it can do and the app shows only those features. This
section breaks the hardware down by manufacturer.

!!! abstract "About these pages"
    This is a cross-platform reference shared by both the iOS and Android ports —
    they drive the same rings over the same reverse-engineered BLE protocols.
    Compiled from project documentation, web research, product pages, and
    teardowns. *Last updated: 2026-06-25.*

!!! warning "No affiliation"
    PulseLoop has no affiliation with the sellers or manufacturers of any ring
    listed here. Listings are for convenience only — links may break, sellers may
    swap hardware under the same name, and your unit may behave differently. Buy
    at your own risk and treat any data the ring produces as approximate.

## Browse by manufacturer

<div class="grid cards" markdown>

-   :material-ring: __Jring / 56ff__

    ---

    The $7–12 commodity ring (keeprapid OEM). Custom `56ff` protocol. The only
    PulseLoop-supported ring with blood pressure and blood sugar.

    [:octicons-arrow-right-24: Jring / 56ff](jring.md)

-   :material-ring: __Colmi / Yawell (QRing)__

    ---

    The $15–30 QRing family — R02/R0x/R1x/H59. Nordic-UART protocol, skin
    temperature, REM sleep, and continuous background sync.

    [:octicons-arrow-right-24: Colmi / Yawell](colmi.md)

-   :material-flask-outline: __TK5 / SmartHealth__

    ---

    🧪 Experimental. Custom `be940` protocol (SmartHealth app), reverse-engineered
    from a single capture — some metrics unverified, no encrypted login yet.

    [:octicons-arrow-right-24: TK5 / SmartHealth](tk5.md)

-   :material-help-circle-outline: __SIMSONLAB__

    ---

    Not supported — unknown protocol on a Phyplus PHY6222 SoC, with no public
    reverse engineering. Documented here for reference.

    [:octicons-arrow-right-24: SIMSONLAB](simsonlab.md)

-   :material-crown-outline: __Premium rings__

    ---

    Oura, Ultrahuman, and RingConn. Not currently supported (Ultrahuman's
    protocol is documented and on the roadmap). Documented for reference.

    [:octicons-arrow-right-24: Premium rings](premium.md)

</div>

## Supported Rings — Hardware Specs

!!! info "Legend"
    - ✅ — yes / supported
    - ❌ — no / not supported
    - 🧪 — implemented, needs testing / experimental
    - ❓ — unknown

|  | 56ff / Jring | Colmi R02/R03/etc | Colmi R10 | Colmi R12 | Colmi R11 | TK5 |
|---|---:|---:|---:|---:|---:|---:|
| **SoC** | Renesas DA14531 | Realtek RTL8762 | RTL8762 ESF | Realtek RTL8762 | Realtek AB2026 | ❓ |
| **Architecture** | ARM Cortex-M0 | ARM | ARM | ARM | ARM | ❓ |
| **Bluetooth** | BLE 5.x | BLE 5.0 | BLE 5.0 | BLE 5.0 | BLE 5.0 | BLE |
| **PPG sensor** | Unknown (HR/SpO₂) | Unknown | Vcare VC30F | Vcare VC30F | Vcare VC30F | ❓ |
| **PPG LEDs** | Unknown | Unknown | Red + green (dual) | Red + green (dual) | Red + green (dual) | Green + red/IR |
| **Accelerometer** | Yes | Unknown | STK8321 | ST LIS2DOC | STK8321 | Yes (❓ part) |
| **Skin temperature** | ❌ | ❓ | ✅ | ✅ | ✅ | ❌ |
| **Battery** | Unknown | Varies | 17 mAh | 15–18 mAh | 15–18 mAh¹ | ❓ |
| **Battery life** | Unknown | Varies | ~4–7 days | ~4–7 days | ~4–7 days | ❓ |
| **Charging case** | ❌ | ❌ | ✅ (200 mAh) | ❌ | ✅ (200 mAh) | ❓ |
| **Display** | ❌ | ❌ | ❌ | ✅ | ❌ | ❓ |
| **Waterproof** | Varies by seller | IP68 / 3ATM | 5ATM | IP68 + 1ATM | IP68 + 5ATM | ❓ |
| **Weight** | Unknown | Unknown | Unknown | ~4 g | Unknown | ❓ |
| **Price** | $7–12 | $15–25 | $15–25 | ~$30 | ~$15–25 | ❓ |
| **Protocol** | Custom 56ff | Nordic-UART QRing | Nordic-UART QRing | Nordic-UART QRing | Nordic-UART QRing² | Custom be940 |
| **Frame size** | Fixed 20 bytes | 16 bytes (checksum) | 16 bytes (checksum) | 16 bytes (checksum) | 16 bytes (checksum) | Variable (CRC16) |
| **Encryption** | None | None | None | None | None | None³ |
| **FW OTA** | ✅ Renesas SUOTA | ✅ BLE OTA (no sign) | ❓ | ❓ | ❓ | ❓ |
| **Custom firmware** | ✅ (SR08 ref) | ✅ (RF03 ref) | ❓ | ❓ | ❓ | ❓ |
| **PulseLoop support** | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |

¹ 15 mAh for sizes 8–9, 18 mAh for sizes 10–13.
² Works with the QRing app; also has a companion "Da Rings" app. Matched by Colmi driver.
³ TK5 data channels are cleartext. It also exposes a separate encrypted `AE00` login, which PulseLoop does not implement.

## Supported Rings — Capabilities

| Capability | 56ff / Jring | Colmi R02/etc | Colmi R10 | Colmi R12 | Colmi R11 | TK5 |
|---|---:|---:|---:|---:|---:|---:|
| Heart rate — spot | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Heart rate — history | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Heart rate — live | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| SpO₂ — history | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| SpO₂ — spot | ✅ | ❌¹ | ❌¹ | ❌¹ | ❌¹ | 🧪 |
| Steps / distance / calories | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Sleep (light/deep/awake) | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| REM sleep | ❌ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Blood pressure | ✅² | ❌ | ❌ | ❌ | ❌ | 🧪 |
| Blood sugar | ✅³ | ❌ | ❌ | ❌ | ❌ | ❌ |
| HRV | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Stress | ✅ | ✅ | ✅ | ✅ | ✅ | ❌⁴ |
| Fatigue | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Skin temperature | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Battery level | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Find device | ✅ | ✅ | ✅ | ✅ | ✅ | 🧪 |
| Continuous background sync | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| FW update via app | ✅ | ✅ | ❓ | ❓ | ❓ | ❓ |

¹ Colmi family has no on-demand SpO₂ reading; SpO₂ is all-day background only.
² Direct PPG sensor reading, no user profile required.
³ Profile-derived estimate from sex/age/height/weight, not a real glucometer reading.
⁴ The TK5 doesn't store stress — SmartHealth derives it from HRV app-side — so PulseLoop doesn't claim it.

## Not Supported by PulseLoop

| Ring | Reason |
|---|---|
| **SIMSONLAB LA380-YJ** | Unknown protocol (PHY6222 SoC), no reverse engineering — see [SIMSONLAB](simsonlab.md) |
| **Oura Gen 3/4** | Encrypted BLE, proprietary protocol, subscription required — see [Premium rings](premium.md) |
| **Ultrahuman Ring Air** | Not yet implemented (protocol is documented) — see [Premium rings](premium.md) |
| **RingConn Gen 2** | No public protocol, no reverse engineering — see [Premium rings](premium.md) |

---

## Platform Overview

Multiple hardware platforms span from $7 commodity rings to $350 premium devices:

### Budget / Commodity Rings

| Platform | SoC | Protocol | App | Price | Hackable |
|---|---|---|---|---|---|
| **[56ff / Jring](jring.md)** | Renesas DA14531 | Custom 56ff (SXR KeepFit SDK) | Jring / KeepFit | $7–12 | ✅ App + FW |
| **[Colmi / Yawell (QRing)](colmi.md)** | Realtek RTL8762 family | Nordic-UART (QRing) | QRing | $15–30 | ✅ App (R02 FW too) |
| **[Colmi R11](colmi.md#colmi-r11-qring-compatible-with-fidget-shell)** | Realtek AB2026 | Nordic-UART QRing | QRing / Da Rings | ~$15–25 | ✅ App (untested) |
| **[SIMSONLAB](simsonlab.md)** | Phyplus PHY6222 | Unknown | SIMSONLAB app | ~$10–20 | ❌ |

### Premium Rings

| Platform | SoC | Protocol | App | Price | Subscription | Hackable |
|---|---|---|---|---|---|---|
| **[Oura Gen 4](premium.md#oura-ring-gen-3-gen-4)** | Nordic nRF52840 | Encrypted proprietary | Oura app | $349 | **$5.99/mo required** | ❌ |
| **[Ultrahuman Ring Air](premium.md#ultrahuman-ring-air)** | nRF52840 + STM32G0 | Documented (Gadgetbridge) | Ultrahuman | $349 | ❌ None | ✅ App protocol |
| **[RingConn Gen 2 Air](premium.md#ringconn-gen-2-gen-2-air)** | Unknown (Nordic likely) | Proprietary | RingConn | $199 | ❌ None | ❌ |

---

## Hackability Summary

A breakdown of which rings can be used with custom software or firmware. For the
full detail, see each manufacturer's page.

| Ring | Custom App | Custom Firmware | Price |
|---|---|---|---|
| **[Colmi R02/R03](colmi.md)** | ✅ PulseLoop, Gadgetbridge | ✅ OTA, SWD, SDK | $15–25 |
| **[56ff / Jring](jring.md)** | ✅ PulseLoop, Gadgetbridge | ✅ SUOTA, open-source FW | $7–12 |
| **[Colmi R10/R12](colmi.md)** | ✅ PulseLoop, Gadgetbridge | ❓ Unknown (Realtek locked?) | $15–30 |
| **[Ultrahuman Ring Air](premium.md#ultrahuman-ring-air)** | ✅ Gadgetbridge protocol | ❌ nRF locked | $349 |
| **[RingConn Gen 2](premium.md#ringconn-gen-2-gen-2-air)** | ❌ No public protocol | ❌ | $199–299 |
| **[Oura Ring](premium.md#oura-ring-gen-3-gen-4)** | ❌ Encrypted BLE | ❌ | $349 + sub |
| **[SIMSONLAB](simsonlab.md)** | ❌ Unknown protocol | ❌ | $10–20 |

### Open-Source DIY Platforms

| Project | Detail |
|---|---|
| **[Open Ring](https://github.com/stawiski/open-ring)** | Open-source hardware + firmware reference design |
| **KuoQuo's smart ring dev board** | nRF-based I2C sensor platform, designed for firmware hacking |
| **[ATC_SR08_Ring](https://github.com/atc1441/ATC_SR08_Ring)** | Open-source firmware for 56ff/Jring hardware |
| **[ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring)** | Open-source firmware for Colmi R02/R03 hardware |
| **[ringverse/protocol](https://github.com/ringverse/protocol)** | Community reverse engineering of smart ring protocols |

---

## Quick Comparison

### Sensor quality

| | VC30F (Colmi R10/R12) | HX3602 (SIMSONLAB) | Unknown PPG (56ff) |
|---|---|---|---|
| **LEDs** | Red + green (dual) | Unknown | Unknown |
| **SpO₂ capable** | ✅ (red LED) | ❓ | ✅ |
| **Datasheet** | Public (JLCPCB) | None found | None found |
| **Verified accuracy** | ±1 BPM vs medical device | No testing found | No testing found |

### Chipset comparison

| | DA14531 (56ff) | RTL8762 (Colmi QRing) | AB2026 (Colmi R11) | PHY6222 (SIMSONLAB) |
|---|---|---|---|---|
| **Vendor** | Renesas | Realtek | Realtek | Phyplus |
| **Architecture** | ARM Cortex-M0 | ARM | ARM | ARM Cortex-M0 |
| **Bluetooth** | BLE 5.x | BLE 5.0 | BLE 5.2 | BLE 5.1 |
| **Memory** | Unknown | Unknown | Unknown | 512 KB built-in |
| **Known from** | Jring, KeepFit, RWfit, Tag | Colmi R02–R10, R12, Yawell | Colmi R11 | SIMSONLAB LA380-YJ, various watches |

### Which to choose?

| If you want... | Pick |
|---|---|
| **Cheapest possible** ($7–12) | [56ff / Jring](jring.md) |
| **Most sensors** (temp, HRV, REM, stress) | [Colmi R10 or R12](colmi.md) ($15–30) |
| **Best battery** | [Colmi R10](colmi.md) (17 mAh + 200 mAh case, no display) |
| **On-ring display** | [Colmi R12](colmi.md) |
| **Best waterproofing** | [Colmi R10 or R11](colmi.md) (5ATM) |
| **Best HR accuracy** | [Colmi R10/R12](colmi.md) (VC30F sensor, verified accuracy) |
| **Works with PulseLoop today** | [56ff Jring](jring.md) or [Colmi QRing family](colmi.md) |

---

## References

- **56ff protocol reverse-engineering writeup**: [sakshambhutani.xyz/hacking/2_hacking/](https://sakshambhutani.xyz/hacking/2_hacking/)
- **PulseLoop protocol docs** (in the iOS repo): `docs/ring-protocol.md`, `docs/protocol-discoveries.md`, `docs/keepfit-protocol-complete.md`
- **Gadgetbridge Yawell/Colmi page**: [gadgetbridge.org/gadgets/wearables/yawell/](https://gadgetbridge.org/gadgets/wearables/yawell/)
- **Gadgetbridge KeepFit PR**: [#5326](https://codeberg.org/Freeyourgadget/Gadgetbridge/pulls/5326)
- **Open-source ring firmware**: [atc1441/ATC_SR08_Ring](https://github.com/atc1441/ATC_SR08_Ring)
- **Official KeepFit SDK/protocol**: [keeprapid/krwatch](https://github.com/keeprapid/krwatch)
- **Ring reverse engineering**: [ringverse/protocol](https://github.com/ringverse/protocol)
- **Colmi R12 review** (Walter Shillington, Medium, 2026-03-05)
- **Colmi R10 review** (ShaunChng.com)
- **SIMSONLAB LA380-YJ user manual** (device.report)
- **PHY6222 datasheet** (Phyplus Technologies)
- **Yawell company profile**: [yawellfit.com](https://www.yawellfit.com/p/about.html)
- **Colmi official**: [colmi.com](https://www.colmi.com/), [colmi.info](https://www.colmi.info/)
- **Ultrahuman Protocol (Gadgetbridge)**: [gadgetbridge.org/internals/specifics/ultrahuman-protocol/](https://gadgetbridge.org/internals/specifics/ultrahuman-protocol/)
- **Hackaday — Hackable Smart Ring**: [New Part Day: A Hackable Smart Ring](https://hackaday.com/2024/06/16/new-part-day-a-hackable-smart-ring/)
- **ATC_RF03_Ring (custom FW for Colmi R02)**: [github.com/atc1441/ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring)
- **Open Ring (open-source HW/FW)**: [github.com/stawiski/open-ring](https://github.com/stawiski/open-ring)
- **Ultrahuman Ring Air teardown**: [makingstudio.blog](https://makingstudio.blog/2024/09/10/ultrahuman-ring-air-teardown/)
- **Oura Ring teardown (Becky Stern)**: [beckystern.com](https://beckystern.com/2022/04/17/oura-ring-teardown-gen-3-and-gen-2/)
- **Oura Ring 4 deep-dive (EDN)**: [edn.com](https://www.edn.com/the-oura-ring-4-does-one-more-deliver-much-if-any-more/)
- **Wareable best smart rings 2026**: [wareable.com](https://www.wareable.com/fashion/best-smart-rings-1340)
