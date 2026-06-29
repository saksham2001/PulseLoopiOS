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
    *Last updated: 2026-06-29.* For the canonical state, check each repo:
    [iOS](https://github.com/saksham2001/PulseLoopiOS) ·
    [Android](https://github.com/foureight84/PulseLoopAndroid).

The two ports have converged on the low-level work — protocol decoding, ring
configuration/calibration, and connection reliability are now on both. What
remains is mostly **UI polish** (richer vitals/sleep/activity dashboards, detail
screens) where Android is still ahead. The sections below break that down.

!!! success "Now on both ports"
    These previously Android-only items have landed on iOS and left this page:
    full `0x24` decoding (fatigue, stress, blood sugar, HRV) with corrected
    opcode labels, the ring-config commands (`0x02` profile, `0x33` BP
    calibration, `0x48` app identity, `0x4B` bind/unbind, `0x3A` keepalive),
    connection reliability (write-ACK timeout, watchdog, foreground reconnect,
    stale-state guard, force-close, firmware discovery), profile + BP + blood
    sugar calibration settings, the `0x16` multi-packet history averaging, and
    the calibrated display pipeline. Per-metric on/off toggles for the new jring
    vitals live in **Settings → Vitals & Display**, and BP/blood-sugar
    calibration in **Settings → Calibration** (both capability-gated, so Colmi
    never sees them).

## UI Differences

### Vitals Dashboard

| Feature | iOS | Android |
|---------|:---:|:---:|
| BP / blood sugar / fatigue panels | ✅ Value cards (capability-gated to jring) | ✅ |
| Threshold bars on every metric panel | — | ✅ Color-coded (Good → Normal → Borderline → High) |
| Tap-through detail screens per metric | — | ✅ Full trend view with period selector |
| Zone-colored trend charts | — | ✅ Data points colored by threshold zone |
| Range/avg summaries on panels | — | ✅ `Range: min – max · Avg: avg` |
| Combined measurement button | — | ✅ One-tap BP+SpO₂+stress+fatigue+BS with countdown |

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

### Ring Management

| Feature | iOS | Android |
|---------|:---:|:---:|
| BP/blood sugar/fatigue panels gated to jring | ✅ Capability-gated; Colmi never declares them | ✅ |
| Calibration screen gated to jring | ✅ Shown only when ring supports BP/blood sugar | ✅ |
| Proper unbind on forget | ✅ `0x4B` UNBOND before teardown (jring) | ✅ UNBOND → UNBOND_ACK |
| Firmware version captured | ✅ Parsed from `0x0C`/`0xF6` + DIS, stored on device | ✅ Also displayed in Settings |
| Connection state display | — | ✅ Live status with battery % in Settings |

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

Profile, BP calibration, blood sugar calibration, unit toggle, and demo seeding
are now on both ports. iOS keeps per-metric visibility toggles in **Vitals &
Display** and calibration in a dedicated **Calibration** screen.

| Feature | iOS | Android |
|---------|:---:|:---:|
| Per-metric vitals on/off toggles | ✅ Vitals & Display (incl. new jring metrics) | ✅ |
| Ring connection management | ✅ Status + forget in Wearable settings | ✅ Live status, firmware version, forget |

## Data Flow

The new metric capture + calibration pipeline is on both ports. What's left is
Colmi-specific decoding and the reactive-store/timezone-bucketing internals.

| Feature | iOS | Android |
|---------|:---:|:---:|
| Sleep REM detection (Colmi) | — | ✅ Via V2 big-data protocol |
| Skin temperature (Colmi) | — | ✅ Via V2 big-data protocol |
| Reactive store with live updates | ✅ SwiftData + event-bus signature refresh | ✅ Room + Flow |
| Local-midnight-aligned day bucketing | Partial — `Calendar.startOfDay` per day | ✅ Timezone-offset SQL bucketing |

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

## Summary: What Android still has that iOS doesn't

The low-level protocol, ring configuration, connection reliability, and
calibration pipeline are now on both ports. The remaining gaps are UI polish and
a couple of Colmi-specific decodes:

1. **Vitals detail screens** — tap-through per metric with period selector, trend arrows, stat tiles
2. **Threshold bars on all vitals panels** — color-coded reference ranges (Good → High)
3. **Zone-colored trend charts** — data points colored by threshold zone
4. **Combined measurement button** — one-tap BP+SpO₂+stress+fatigue+BS with countdown
5. **Richer Sleep view** — stage breakdown pills, coach insights, duration/architecture charts
6. **Richer Activity view** — threshold reference ranges, active-minutes trend card
7. **Sleep REM + skin temperature (Colmi)** — via the V2 big-data protocol
8. **Timezone-offset day bucketing** — Android buckets daily stats by a local-midnight SQL offset
