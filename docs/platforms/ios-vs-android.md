---
title: iOS vs Android
description: >-
  A living comparison of where the PulseLoop iOS and Android ports differ in
  design, features, and capability.
---

# iOS vs Android

The iOS and Android ports of PulseLoop are built hand in hand and share the same
reverse-engineered BLE protocol work. They are not identical, though. Each
platform lands some features first. This page is a **living comparison** of the
real differences in design and capability, not language or framework details.

!!! note "This is a snapshot"
    Things change fast. When a feature lands on both ports, it leaves this page.
    *Last updated: 2026-07-01.* For the canonical state, check each repo:
    [iOS](https://github.com/saksham2001/PulseLoopiOS) ·
    [Android](https://github.com/foureight84/PulseLoopAndroid).

## AI Coach (iOS only)

This is the biggest difference between the two ports today. iOS has an AI Coach
that reads your metrics and answers questions about them. Android has no coach.

On iOS you can choose how the coach runs:

- **Bring your own key** for OpenAI, Google Gemini, or OpenRouter. OpenRouter
  opens up hundreds of models behind one key, with extra options like privacy
  routing and provider selection.
- **Apple on-device Foundation Models.** Runs the model locally on supported
  devices with no API key and no data leaving the phone. Availability is gated
  to hardware that supports it.
- **Offline** scripted fallback when no provider is configured.

Beyond provider choice, the iOS coach is:

- **Multimodal.** You can send images into the chat, for example a photo of a
  meal or a supplement label, and ask about them.
- **Agentic.** It runs a tool loop that can pull your own metrics and search the
  web, rather than answering from a single static prompt.
- **Proactive.** It generates daily check-in notifications from your recent
  data.

## Vitals, Activity, and Sleep dashboards

Both ports now have rich dashboards after the recent iOS UI overhaul. The gap
here is small and goes in both directions.

iOS recently rebuilt its dashboards and today page. It now has dedicated widgets
for activity goals, heart rate, sleep, blood pressure, and blood sugar, plus
zone-colored charts and threshold reference bars on the vitals panels. Blood
pressure, blood sugar, and fatigue panels are capability-gated so they only show
on rings that support them.

Android still leads on a few detail-level touches: deeper tap-through detail
screens per metric with period selectors and stat tiles, and a one-tap combined
measurement button. These are polish gaps rather than capability gaps.

Both ports record workouts with GPS and heart rate zones. iOS records a broad
set of activity types (walk, run, cycle, gym, squash, sport, yoga, hike, dance,
and other), and the AI Coach can log or edit those sessions for you by voice or
text, which Android has no equivalent for.

## Ring support and protocol

The low-level work has converged. Both ports decode the full jring / 56ff metric
set (blood pressure, blood sugar, stress, fatigue, HRV), do blood pressure and
blood sugar calibration, support the Colmi QRing, and share the same connection
reliability work (write-ACK timeouts, watchdogs, reconnect, proper unbind on
forget).

## Platform-native capabilities

A few differences come straight from the platform each port runs on:

- **On-device AI** is iOS-only, since it uses Apple's Foundation Models.
- **Live status while measuring** uses the Dynamic Island and a Live Activity on
  iOS, and a foreground-service notification on Android.
