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

!!! warning "Set the ring up in the official Jring app first"
    Pair and initialize the ring once with the original **Jring / KeepFit** app
    before connecting it to PulseLoop. First-time setup sends some device
    initialization commands that we haven't fully reverse-engineered yet; without
    that one-time setup a fresh ring may not stream all data correctly to
    PulseLoop. After it's been set up once, PulseLoop can connect to it directly.

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

- Version format: `003A002AV138` — an 8-hex **family code** (`003A002A`) + `V` + version number. The family code identifies the specific hardware variant.
- Update manifest: `http://download.keeprapid.com/apps/smartband/keepfit/fwupdater/{en|zh}/{family}/update.json` — returns the latest version, the binary URL, and its MD5.
- Binary: `http://download.keeprapid.com/apps/smartband/keepfit/fwrelease/{family}/V{n}.bin` — a Renesas/Dialog SUOTA image.
- Flashing: Renesas SUOTA (`0xFEF5` service) to the DA14531.
- **All firmware traffic is plain HTTP with no token or signature — integrity is an MD5 only.**

## History sync

PulseLoop pulls history the way the vendor app (`com.jaga.ibraceletplus.jyring`)
does: **one day at a time**, oldest first.

| Request | Answer | Transfer ends on |
|---|---|---|
| `10 dd` — steps + sleep | `0x10` steps / `0x11` sleep packets: LE u32 time at [1..4], then 15 one-minute values | 2 s with no new packet, or `0x90` (refused) |
| `16 dd` — heart rate | `F0` header (segment count), `AA` segment, `A0` data blocks | `FF`, the last segment's last `A0` block, or `0x96` (refused) |

`dd` is 0 = today … 6. The frames are 20 bytes, zero padded.

- **How far back.** On connect, the sync starts at the number of calendar days
  since this ring's last *finished* sync, capped at 6. A ring never synced here
  gets all 6 days. This matches the vendor's `DupMainActivity.autoSync`.
- **Chaining.** Each day runs `10 dd` → `16 dd`, then moves to the next-newer
  day. After day 0 the app shows "done" — once per sync, not once per day.
- **Sync point.** The time the sync *started* is saved per ring, but only when
  every step ended on the ring's own terminator. If the ring goes silent for
  10 s, that step is skipped and the next sync re-reads the same days. Forgetting
  the ring clears its sync point.
- **No 300 s gap.** The vendor skips a sync that starts within 300 s of the last
  one. PulseLoop always reads at least today, because a manual sync must finish
  with "done". Re-reading a day is idempotent.
- **Steps** come down as one 15-minute bucket per `0x10` packet. Buckets are
  upserted by start time and summed per day. The packet has no distance, so a
  day's distance comes only from the live `0x03` total.
- **Post-workout** backfill sends only today's `16 00`.
- **Not pulled yet:** temperature (`39 dd`), offline SpO₂ (`40 dd`), pressure
  (`55 dd`) and multi-sport (`25 dd`). The vendor sends these only on rings whose
  `0x20` capability reply lists them, and PulseLoop has no decoders for their
  replies yet.

!!! danger "Never send `0E 12 34 12 34 12 34 12 34`"
    That frame is a factory reset. Other `0E` frames are OTA, power-off and
    restart. PulseLoop sends no `0x0E` frame at all.

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
