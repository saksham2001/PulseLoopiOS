# PulseLoop

<!-- ===================== BADGES ===================== -->
<p align="center">
  <a href="https://github.com/saksham2001/PulseLoopiOS/stargazers"><img src="https://img.shields.io/github/stars/saksham2001/PulseLoopiOS?style=flat&logo=github" alt="Stars"></a>
  <a href="https://github.com/saksham2001/PulseLoopiOS/network/members"><img src="https://img.shields.io/github/forks/saksham2001/PulseLoopiOS?style=flat&logo=github" alt="Forks"></a>
  <a href="https://github.com/saksham2001/PulseLoopiOS/issues"><img src="https://img.shields.io/github/issues/saksham2001/PulseLoopiOS" alt="Issues"></a>
  <a href="https://github.com/saksham2001/PulseLoopiOS/pulls"><img src="https://img.shields.io/github/issues-pr/saksham2001/PulseLoopiOS?label=open%20PRs&logo=github" alt="PRs"></a>
  <!-- TODO: replace ci.yml with your actual workflow filename in .github/workflows/ -->
  <a href="https://github.com/saksham2001/PulseLoopiOS/actions"><img src="https://img.shields.io/github/actions/workflow/status/saksham2001/PulseLoopiOS/ci.yml?label=CI&logo=githubactions&logoColor=white" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white" alt="Swift">
  <a href="https://github.com/saksham2001/PulseLoopiOS/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-CC--BY--4.0-blue" alt="License"></a>
  <a href="https://discord.gg/t9y85ebaKD"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="https://github.com/saksham2001/PulseLoopiOS/raw/main/docs/thumbnail.png">
    <img src="https://github.com/saksham2001/PulseLoopiOS/raw/main/docs/thumbnail.png" alt="PulseLoop">
  </a>
</p>

<!-- ===================== TOP CALLOUTS ===================== -->
<p align="center">
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

---

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

---

## Contents

- [What it does](#what-it-does)
- [Also on Android](#also-on-android)
- [Community](#community)
- [Supported wearables](#supported-wearables)
- [How it works](#how-it-works)
- [Install & try it](#install--try-it)
- [Privacy](#privacy)
- [Contributing](#contributing)
- [Goals / Roadmap](#goals--roadmap)
- [Project layout](#project-layout)
- [Acknowledgements](#acknowledgements)
- [License](#license)

---

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
- **Metric & imperial units** and a fully reworked settings pane.

### Screenshots

| Today | AI Coach | Sleep |
| --- | --- | --- |
| [![Today](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/today%20page%201.PNG)](/screenshots/today%20page%201.PNG) | [![Coach](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/LLM%20coach%20example%201.PNG)](/screenshots/LLM%20coach%20example%201.PNG) | [![Sleep](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/sleep%20page%201.PNG)](/screenshots/sleep%20page%201.PNG) |

| Activity | Vitals | Workout Summary |
| --- | --- | --- |
| [![Activity](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/activity%20page%201.PNG)](/screenshots/activity%20page%201.PNG) | [![Vitals](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/vitals%20page%201.PNG)](/screenshots/vitals%20page%201.PNG) | [![Workout Summary](https://github.com/saksham2001/PulseLoopiOS/raw/main/screenshots/activity%20recording-%20complete%201.PNG)](/screenshots/activity%20recording-%20complete%201.PNG) |

---

## Also on Android

PulseLoop has a sister project for Android: **[PulseLoopAndroid](https://github.com/foureight84/PulseLoopAndroid)**

The two ports are developed hand in hand and share the same BLE protocol work,
so a fix or a newly decoded sensor on one platform usually lands on the other.
The Android build adds some platform-specific niceties (threshold bars,
tap-through metric detail screens, extra connection-reliability handling).
Pick the build for your phone — both connect to the same rings.

> Coordination, the shared roadmap, and cross-platform discussion all happen in
> the [Discord](#community).

---

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

---

## Supported Wearables

> **Disclaimer:** We have no affiliation with the sellers or manufacturers of
> any of the wearables listed below. We do not endorse them and take no
> responsibility for their quality, accuracy, performance, durability, data
> security, or anything else that might go wrong with them. Listings are
> provided for convenience only — links may break, sellers may swap hardware
> under the same name, change prices, and your unit may behave differently from mine. Buy at
> your own risk and treat any data the ring produces as approximate.

PulseLoop is built around a device-agnostic driver layer, so each supported ring
declares exactly what it can do and the app shows only those features. The
tables below break support down by capability.

**Support status legend**

| Status | Meaning |
| --- | --- |
| ✅ | **Supported & tested**: Fully verified working on real hardware |
| 🧪 | **Implemented, needs testing**: code is in place (decoded from the protocol) but not yet tested with that specific model |
| 🚧 | **Planned / not yet implemented** |
| — | **Not applicable**: the hardware doesn't expose this capability |

### Ring families

| Ring | BLE Family | Advertised name | Price | Listing |
| --- | --- | --- | --- | --- |
| jring (generic smart ring) | `56ff` | `SMART_RING` | $7–12 | [AliExpress](https://www.aliexpress.us/item/3256810466598469.html) |
| Colmi / Yawell ring family | `6e40fff0` / `de5bf728` | `R02_…`, `R0x…`, `COLMI R1x…`, `H59_…` | $15–30 | [Colmi store](https://www.colmi.com/) |

### Capability matrix

Major functional areas, by device:

| Capability | jring | Colmi R11 | Other Colmi/Yawell¹ |
| --- | --- | --- | --- |
| **Connection & pairing** (scan, connect, reconnect, forget) | ✅ | ✅ | 🧪 |
| **History sync** (pull stored data on connect) | ✅ | ✅ | 🧪 |
| **Heart rate — spot measurement** | ✅ | ✅ | 🧪 |
| **Heart rate — history** | ✅ | ✅ | 🧪 |
| **Heart rate — live (workout)** | ✅ | ✅ | 🧪 |
| **SpO₂ — spot measurement** | ✅ | — ² | — ² |
| **SpO₂ — history** | ✅ | ✅ | 🧪 |
| **Steps / distance / calories** | ✅ | ✅ ³ | 🧪 |
| **Activity / workout recording** (live HR, zones, GPS route) | ✅ | ✅ | 🧪 |
| **Sleep stages** (light / deep / awake) | ✅ | ✅ | 🧪 |
| **REM sleep** | — | ✅ | 🧪 |
| **HRV** | — | ✅ | 🧪 |
| **Stress** | — | ✅ | 🧪 |
| **Body temperature** | — | ✅ | 🧪 |
| **Battery level** | ✅ | ✅ | 🧪 |
| **Find device** | ✅ | ✅ | 🧪 |

¹ Other Colmi/Yawell models recognized by the same driver: **Colmi R02, R03,
R06, R07, R09, R10, R12** and **Yawell R05, R10, R11, H59**. Same protocol as
the R11, so all capabilities are implemented, but not yet hardware-verified
per model.

² The Colmi family has no on-demand SpO₂ reading; SpO₂ is an all-day background
metric, so only the synced **history/graph** is available (no spot button).

³ Calories from Colmi history are currently hidden pending verification of the
raw value; steps and distance are shown.

---

## How it works

**System architecture:** four layers on the phone. Data flows up from the ring into local storage; the coach reads sideways through tools, and the only thing that leaves the device is a coach question you choose to ask.

[![System architecture](https://github.com/saksham2001/PulseLoopiOS/raw/main/docs/system-architecture.png)](/docs/system-architecture.png)

**The ring link:** one custom BLE service, fixed 20-byte cleartext packets, commands out and notifications back.

[![Ring interaction](https://github.com/saksham2001/PulseLoopiOS/raw/main/docs/ble-interaction.png)](/docs/ble-interaction.png)

**The AI coach:** an agentic loop that calls tools to read your local data, then answers in a structured format.

[![AI coach](https://github.com/saksham2001/PulseLoopiOS/raw/main/docs/AI-coach-design.png)](/docs/AI-coach-design.png)

---

## Install & try it

### 📲 TestFlight beta

A public TestFlight beta is coming soon. Sign up on the
[Discord](#community) to get the invite link. We also have plans to to IPA release soon!

### 🛠️ Build from source (Xcode)

**Requirements**

- Xcode 16+ and an iOS 18+ device (Bluetooth and Live Activities need a real
device — the simulator can't reach the ring).
- A compatible `56ff` or Colmi/Yawell BLE ring.
- An OpenAI or Gemini API key (for the Coach features).

**Run it**

1. Open `PulseLoop.xcodeproj` in Xcode.
2. Select the `PulseLoop` scheme and your physical device as the run target.
3. Set your own **Team** and a unique **Bundle Identifier** under
*Signing & Capabilities* (the Live Activity extension target needs this too).
4. Build & run (`⌘R`).
5. On first launch, complete onboarding, then keep the ring nearby — the app
auto-scans and connects when Bluetooth powers on.
6. To enable the Coach, open **Settings → Coach** and paste your API key. It's
stored in the iOS Keychain and never leaves the device except to call the model.
Pick a provider and model.

**Demo data (no ring required)**

You can explore the UI without hardware: **Settings → "Reseed demo data"**, or
launch with the `-seedDemo YES` argument.

---

## Privacy

PulseLoop is built local-first, which is the whole point:

- **No vendor cloud, no account.** The app talks to the ring directly over BLE.
- **Your data stays on your phone**, persisted locally with SwiftData.
- **AI Coach is off by default and optional.** You can use the app without it, and it is disabled by default in the settings.
- **Nothing leaves the device** except a coach question you explicitly ask —
that single request goes to whichever LLM provider you configured, with the API
key you supply.
- **API keys live in the iOS Keychain.**

> ⚠️ PulseLoop is not a medical device and is not a substitute for professional
> medical advice. Treat all readings as approximate. Always consult a clinician
> for health concerns.

---

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

---

## Goals / Roadmap

> Up-to-date plans and what's shipping next now live in the
> [Releases](https://github.com/saksham2001/PulseLoopiOS/releases) and the
> [Discord](#community). High-level direction:

- [ ] **On-device LLM integration** — run the coach against a local model
(Apple Foundation Models / a quantized on-device LLM) so the app works with
no API key, no network, and full privacy.
- [ ] **Support more cheap rings and other wearables** — generalize the BLE protocol layer to
handle other low-cost ring families beyond the `56ff` devices.
- [ ] **Custom ring firmware** — open firmware to unlock features the stock
ring won't do, e.g. automatic activity/workout detection, higher-rate
sampling, and richer sensor access.
- [ ] **Better onboarding** — smoother first-run pairing, permission, and
setup journey.
- [ ] **LLM tool-call transparency** — surface exactly which tools the coach
called and what data it read, so every answer is auditable.
- [ ] **Multimodal coach input** — let the coach accept image and voice input (e.g. snap a meal, speak a question).
- [ ] **Apple Health integration** — sync data with Apple Health.

---

## Project layout

```
PulseLoop/
├─ RingProtocol/      BLE client + packet decoding for the ring
├─ Models/            SwiftData models (vitals, sleep, activity, coach)
├─ Services/          Sync, workouts, GPS, derived summaries
├─ Coach/             The LLM coach: orchestration, tools, prompts, notifications
│  ├─ Orchestration/  Agentic turn loop, tool execution, fallbacks
│  ├─ Tools/          Retrieval, analysis, charts, memory, web search, actions
│  ├─ OpenAI/         Responses API client
│  ├─ Gemini/         Google Gemini client
│  └─ Notifications/  Daily AI check-ins
├─ Views/             SwiftUI screens (Today, Vitals, Sleep, Activity, Coach)
└─ DesignSystem/      Charts, components, theming

PulseLoopLiveActivity/  Live Activity + Dynamic Island widget
PulseLoopTests/         Unit tests
```

---

## Acknowledgements

- [@foureight84](https://github.com/foureight84) for the
  [Android port](https://github.com/foureight84/PulseLoopAndroid).
- Everyone who's filed an issue, opened a PR, or reported a device — see the
  [contributors graph](https://github.com/saksham2001/PulseLoopiOS/graphs/contributors).

---

## License

This project is licensed under [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://github.com/saksham2001/PulseLoopiOS/blob/main/LICENSE).

You're free to share and adapt the work, including commercially, **as long as
you give appropriate credit**. Please attribute:

> PulseLoop by Saksham Bhutani — <https://github.com/saksham2001/PulseLoopiOS>
