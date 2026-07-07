---
title: Roadmap
description: Long-term direction and guiding principles for PulseLoop, across both the iOS and Android ports.
---

# Roadmap

!!! tip "Where live planning happens"
    Up-to-date plans and what's shipping next live in the
    [Releases](https://github.com/saksham2001/PulseLoopiOS/releases) and the
    [Discord](https://discord.gg/t9y85ebaKD). This page captures the long-term
    direction shared across the project.

## Principles

These guide what we build and what we say no to.

- **Privacy-first**: your health data stays on your device by default.
- **Subscription-free**: every feature, for everyone, no paywalls.
- **Open & transparent**: documented metrics and an auditable coach, no black boxes.
- **Hardware freedom**: cheap devices, your data, and eventually your own firmware.
- **Cross-platform**: one direction shared across iOS and Android.

## Direction

### More wearables, more freedom

- **Open BLE standards**: heart rate (+ HRV), blood pressure, temperature, weight,
  and glucose. Supporting the standards adds chest straps, BP cuffs, and scales with
  little per-device work.
- **Reverse-engineered protocols**: more rings (Ultrahuman, RingConn, …) and
  bands/watches (Amazfit/Zepp, Xiaomi) beyond today's `56ff` and Colmi families.
- **Device-driver SDK**: let contributors add a wearable without touching the core.

### Own the hardware

- Reverse-engineer ring firmware and the over-the-air update path.
- Load custom firmware safely: higher sampling rates, longer battery, and access
  the stock app blocks.
- Unlock **raw PPG and accelerometer** signals: the basis for everything intelligent.

### On-device intelligence

- **Local LLM coach**: run against an on-device model: no API key, no network, full privacy.
- **Automatic workout detection**: recognize runs, rides, and walks with no manual start.
- **Proactive insights**: weekly trends and call-outs the coach surfaces for you.
- **Auditable coach**: show which tools the coach called and what data it read.
- **Personal baselines**: learn what's normal for you and flag meaningful changes.

### Metrics you can trust

- **Performance & recovery**: readiness, training/cardio load, HRV and resting-HR
  trends, VO₂max.
- **Health signals**: illness early-warning from shifts in skin temperature, resting
  heart rate, and respiration.
- **Cycle tracking**: menstrual cycle and BBT from skin temperature, computed on-device.
- **Energy balance**: calorie-burn estimation paired with food logging via an open
  food database.

### Your data, your way

- **Optional sync**: Apple Health, Google Health Connect, Strava, Garmin; useful for
  export and for cross-checking your readings.
- **Self-hosted export**: Home Assistant, InfluxDB/Grafana, MQTT, and open formats
  (FIT, GPX, CSV, JSON).
- **Ownership by default**: your data is portable and never required to leave the device.

### Everywhere you are

- **Multiple wearables at once**: aggregate several devices into one picture.
- **watchOS companion**: glanceable data, or use a watch as another sensor.
- **Web app**: a third client alongside iOS and Android.

## Cross-platform parity

Because the iOS and Android ports share the same protocol work, a big part of the
roadmap is simply bringing the two ports to feature parity. The low-level
protocol, calibration, and connection reliability are now on both. iOS leads on
the AI Coach (multiple providers, on-device model, multimodal input), while
Android still leads on a few vitals detail screens and a couple of
Colmi-specific decodes.

See [iOS vs Android](../platforms/ios-vs-android.md) for the current gap list.
Much of it is fair game for contributors who want a well-scoped first task.

## Want to help?

- Skim the [open issues](https://github.com/saksham2001/PulseLoopiOS/issues),
  especially anything tagged **good first issue**.
- Propose or claim work in the [Discord](https://discord.gg/t9y85ebaKD). Coordinate anything that should land on both platforms.
- See [Contributing](contributing.md) to get set up.