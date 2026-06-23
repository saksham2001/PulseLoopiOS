<!--
Thanks for contributing to PulseLoop! 🫀
Please fill this out so your PR can be reviewed quickly. Delete sections that
don't apply. PRs need (1) all CI checks green and (2) one approving review
before they can be merged.
-->

## Summary

<!-- What does this PR do, and why? Keep it short. -->

## Related issues

<!-- e.g. "Closes #123" / "Part of #45". Link an issue when you can. -->

## Type of change

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 📟 New / improved wearable support (BLE driver layer)
- [ ] 🤖 Coach / LLM change (tools, prompts, orchestration)
- [ ] 🎨 UI / DesignSystem change
- [ ] 🧹 Refactor / chore (no behavior change)
- [ ] 📝 Docs only
- [ ] ⚠️ Breaking change (existing data, settings, or APIs change)

## How was this tested?

<!--
PulseLoop's BLE + Live Activity features need a REAL device — the simulator
can't reach the ring. Tell us what you actually ran:
-->

- [ ] Added / updated unit tests (`PulseLoopTests`)
- [ ] Ran the test suite locally (`⌘U` in Xcode)
- [ ] Tested on a physical device with a real ring — model: <!-- e.g. Colmi R02 -->
- [ ] Tested with demo data (`-seedDemo YES`, no hardware)
- [ ] N/A (docs / non-code change)

## Privacy & data

<!--
PulseLoop is privacy-first: health data stays on device, and the only thing that
leaves is a coach question the user chooses to send. Confirm this PR keeps that promise.
-->

- [ ] This change does **not** send health data off-device without explicit user action.
- [ ] No secrets, API keys, or personal data are committed.
- [ ] N/A

## Screenshots / recordings

<!-- For UI changes, before/after screenshots or a screen recording help a lot. -->

## Checklist

- [ ] My code follows the project's style (SwiftLint passes).
- [ ] I ran the tests and they pass.
- [ ] I updated docs / README where relevant.
- [ ] I read the [Contributing guide](../CONTRIBUTING.md).
