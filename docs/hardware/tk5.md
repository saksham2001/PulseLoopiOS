---
title: TK5 / SmartHealth
description: >-
  The TK5 ring (SmartHealth app) — experimental support on a custom be940
  protocol, reverse-engineered from a single capture. Several fields unverified.
---

# TK5 / SmartHealth

**PulseLoop support: 🧪 Experimental — limited support, reverse-engineered from a single capture**

The TK5 pairs with the **SmartHealth** app (`com.zhuoting.healthyucheng`) and speaks its own
`be940` BLE protocol — nothing in common at the wire level with the [56ff / Jring](jring.md) or
[Colmi / Yawell](colmi.md) families. PulseLoop's driver was reconstructed from **one** Android
btsnoop HCI capture, which is why it is the only ring here that isn't marked as supported.

!!! warning "Experimental — limited support"
    This driver came from a single packet capture. Some byte offsets are **inferred rather than
    confirmed**, skin temperature and stress aren't decoded at all, and the ring's encrypted `AE00`
    login isn't implemented. Every decoded metric is range-gated before it's stored, so a misdecode
    is dropped rather than saved as garbage — but expect gaps, and treat TK5 readings as approximate.

    If you own one, a second capture (especially one containing temperature) would settle most of
    the open questions. See [Contributing](../project/contributing.md).

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
| **Protocol** | Custom `be940`, variable-length frames, CRC16/CCITT-FALSE, cleartext |
| **App** | SmartHealth (`com.zhuoting.healthyucheng`) |
| **Advertised name** | `TK5 <4 hex>` — e.g. `TK5 24AA` |
| **Custom firmware** | ❓ Unknown |

## Protocol

| Property | Value |
|---|---|
| **Service** | `be940000-7333-be46-b7ae-689e71722bd5` |
| **Command char** | `be940001` — write **and** indicate (the app writes here and gets replies here) |
| **Stream char** | `be940003` — indicate: live HR / SpO₂ / steps and downloaded history records |
| **Frame** | `[type:1][cmd:1][len:2 LE][payload:N][crc16:2 LE]`, `len` = total frame length |
| **CRC** | CRC16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no reflection), little-endian |
| **Epoch** | Seconds since 2000-01-01, in the ring's **local wall-clock** (no timezone concept) |
| **Encryption** | Data channels are cleartext; a separate `AE00` login exists but is **not implemented** |

Full byte-level teardown: [TK5 protocol notes](tk5-protocol.md).

## Capabilities

Everything PulseLoop reads from the TK5 is 🧪 — implemented from one capture, needs testing on
more hardware.

| Capability | Status | Notes |
|---|:---:|---|
| Heart rate — spot | 🧪 | proprietary `06 01` stream; the standard `180D` char is ignored (see below) |
| Heart rate — live | 🧪 | |
| Heart rate — history | 🧪 | hourly, from `05 15` records |
| SpO₂ — spot | 🧪 | red/IR LED, `03 2f` mode `02` |
| SpO₂ — history | 🧪 | hourly, from `05 18` records |
| Steps / distance / calories | 🧪 | live push while connected; distance/calories offsets unverified |
| Sleep (light/deep/awake) | 🧪 | `05 13` timeline, matched to the app's own breakdown |
| REM sleep | 🧪 | |
| HRV | 🧪 | spot (`03 2f` mode `0a`) and hourly history |
| Blood pressure | 🧪 | periodic + live; no cuff calibration, so treat as a trend, not a number |
| Battery level | 🧪 | in-band; byte offset unverified, clamped to 0–100 |
| Find device | 🧪 | best-effort — no confirmed vibrate command in the capture |
| Stress | ❌¹ | |
| Skin temperature | ❌ | monitoring is enabled on connect, but no capture contains the data |
| Blood sugar | ❌ | |
| Continuous background sync | ❌ | live stream only while connected |
| FW update via app | ❓ | |

¹ The ring doesn't store stress — SmartHealth derives it from HRV app-side — so PulseLoop doesn't
claim it rather than show an empty card.

## Known limitations

- **Single-capture provenance.** Offsets tagged `UNVERIFIED` in the driver source are inferred from
  one session. They're range-gated, but they haven't been confirmed against a second device.
- **No encrypted login.** The ring exposes a separate `AE00` service with a `fedcba`/`"pass"`
  handshake that PulseLoop doesn't implement. Live data and history flowed in plaintext without it
  in the capture; if a unit turns out to gate them behind that login, this is why nothing arrives.
- **Standard heart-rate service is deliberately ignored.** The TK5 exposes `180D`/`2A37`, but it
  emits a cached resting HR (~87 bpm) even off-finger, which would mask real readings. Live HR comes
  solely from the proprietary `06 01` stream, as in the official app.
- **Timestamps are timezone-naive.** The ring stores local wall-clock seconds with no timezone byte,
  so the decoder un-applies the device's UTC offset to recover the true instant. This is exact for
  same-session syncs and can be an hour off across a DST transition.

---

See the [hardware overview](index.md) for the cross-manufacturer comparison, or the
[TK5 protocol notes](tk5-protocol.md) for framing, commands, and GATT handles.
