---
title: Getting Started — iOS
description: Install PulseLoop on iOS via TestFlight or build it from source in Xcode.
---

# Getting Started on iOS

PulseLoop for iOS is a native SwiftUI app with SwiftData persistence, Live
Activities, and a Dynamic Island widget. There are two ways to run it: the
upcoming public TestFlight beta, or building from source in Xcode.

!!! info "Pick a ring first"
    PulseLoop talks to a real Bluetooth ring. Before you start, check the
    [supported hardware](../hardware/index.md) to make sure your ring
    is one PulseLoop can drive. No ring yet? You can still explore the whole app
    with [demo data](#demo-data-no-ring-required).

## :material-apple: TestFlight beta

A public TestFlight beta is coming soon. Sign up on the
[Discord](https://discord.gg/t9y85ebaKD) to get the invite link. An IPA release
is also planned.

## :material-hammer-wrench: Build from source (Xcode)

### Requirements

- **Xcode 16+** on macOS.
- An **iOS 18+ physical device** — Bluetooth and Live Activities need real
  hardware, so the simulator can't reach the ring.
- A compatible `56ff` or Colmi/Yawell BLE ring (see
  [supported rings](../hardware/index.md)).
- An **OpenAI or Gemini API key** — only needed for the AI Coach features.

### Run it

1. Open `PulseLoop.xcodeproj` in Xcode.
2. Select the **`PulseLoop`** scheme and your physical device as the run target.
3. Under **Signing & Capabilities**, set your own **Team** and a unique **Bundle
   Identifier**.

    !!! warning "The Live Activity extension needs this too"
        The `PulseLoopLiveActivity` extension target is a *separate* target —
        give it your team and a unique bundle ID as well, or the build will fail
        to sign.

4. Build & run (`⌘R`).
5. On first launch, complete onboarding, then keep the ring nearby — the app
   auto-scans and connects when Bluetooth powers on.
6. To enable the Coach, open **Settings → Coach** and paste your API key, then
   pick a provider and model. The key is stored in the iOS Keychain and never
   leaves the device except to call the model you chose.

### Demo data (no ring required)

You can explore the whole UI and coach without any hardware:

- **Settings → "Reseed demo data"**, or
- Launch with the `-seedDemo YES` argument.

## Running the tests

The unit tests in `PulseLoopTests/` are hermetic — in-memory SwiftData and a
mocked client, so they need no network and no secrets.

- In Xcode: `⌘U`.
- From the CLI:

    ```sh
    xcodebuild test \
      -project PulseLoop.xcodeproj \
      -scheme PulseLoop \
      -destination 'platform=iOS Simulator,name=iPhone 16'
    ```

CI runs this exact suite (plus SwiftLint) on every PR.

## Next steps

- [Supported hardware](../hardware/index.md) — what each ring can do.
- [Architecture](../project/architecture.md) — how the app is put together.
- [Contributing](../project/contributing.md) — add a ring driver or improve the coach.
- Looking for Android? See [Getting Started on Android](android.md).
