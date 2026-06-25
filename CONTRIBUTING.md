# Contributing to PulseLoop

First off — thank you! PulseLoop is an open, privacy-first health app that turns
a cheap Bluetooth ring into a real, local-first health tracker. Contributions of
all kinds are welcome: bug reports, new ring drivers, coach improvements, UI
polish, and docs.

This guide explains how to get set up, the standards we hold PRs to, and how the
review/merge process works.

---

## Code of conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). By participating,
you're expected to uphold it. Please be kind.

---

## Ways to contribute

- **Report a bug** — open a [bug report](https://github.com/saksham2001/PulseLoopIOS/issues/new?template=bug_report.yml).
- **Request a feature** — open a [feature request](https://github.com/saksham2001/PulseLoopIOS/issues/new?template=feature_request.yml).
- **Add a wearable** — open a [new wearable support](https://github.com/saksham2001/PulseLoopIOS/issues/new?template=new_wearable_support.yml)
  issue, ideally with BLE service/characteristic UUIDs and packet captures.
- **Send a pull request** — see below.

For anything large, please open an issue to discuss it **before** writing a lot
of code, so we can agree on the approach.

---

## Development setup

**Requirements**

- macOS with **Xcode 16+**.
- An **iOS 18+ physical device** for anything touching Bluetooth or Live
  Activities — the simulator cannot reach the ring.
- A compatible BLE ring (see the [supported wearables](README.md#supported-wearables)),
  or use demo data (below) if you don't have hardware.
- An OpenAI API key only if you're working on the Coach.

**Build & run**

1. Open `PulseLoop.xcodeproj` in Xcode.
2. Set your own **Team** and a unique **Bundle Identifier** under
   *Signing & Capabilities* (the Live Activity extension target needs this too).
3. Select the `PulseLoop` scheme + your device, then Build & Run (`⌘R`).

**No hardware? Use demo data**

You can do most UI/coach work without a ring:

- **Settings → "Reseed demo data"**, or
- Launch with the `-seedDemo YES` argument.

---

## Running the tests

The unit tests live in `PulseLoopTests/` and are **hermetic**: they use
in-memory SwiftData and a mocked OpenAI client (`sk-test`), so they need no
network and no secrets.

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
math, and coach tools, which are all covered today and easy to extend.

---

## Code style

- We use **SwiftLint** (config in [.swiftlint.yml](.swiftlint.yml)); CI runs it
  on every PR. Install locally with `brew install swiftlint` and run `swiftlint`
  from the repo root.
- Match the surrounding code: SwiftUI views in `Views/`, models in `Models/`,
  etc. Keep changes small and focused.
- Prefer clarity over cleverness. Comments should explain *why*, not *what*.

---

## Adding support for a new wearable

PulseLoop has a **device-agnostic driver layer** in `RingProtocol/`. Each device
declares the capabilities it supports, and the UI shows only those features
(see `CapabilityGatingTests` for how this is enforced). To add a ring:

1. **Identify it** — advertised BLE name, primary service UUID, and the
   write/notify characteristic UUIDs (use a scanner like LightBlue or nRF
   Connect).
2. **Decode the protocol** — capture the 20-byte command/notification packets
   from the vendor app and map them to metrics. Existing decoders
   (`RingDecoderTests`, `ColmiDecoderTests`) are good references and good places
   to add coverage.
3. **Declare capabilities** — give the driver the right `WearableCapability` set
   so the app gates features correctly.
4. **Add tests** — decoder round-trips and capability gating, following the
   existing test files.
5. **Update the README capability matrix** with the new model and its support status.

You don't necessarily need the hardware to *start* — a good packet capture in an
issue lets others help. Mark anything you couldn't verify on real hardware as
🧪 ("implemented, needs testing").

---

## Pull request process

1. **Fork** the repo and create a branch from `main`:
   `git checkout -b feature/short-description`.
2. Make your change, **add tests**, and make sure `swiftlint` and the test suite
   pass locally.
3. **Open a PR** against `main` and fill out the PR template. Link any related
   issue (`Closes #123`).
4. **CI must be green** — build, tests, and SwiftLint all pass.
5. **Review** — the maintainer ([@saksham2001](https://github.com/saksham2001))
   reviews and may request changes. One approving review is required to merge.
6. Once approved and green, your PR gets merged. 🎉

Keep PRs focused — one logical change per PR is much easier to review than a
large mixed one.

---

## Privacy expectations

PulseLoop's promise is that **your health data stays on your device**. The only
thing that should ever leave the phone is a coach question the user explicitly
chooses to send. Any PR that changes what data leaves the device, or how it's
stored, must call that out clearly in the PR description and will get extra
scrutiny. Never commit secrets, API keys, or real personal health data.

---

## License

By contributing, you agree that your contributions will be licensed under the
project's [CC BY 4.0](LICENSE) license.
