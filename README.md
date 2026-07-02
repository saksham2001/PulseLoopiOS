# PulseLoop

<!-- ===================== BADGES ===================== -->
<p align="center">
  <a href="https://github.com/saksham2001/PulseLoopiOS/stargazers"><img src="https://img.shields.io/github/stars/saksham2001/PulseLoopiOS?style=flat&logo=github" alt="Stars"></a>
  <a href="https://github.com/saksham2001/PulseLoopiOS/network/members"><img src="https://img.shields.io/github/forks/saksham2001/PulseLoopiOS?style=flat&logo=github" alt="Forks"></a>
  <a href="https://github.com/saksham2001/PulseLoopiOS/issues"><img src="https://img.shields.io/github/issues/saksham2001/PulseLoopiOS" alt="Issues"></a>
  <a href="https://github.com/saksham2001/PulseLoopiOS/pulls"><img src="https://img.shields.io/github/issues-pr/saksham2001/PulseLoopiOS?label=PRs&logo=github" alt="PRs"></a>
  <!-- TODO: replace ci.yml with your actual workflow filename in .github/workflows/ -->
  <a href="https://github.com/saksham2001/PulseLoopiOS/actions"><img src="https://img.shields.io/github/actions/workflow/status/saksham2001/PulseLoopiOS/ci.yml?label=CI&logo=githubactions&logoColor=white" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white" alt="Swift">
  <a href="https://github.com/saksham2001/PulseLoopiOS/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-CC--BY--4.0-blue" alt="License"></a>
  <a href="https://saksham2001.github.io/PulseLoopiOS/"><img src="https://img.shields.io/badge/docs-online-7C5CFF?logo=materialformkdocs&logoColor=white" alt="Docs"></a>
  <a href="https://discord.gg/t9y85ebaKD"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="docs/images/thumbnail.png">
    <img src="docs/images/thumbnail.png" alt="PulseLoop">
  </a>
</p>

<!-- ===================== TOP CALLOUTS ===================== -->
<p align="center">
  <a href="https://saksham2001.github.io/PulseLoopiOS/"><b>📚 Documentation</b></a> ·
  <a href="https://github.com/foureight84/PulseLoopAndroid"><b>📱 Now on Android</b></a> ·
  <a href="https://discord.gg/t9y85ebaKD"><b>💬 Join the Discord</b></a> ·
  <a href="https://sakshambhutani.xyz/projects/20_project/"><b>📖 Read the writeup</b></a>
</p>

<!-- ===================== FEATURED / SHARED ON ===================== -->
<p align="center"><i>Featured on communities:</i></p>
<p align="center">
  <a href="https://www.reddit.com/r/ReverseEngineering/comments/1u34idd/reverse_engineered_ble_protocol_of_a_7_generic/"><img src="https://img.shields.io/badge/Reddit-r%2FReverseEngineering-FF4500?logo=reddit&logoColor=white" alt="r/ReverseEngineering"></a>
  <a href="https://www.reddit.com/r/hardwarehacking/comments/1u3wdeb/reverse_engineered_s_7_chinese_smart_ring_from/"><img src="https://img.shields.io/badge/Reddit-r%2Fhardwarehacking-FF4500?logo=reddit&logoColor=white" alt="r/hardwarehacking"></a>
  <a href="https://www.reddit.com/r/selfhosted/comments/1u3wg8z/reverse_engineered_ble_protocol_of_a_7_generic/"><img src="https://img.shields.io/badge/Reddit-r%2Fselfhosted-FF4500?logo=reddit&logoColor=white" alt="r/selfhosted"></a>
  <a href="https://www.reddit.com/r/degoogle/comments/1u43mxe/you_dont_need_fitbit_now_i_reverse_engineering_a/"><img src="https://img.shields.io/badge/Reddit-r%2Fdegoogle-FF4500?logo=reddit&logoColor=white" alt="r/degoogle"></a>
  <a href="https://x.com/vu3dtu/status/2064797099385061792"><img src="https://img.shields.io/badge/-000000?logo=x&logoColor=white" alt="X post"></a>
</p>

An LLM-native health app for iOS that turns a cheap Bluetooth "smart ring"
into a real, conversational health tracker. It currently supports the generic Chinese
Jring and the Colmi / Yawell ring family (R02/R0x/R1x/H59), behind a device-agnostic driver layer so
adding more wearables is straightforward.

PulseLoop talks to the ring directly over Bluetooth LE (no vendor cloud, no
account) and layers an **optional** AI Coach on top of your own data. Instead of
static charts, you get a coach that can read your metrics, run its own
analysis, draw charts, remember context about you, and answer questions about
your sleep, heart rate, activity, and recovery.

> **Goal:** prove that a $20 ring + an LLM can replace a $300 subscription
> wearable, and that the "intelligence" should live on the phone, not behind a
> paywall.

## Documentation

📚 **Full docs: [saksham2001.github.io/PulseLoopiOS](https://saksham2001.github.io/PulseLoopiOS/)**

- [Getting started — iOS](https://saksham2001.github.io/PulseLoopiOS/getting-started/ios/)
- [Getting started — Android](https://saksham2001.github.io/PulseLoopiOS/getting-started/android/)
- [Supported hardware](https://saksham2001.github.io/PulseLoopiOS/hardware/)
- [iOS vs Android](https://saksham2001.github.io/PulseLoopiOS/platforms/ios-vs-android/)
- [Architecture](https://saksham2001.github.io/PulseLoopiOS/project/architecture/) · [Roadmap](https://saksham2001.github.io/PulseLoopiOS/project/roadmap/) · [Contributing](https://saksham2001.github.io/PulseLoopiOS/project/contributing/)

## What it does

- **Connects to the ring over BLE** and decodes its proprietary protocol
(heart rate, SpO₂, steps, distance, calories, sleep stages, raw packets).
- **Today / Vitals / Sleep / Activity** dashboards built natively in SwiftUI,
backed by SwiftData for local persistence.
- **AI Coach** — an agentic loop (OpenAI or Google Gemini) with tools for data
retrieval, on-the-fly analysis, chart generation, long-term memory, and web
search. Every answer is grounded in your actual ring data.
- **Workout recording** with live heart-rate zones, GPS route maps, a Live
Activity, and a Dynamic Island widget.
- **Daily check-in notifications** generated by the coach from your recent
trends.

> 📚 **Diagrams and a full walkthrough:
> [Architecture docs](https://saksham2001.github.io/PulseLoopiOS/project/architecture/).**

### Screenshots

| Today | AI Coach | Sleep |
| --- | --- | --- |
| [![Today](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/today%20page.png)](/screenshots/today%20page.png) | [![Coach](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/today%20coach%20summary.png)](/screenshots/today%20coach%20summary.png) | [![Sleep](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/sleep%20page.png)](/screenshots/sleep%20page.png) |

| Activity | Vitals | Workout Summary |
| --- | --- | --- |
| [![Activity](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/activity%20page.png)](/screenshots/activity%20page.png) | [![Vitals](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/vitals%20page.png)](/screenshots/vitals%20page.png) | [![Workout Summary](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/workout%20summary.png)](/screenshots/workout%20summary.png) |

## Also on Android

PulseLoop has a sister project for Android: **[PulseLoopAndroid](https://github.com/foureight84/PulseLoopAndroid)**

The two ports are developed hand in hand and share the same BLE protocol work,
so a fix or a newly decoded sensor on one platform usually lands on the other.
The Android build adds some platform-specific niceties (threshold bars,
tap-through metric detail screens, extra connection-reliability handling).
Pick the build for your phone — both connect to the same rings.

> Coordination, the shared roadmap, and cross-platform discussion all happen in
> the [Discord](#community).

## Community

We run a Discord for roadmap planning, getting-started help, and coordinating
the iOS + Android efforts. It's the fastest place to get unstuck, claim an
issue, or propose a feature.

**👉 [Join the PulseLoop Discord](https://discord.gg/t9y85ebaKD)**

New here? Good places to start:
- Skim the [open issues](https://github.com/saksham2001/PulseLoopiOS/issues),
  especially any tagged **good first issue**.
- Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the
  [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
- Say hi in Discord and tell us what ring you have — device reports are
  genuinely useful.

## Supported Wearables

> **Disclaimer:** We have no affiliation with the sellers or manufacturers of
> any of the wearables listed below. We do not endorse them and take no
> responsibility for their quality, accuracy, performance, durability, data
> security, or anything else that might go wrong with them. Listings are
> provided for convenience only — links may break, sellers may swap hardware
> under the same name, change prices, and your unit may behave differently from mine. Buy at
> your own risk and treat any data the ring produces as approximate.

PulseLoop is built around a device-agnostic driver layer, so each supported ring
declares exactly what it can do and the app shows only those features.

| Ring | BLE Family | Advertised name | Price |
| --- | --- | --- | --- |
| jring (generic smart ring) | `56ff` | `SMART_RING` | $7–12 |
| Colmi / Yawell ring family | `6e40fff0` / `de5bf728` | `R02_…`, `R0x…`, `COLMI R1x…`, `H59_…` | $15–30 |

> 📚 **Full hardware specs, per-model capability matrix, and buying guidance:
> [Supported hardware docs](https://saksham2001.github.io/PulseLoopiOS/hardware/).**

## Install & try it

### 📲 TestFlight beta

A public TestFlight beta is coming soon. Sign up on the
[Discord](#community) to get the invite link. We also have plans to to IPA release soon!

### 🛠️ Build from source (Xcode)

You'll need Xcode 16+, an iOS 18+ device, a compatible `56ff` or Colmi/Yawell
ring, and (optionally) an OpenAI or Gemini API key for the Coach. Open
`PulseLoop.xcodeproj`, set your **Team** + a unique **Bundle Identifier**, then
build & run on your device.

> 📚 **Full step-by-step build, signing, and demo-data instructions:
> [Getting started — iOS](https://saksham2001.github.io/PulseLoopiOS/getting-started/ios/).**
> Building on Android? See the
> [Android guide](https://saksham2001.github.io/PulseLoopiOS/getting-started/android/).

## Contributing

PRs and issues are very welcome — this project moves fast because people pitch
in. Before you start:

1. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
2. Open or comment on an [issue](https://github.com/saksham2001/PulseLoopiOS/issues)
so we don't duplicate work.
3. CI runs automatically on every PR (build + SwiftLint): keep it green!
4. Coordinate bigger changes in the [Discord](#community), especially anything
that should land on Android too.

Adding a new ring? The device-agnostic driver layer in `RingProtocol/` is the
place to start — ping us in Discord and we'll point you at the right files.

> 📚 The [roadmap](https://saksham2001.github.io/PulseLoopiOS/project/roadmap/) and
> [architecture / project layout](https://saksham2001.github.io/PulseLoopiOS/project/architecture/)
> now live in the docs.

## Acknowledgements

- [@foureight84](https://github.com/foureight84) for the
  [Android port](https://github.com/foureight84/PulseLoopAndroid).
- Everyone who's filed an issue, opened a PR, or reported a device — see the
  [contributors graph](https://github.com/saksham2001/PulseLoopiOS/graphs/contributors).

## License

This project is licensed under [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://github.com/saksham2001/PulseLoopiOS/blob/main/LICENSE).

You're free to share and adapt the work, including commercially, **as long as
you give appropriate credit**. Please attribute:

> PulseLoop by Saksham Bhutani — <https://github.com/saksham2001/PulseLoopiOS>
