---
title: Contributing
description: How to get set up, the standards PRs are held to, and how to add a new ring.
---

# Contributing

Thank you! PulseLoop is an open, privacy-first health app that turns a cheap
Bluetooth ring into a real, local-first health tracker. Contributions of all
kinds are welcome — bug reports, new ring drivers, coach improvements, UI polish,
and docs.

!!! tip "Start in the Discord"
    The fastest way to get unstuck, claim an issue, or coordinate cross-platform
    work is the [PulseLoop Discord](https://discord.gg/t9y85ebaKD). For anything
    large, open an issue to discuss the approach **before** writing a lot of code.

This page summarizes the workflow. The authoritative version lives in each repo:

- iOS: [`CONTRIBUTING.md`](https://github.com/saksham2001/PulseLoopiOS/blob/main/CONTRIBUTING.md)
  and [`CODE_OF_CONDUCT.md`](https://github.com/saksham2001/PulseLoopiOS/blob/main/CODE_OF_CONDUCT.md)
- Android: [PulseLoopAndroid](https://github.com/foureight84/PulseLoopAndroid)

## Code of conduct

This project follows a
[Code of Conduct](https://github.com/saksham2001/PulseLoopiOS/blob/main/CODE_OF_CONDUCT.md).
By participating, you're expected to uphold it. Please be kind.

## Ways to contribute

- **Report a bug** — open a [bug report](https://github.com/saksham2001/PulseLoopiOS/issues/new?template=bug_report.yml).
- **Request a feature** — open a [feature request](https://github.com/saksham2001/PulseLoopiOS/issues/new?template=feature_request.yml).
- **Add a wearable** — open a [new wearable support](https://github.com/saksham2001/PulseLoopiOS/issues/new?template=new_wearable_support.yml)
  issue, ideally with BLE service/characteristic UUIDs and packet captures.
- **Send a pull request** — see below.

## Development setup (iOS)

**Requirements**

- macOS with **Xcode 16+**.
- An **iOS 18+ physical device** for anything touching Bluetooth or Live
  Activities — the simulator cannot reach the ring.
- A compatible BLE ring (see [supported rings](../hardware/index.md)),
  or use demo data if you don't have hardware.
- An OpenAI/Gemini API key only if you're working on the Coach.

See [Getting Started on iOS](../getting-started/ios.md) for full build steps, and
[Getting Started on Android](../getting-started/android.md) for the Android flow.

## Running the tests (iOS)

The unit tests in `PulseLoopTests/` are **hermetic** — in-memory SwiftData and a
mocked client (`sk-test`), so they need no network and no secrets.

- In Xcode: `⌘U`.
- From the CLI:

    ```sh
    xcodebuild test \
      -project PulseLoop.xcodeproj \
      -scheme PulseLoop \
      -destination 'platform=iOS Simulator,name=iPhone 16'
    ```

CI runs this exact suite on every PR. **Please add or update tests** for any
behavior you change — especially decoders, capability gating, sleep/activity
math, and coach tools.

## Code style (iOS)

- We use **SwiftLint** (config in `.swiftlint.yml`); CI runs it on every PR.
  Install locally with `brew install swiftlint` and run `swiftlint` from the repo
  root.
- Match the surrounding code: SwiftUI views in `Views/`, models in `Models/`, etc.
  Keep changes small and focused.
- Prefer clarity over cleverness. Comments should explain *why*, not *what*.

## Adding support for a new wearable

PulseLoop has a **device-agnostic driver layer** (`RingProtocol/` on iOS). Each
device declares the capabilities it supports, and the UI shows only those
features. To add a ring:

1. **Identify it** — advertised BLE name, primary service UUID, and the
   write/notify characteristic UUIDs (use a scanner like LightBlue or nRF Connect).
2. **Decode the protocol** — capture the 20-byte command/notification packets from
   the vendor app and map them to metrics. Existing decoders (`RingDecoderTests`,
   `ColmiDecoderTests`) are good references and good places to add coverage.
3. **Declare capabilities** — give the driver the right capability set so the app
   gates features correctly.
4. **Add tests** — decoder round-trips and capability gating, following the
   existing test files.
5. **Update the capability matrix** — add the new model and its support status
   (here and in the [Supported Rings](../hardware/index.md) page).

You don't need the hardware to *start* — a good packet capture in an issue lets
others help. Mark anything you couldn't verify on real hardware as 🧪
("implemented, needs testing").

## Pull request process

1. **Fork** the repo and create a branch from `main`:
   `git checkout -b feature/short-description`.
2. Make your change, **add tests**, and make sure lint and the test suite pass
   locally.
3. **Open a PR** against `main` and fill out the PR template. Link any related
   issue (`Closes #123`).
4. **CI must be green** — build, tests, and SwiftLint all pass.
5. **Review** — the maintainer reviews and may request changes. One approving
   review is required to merge.
6. Once approved and green, your PR gets merged. 🎉

Keep PRs focused — one logical change per PR is much easier to review.

!!! warning "Privacy expectations"
    PulseLoop's promise is that **your health data stays on your device**. Any PR
    that changes what data leaves the device, or how it's stored, must call that
    out clearly in the PR description and will get extra scrutiny. Never commit
    secrets, API keys, or real personal health data. See [Privacy](privacy.md).

## License

By contributing, you agree that your contributions will be licensed under the
project's [CC BY 4.0](https://github.com/saksham2001/PulseLoopiOS/blob/main/LICENSE)
license.
