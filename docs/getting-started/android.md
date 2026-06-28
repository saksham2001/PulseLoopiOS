---
title: Getting Started — Android
description: Install and build PulseLoop for Android, and what the Android port adds.
---

# Getting Started on Android

PulseLoop has a sister project for Android:
**[foureight84/PulseLoopAndroid](https://github.com/foureight84/PulseLoopAndroid)**.

The two ports are developed hand in hand and share the same BLE protocol work, so
a fix or a newly decoded sensor on one platform usually lands on the other. The
Android build is written in **Jetpack Compose + Material 3** with **Room** for
persistence, and adds several platform-specific niceties on top of the shared
feature set.

!!! info "Pick a ring first"
    PulseLoop talks to a real Bluetooth ring. Check the
    [supported hardware](../hardware/index.md) before you start — both
    ports connect to the same rings.

## :material-android: Install

The Android app is distributed from the
[PulseLoopAndroid repository](https://github.com/foureight84/PulseLoopAndroid).
Check that repo's releases and README for the latest APK and install
instructions.

## :material-hammer-wrench: Build from source

!!! note "Build steps live in the Android repo"
    Android build instructions are maintained in the
    [PulseLoopAndroid README](https://github.com/foureight84/PulseLoopAndroid).
    The outline below is the typical Android Studio flow; **follow the Android
    repo's README for the authoritative, up-to-date steps.**

<!-- TODO: confirm exact steps (min SDK, JDK version, signing) against the
     PulseLoopAndroid README and fill in precise versions here. -->

1. Clone [foureight84/PulseLoopAndroid](https://github.com/foureight84/PulseLoopAndroid).
2. Open the project in **Android Studio**.
3. Let Gradle sync, then connect a physical Android device — Bluetooth LE needs
   real hardware.
4. Build & run the app module to your device.
5. On first launch, grant Bluetooth/Location permissions and keep the ring nearby.
6. To enable the Coach, open **Settings** and add your OpenAI or Gemini API key.
   It's stored in `EncryptedSharedPreferences` and only used to call the model
   you choose.

## What the Android port adds

Beyond the shared dashboards and AI Coach, the Android build includes extra
features that aren't (yet) in the iOS app:

- **Full `0x24` sensor decoding** — fatigue, stress, blood sugar, and HRV from
  the combined-measurement packet.
- **Ring configuration & calibration** — user profile (age/sex/height/weight),
  BP cuff-reference calibration, and a blood-sugar lab offset, all in Settings.
- **Bind/unbind protocol** — proper ring claiming on connect and release on
  forget, so the ring re-advertises for other apps.
- **Connection reliability** — keepalive pings, a write-ACK timeout, and a
  connection watchdog that prevents silent disconnects.
- **Vitals detail screens** — tap any metric for a trend chart, period selector,
  stat tiles, and a color-coded threshold bar.
- **Threshold bars everywhere** — color-coded reference ranges (Good → Normal →
  Borderline → High) on every vitals panel.
- **Combined measurement button** — one tap for BP + SpO₂ + stress + fatigue +
  blood sugar with a countdown.
- **Pull-to-refresh** — triggers an immediate ring sync from the Today dashboard.

For the complete, current breakdown, see the
[iOS vs Android comparison](../platforms/ios-vs-android.md).

## Architecture at a glance

| Aspect | Android |
| --- | --- |
| UI | Jetpack Compose + Material 3 |
| Persistence | Room (SQLite) |
| BLE | `android.bluetooth.le` |
| HTTP | OkHttp |
| Key storage | `EncryptedSharedPreferences` |
| Background work | WorkManager |
| Charts | Custom Compose Canvas |

See the [Architecture](../project/architecture.md) page for how both ports map
onto the same data flow.

## Next steps

- [Supported hardware](../hardware/index.md) — what each ring can do.
- [iOS vs Android](../platforms/ios-vs-android.md) — where the ports differ today.
- [Contributing](../project/contributing.md) — coordinate cross-platform work in
  the [Discord](https://discord.gg/t9y85ebaKD).
- Looking for iOS? See [Getting Started on iOS](ios.md).
