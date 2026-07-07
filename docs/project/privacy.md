---
title: Privacy
description: PulseLoop is local-first by design — what leaves your device and what never does.
---

# Privacy

PulseLoop is built **local-first**, which is the whole point.

- **No vendor cloud, no account.** The app talks to the ring directly over
  Bluetooth LE.
- **Your data stays on your phone**, persisted locally (SwiftData on iOS, Room on
  Android).
- **AI Coach is off by default and optional.** You can use the app without it; it
  is disabled by default in Settings.
- **Nothing leaves the device** except a coach question you explicitly ask — that
  single request goes to whichever LLM provider you configured, with the API key
  you supply.
- **API keys are stored securely on-device** — the iOS Keychain, or Android's
  `EncryptedSharedPreferences`.

!!! warning "Not a medical device"
    PulseLoop is not a medical device and is not a substitute for professional
    medical advice. Treat all readings as approximate. Always consult a clinician
    for health concerns.

## For contributors

The promise that your health data stays on your device is a hard constraint. Any
change that affects what data leaves the phone, or how it's stored, must be called
out clearly in the PR description and will get extra scrutiny. Never commit
secrets, API keys, or real personal health data. See [Contributing](contributing.md).
