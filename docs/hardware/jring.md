---
title: Jring / 56ff
description: >-
  The $7–12 commodity smart ring (keeprapid OEM) with the custom 56ff protocol —
  the only PulseLoop-supported ring with blood pressure and blood sugar.
---

# Jring / 56ff

**PulseLoop support: ✅ Supported & tested**

The cheapest ring PulseLoop drives — a $7–12 commodity device built by the
keeprapid OEM and white-labeled under many brands. It speaks a custom `56ff` BLE
protocol and is the **only** PulseLoop-supported ring that reports blood pressure
and (profile-derived) blood sugar.

## At a glance

| | Detail |
|---|---|
| **SoC** | Renesas DA14531 (ARM Cortex-M0) |
| **Bluetooth** | BLE 5.x |
| **PPG sensor** | Unknown (HR/SpO₂, no skin temperature) |
| **Accelerometer** | Yes |
| **Battery / life** | Unknown |
| **Waterproof** | Varies by seller |
| **Price** | $7–12 |
| **Protocol** | Custom 56ff (SXR KeepFit SDK), fixed 20-byte frames, cleartext |
| **App** | Jring / KeepFit |
| **Custom firmware** | ✅ Renesas SUOTA (SR08 reference) |

## Manufacturer

- **keeprapid.com** (ShenXinRui / 深新锐) — Chinese OEM
- White-labels under brands: **Jring, KeepFit, JYouPro, RWfit, Tag**
- SDK: SXR KeepFit SDK (`com.sxr.sdk.ble.keepfit`)

## Hardware

| Component | Detail |
|---|---|
| **SoC** | Renesas DA14531 (Dialog DA145XX family) |
| **SoC architecture** | ARM Cortex-M0 |
| **PPG sensor** | Unknown (PPG HR/SpO₂, no skin temperature) |
| **Accelerometer** | Yes (steps, sleep stages, activity) |
| **Memory** | Unknown |
| **Weight** | Unknown |
| **Waterproof** | Unknown (varies by seller) |

## Protocol

The `56ff` protocol was reverse-engineered from scratch — see the
[full writeup](https://sakshambhutani.xyz/hacking/2_hacking/) for the BLE
teardown and how the packet formats were decoded.

| Property | Value |
|---|---|
| **Service UUID** | `000056ff-0000-1000-8000-00805f9b34fb` |
| **Write characteristic** | `000033f3-...` |
| **Notify characteristic** | `000033f4-...` |
| **Additional chars** | `0x33F5`, `0x33F6` (purpose unknown) |
| **Secondary service** | `0x57FF` |
| **SUOTA service** | `0000fef5-...` (firmware OTA) |
| **Frame size** | Fixed 20 bytes |
| **Encryption** | None (cleartext) |
| **Standard BLE services** | DIS (`0x180A`), Heart Rate Service (`0x180D`) |

## Capabilities

| Capability | Status | Notes |
|---|:---:|---|
| Heart rate — spot / live / history | ✅ | BPM |
| SpO₂ — spot / history | ✅ | |
| Steps / distance / calories | ✅ | |
| Sleep (light / deep / awake) | ✅ | No REM |
| Blood pressure | ✅ | Direct sensor reading via `0x23`/`0x24`, no user profile required |
| Blood sugar | ✅ | Profile-derived estimate (not a real glucometer) — requires user profile |
| Stress | ✅ | 0–100 |
| Fatigue | ✅ | 0–100 |
| HRV | ✅ | ms |
| Battery level | ✅ | |
| Find device | ✅ | |
| REM sleep | ❌ | |
| Skin temperature | ❌ | No sensor — official app shows 0°C/32°F placeholder |
| Continuous background sync | ❌ | Command-response only, ~20s idle timeout |

!!! info "Blood sugar requires a user profile"
    Blood sugar is a profile-derived *estimate* from sex/age/height/weight (sent
    via `0x02` `CMD_SET_USER_INFO`), not a real glucometer reading — changing the
    profile changes the value.

### What the 56ff ring CANNOT do

- REM sleep detection
- Body temperature (no skin temperature sensor)
- Continuous streaming (command-response only, ~20s idle timeout)

## Known models

- **SR08** — open-source reference hardware ([atc1441/ATC_SR08_Ring](https://github.com/atc1441/ATC_SR08_Ring))
- Generic "SMART_RING" — sold on AliExpress for $7–12

## Firmware

- Firmware check: `http://download.keeprapid.com/apps/smartband/jring/autoupdater/{device_id}/update.json`
- Binary download: `http://download.keeprapid.com:8181/docs/jring/an_{p1}_{p2}1`
- Flashing: Renesas SUOTA (`0xFEF5` service) to DA14531
- Version format: `"003A002AV138"` (status hex + V + version number)
- **All API traffic is HTTP (not HTTPS) — unencrypted**

## Background behavior

- Idle timeout: ~20 seconds of inactivity
- Keepalive: `0x3A` ping/pong
- Binding: `0x4B` custom protocol (NOT OS `createBond()`)
- Official app runs periodic background sync

## Hackability

**🥈 Protocol-Documented**

- ✅ Protocol fully reverse-engineered ([writeup](https://sakshambhutani.xyz/hacking/2_hacking/); also the iOS repo's `docs/ring-protocol.md`)
- ✅ Open-source firmware skeleton: [atc1441/ATC_SR08_Ring](https://github.com/atc1441/ATC_SR08_Ring)
- ✅ Official SDK protocol doc: `深新锐蓝牙协议v3.0.docx` (keeprapid/krwatch)
- ✅ Cleartext BLE, no encryption
- ✅ Renesas SUOTA for firmware OTA
- **Price:** $7–12

---

See the [hardware overview](index.md) for the full cross-manufacturer comparison
tables, or the [Colmi / Yawell](colmi.md) family for the more sensor-rich option.
