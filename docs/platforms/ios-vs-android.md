---
title: iOS vs Android
description: >-
  A living comparison of where the PulseLoop iOS and Android ports differ —
  protocol coverage, settings, UI, and architecture.
---

# iOS vs Android

The iOS and Android ports of PulseLoop are developed hand in hand and share the
same reverse-engineered BLE protocol work. They're not identical, though — each
platform sometimes lands a feature first. This page is a **living comparison** of
where they currently differ.

!!! note "This is a snapshot"
    Things change fast. When a feature lands on both ports, it leaves this page.
    *Last updated: 2026-06-25.* For the canonical state, check each repo:
    [iOS](https://github.com/saksham2001/PulseLoopiOS) ·
    [Android](https://github.com/foureight84/PulseLoopAndroid).

Today, the Android port is ahead in a few areas — fuller protocol decoding, ring
configuration/calibration, connection reliability, and richer vitals UI. The
sections below break that down.

## Protocol & Ring Communication

### Extended 0x24 Combined Sensor Decoding

iOS only decodes bytes[1]-[4] (HR + systolic + diastolic + SpO₂) from the `0x24` combined
measurement packet. Android decodes the full 9 bytes — matching the official Jring app's
`onReceiveSensorData(i, i2, i3, i4, i5, i6, i7, i8)`:

| Byte | Metric | iOS | Android |
|------|--------|:---:|:-------:|
| 1 | Heart Rate (BPM) | ✅ | ✅ |
| 2 | Systolic (mmHg) | ✅ | ✅ |
| 3 | Diastolic (mmHg) | ✅ | ✅ |
| 4 | SpO₂ (%) | ✅ | ✅ |
| 5 | **Fatigue** (0–100) | — | ✅ |
| 6 | **Stress** (0–100) | — | ✅ |
| 7 | **Blood Sugar** (mmol/L ×10 → mg/dL) | — | ✅ |
| 8 | **HRV** (ms) | — | ✅ |

**iOS also mislabels the opcodes:** `spo2ResultProgress = 0x24` and `spo2Complete = 0x28`.
These are actually combined sensor data and blood data per the APK decompilation — not
SpO₂-only packets. The separate SpO₂ commands are `0x3E`/`0x3F`.

### Ring Configuration Commands (Android-only)

| Command | Opcode | Purpose |
|---------|--------|---------|
| **User profile** | `0x02` | Sends age/sex/height/weight to ring. Android pushes real profile from Settings on every connect; iOS sends hardcoded defaults (age 25, male, 184cm, 90kg) with no way to configure. |
| **BP calibration** | `0x33` | Sends reference systolic/diastolic to ring for on-device offset correction. iOS has no equivalent. |
| **App identity** | `0x48` | Claims the ring with a persistent app ID so it streams data to PulseLoop. Prevents mute behavior after another app claimed the ring. iOS doesn't send this. |
| **Bind/unbind** | `0x4B` | Ring-driven pairing handshake (INIT → APP_START → ACK → SUCCESS). Proper unbind (UNBOND → UNBOND_ACK) on Forget so the ring re-advertises for other apps. iOS has no bind protocol. |
| **Keepalive ping** | `0x3A` | Prevents ring's ~20s idle disconnect. Android pings every 15s. iOS has no keepalive. |

### Connection Reliability (Android-only)

- **Keepalive ping** — 15s interval prevents ring idle timeout
- **Write ACK timeout** — 3s timeout unblocks command queue on missed ACKs
- **Connection watchdog** — monitors GATT activity, forces reconnect after 10–20s silence
- **Foreground reconnection** — reconnects on app resume if GATT dropped during sleep
- **Stale-state guard** — resets persisted connection state on app restart
- **Force-close stale GATT** — explicitly disconnects/closes orphaned handles before new connection
- **No OS-level bonding** — avoids Bluetooth status-bar icon and OS-level pairing instability
- **High-priority connection interval** — requests priority on connect
- **Firmware discovery** — scans all BLE services for firmware characteristics, not just standard DIS

## Settings & Calibration

### User Profile

| | iOS | Android |
|---|---|---|
| **Profile form** | Not configurable — hardcoded defaults always sent | Full form (age, sex, height, weight) in Settings |
| **Stored on-device** | N/A | Room database, never transmitted off-device |
| **Synced to ring** | Only hardcoded defaults at startup | Real profile pushed on connect + on save |
| **Colmi handling** | N/A | Form hidden with notice explaining Colmi doesn't need it |

### BP Calibration

| | iOS | Android |
|---|---|---|
| **Cuff reference entry** | Not available | Systolic/diastolic fields in Settings |
| **Sent to ring** | N/A | `0x33` command for on-device offset |
| **App-side display** | N/A | Applied in ViewModels |

### Blood Sugar Calibration

| | iOS | Android |
|---|---|---|
| **Lab reference entry** | Not available | mg/dL field + Calibrate button in Settings |
| **Offset method** | N/A | `glucoseOffsetMgdl = ref - latestRaw` |
| **Reset** | N/A | Reset button to clear calibration |

## UI Differences

### Vitals Dashboard

| Feature | iOS | Android |
|---------|:---:|:---:|
| Threshold bars on every metric panel | — | ✅ Color-coded (Good → Normal → Borderline → High) |
| Tap-through detail screens per metric | — | ✅ Full trend view with period selector |
| Zone-colored trend charts | — | ✅ Data points colored by threshold zone |
| Range/avg summaries on panels | — | ✅ `Range: min – max · Avg: avg` |
| Combined measurement button | — | ✅ One-tap BP+SpO₂+stress+fatigue+BS with countdown |
| Pull-to-refresh | — | ✅ Triggers immediate ring sync |

### Vitals Detail (tap on any metric)

| Feature | iOS | Android |
|---------|:---:|:---:|
| Period selector (Today / Week / Month) | — | ✅ |
| Date navigator (← → arrows) | — | ✅ |
| Trend arrow + text (rising/falling/stable) | — | ✅ |
| Stat tiles (Latest · Avg · Min · Max) | — | ✅ |
| Threshold bar with zone legend | — | ✅ |
| Metric explainer text | — | ✅ |
| Medical disclaimer card | — | ✅ |

### Colmi Ring Handling

| Feature | iOS | Android |
|---------|:---:|:---:|
| BP/blood sugar panels hidden for Colmi | — | ✅ Capability-gated in Today and Vitals |
| Profile/calibration form hidden for Colmi | — | ✅ Notice explaining features are 56ff-only |
| Measure button hidden for Colmi | — | ✅ Gated on `supportsBP || supportsGlucose` |
| Colmi capabilities correctly declared | — | ✅ Fixed (was incorrectly including BP/BS) |

### Ring Management

| Feature | iOS | Android |
|---------|:---:|:---:|
| Proper unbind on forget | — | ✅ `0x4B` UNBOND → UNBOND_ACK before teardown |
| Connection state display | — | ✅ Live status with battery % in Settings |
| Firmware version display | — | ✅ Parsed from `0x0C`/`0xF6` + standard DIS |

### Sleep View

| Feature | iOS | Android |
|---------|:---:|:---:|
| Sleep stage breakdown (Deep/Light/Awake %) | — | ✅ Color-coded percentage pills |
| Sleep coach insights | — | ✅ Contextual chip-based recommendations |
| Sleep duration histogram chart | — | ✅ |
| Sleep architecture stages chart | — | ✅ |

### Activity View

| Feature | iOS | Android |
|---------|:---:|:---:|
| MetricThreshold reference ranges | — | ✅ Color-coded for steps/calories/distance/active minutes |
| Active minutes card with trend | — | ✅ |

### Settings Screen

| Feature | iOS | Android |
|---------|:---:|:---:|
| Profile (age/sex/height/weight) | — | ✅ |
| BP calibration (systolic/diastolic) | — | ✅ |
| Blood sugar calibration (mg/dL offset) | — | ✅ |
| Unit system toggle (Metric / Imperial) | — | ✅ |
| Profile sync to ring on save | — | ✅ |
| Demo data seeder | — | ✅ |
| Ring connection management | — | ✅ Live status, firmware version, forget button |

## Data Flow

| Feature | iOS | Android |
|---------|:---:|:---:|
| Blood sugar (profile-derived) displayed | — | ✅ mg/dL with app-side calibration offset |
| Fatigue metric displayed | — | ✅ 0–100 scale from 0x24 byte[5] |
| Sleep REM detection (Colmi) | — | ✅ Via V2 big-data protocol |
| Skin temperature (Colmi) | — | ✅ Via V2 big-data protocol |
| Heart rate history (0x16) multi-packet | — | ✅ With sub-type routing and averaging |
| Reactive Room database with Flow | — | ✅ Live data as ring syncs |
| Local-midnight-aligned day bucketing | — | ✅ Consistent daily stats across timezones |
| Calibrated display pipeline | — | ✅ Offsets applied in ViewModels before UI |

## Architecture

| Aspect | iOS | Android |
|--------|-----|---------|
| Persistence | SwiftData | Room (SQLite) with 18 entities, 14 DAOs |
| BLE | CoreBluetooth | android.bluetooth.le |
| UI | SwiftUI | Jetpack Compose + Material 3 |
| HTTP | URLSession | OkHttp |
| Key storage | Keychain | EncryptedSharedPreferences |
| Background work | BGTaskScheduler | WorkManager |
| Live Activity | WidgetKit / Dynamic Island | ForegroundService + notification |
| Charts | Swift Charts | Custom Compose Canvas |
| Maps | MapKit | Canvas polyline |
| Event bus | NotificationCenter | SharedFlow |
| Notifications | UNUserNotificationCenter | NotificationManager + WorkManager |
| DI | @Environment | Manual (ViewModel factories) |

## Summary: What Android has that iOS doesn't

1. **Full 0x24 decoding** — fatigue, stress, blood sugar, HRV
2. **Ring configuration** — user profile (0x02), BP calibration (0x33), app ID (0x48)
3. **Bind/unbind protocol** (0x4B) — proper ring claiming and release
4. **Keepalive + connection watchdog** — prevents silent disconnects
5. **Profile & calibration settings** — age/sex/height/weight, BP cuff reference, glucose offset
6. **Colmi-aware UI** — hides BP/BS panels and profile form for Colmi rings
7. **Vitals detail screens** — period selector, trend charts, stat tiles, threshold bars
8. **Threshold bars on all vitals panels** — color-coded reference ranges
9. **Combined measurement button** — one-tap BP+SpO₂+stress+fatigue+BS with countdown
10. **Pull-to-refresh** — immediate ring sync from Today dashboard
11. **Reactive Room database** — Flow-based live data throughout the app
12. **Calibrated display pipeline** — offsets applied before UI rendering
