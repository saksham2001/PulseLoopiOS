# Open-sourcing PulseLoop — CI, templates, merge rules

Goal: make PulseLoop a healthy public OSS repo so contributors can open issues / PRs
and PRs are vetted automatically before merge. Repo: `saksham2001/PulseLoopIOS`.

## Decisions (confirmed with user)
- CI checks: **Build + Unit tests** and **SwiftLint**.
- Repo: use existing remote `saksham2001/PulseLoopIOS`.
- Merge rule: **1 approval (me, via CODEOWNERS) + all CI checks green**.
- Contact (conduct/security): `sakshambhutani2001@gmail.com`.
- Xcode: pin to **latest-stable** on the runner; newest available iOS simulator.

## Plan

### A. Critical prerequisite — shared scheme
- [x] Commit a **shared** `PulseLoop.xcscheme` (currently only in gitignored `xcuserdata/`).
      Without this, `xcodebuild test` cannot run in CI. App + Tests + LiveActivity targets.

### B. CI workflows (`.github/workflows/`)
- [x] `ci.yml` — build app + Live Activity, run XCTest on pinned simulator. No secrets.
- [x] `swiftlint.yml` — lint Swift on PRs.
- [x] `.swiftlint.yml` — config tuned to existing style (not too strict at first).

### C. Templates (`.github/`)
- [x] `PULL_REQUEST_TEMPLATE.md`
- [x] `ISSUE_TEMPLATE/bug_report.yml`
- [x] `ISSUE_TEMPLATE/feature_request.yml`
- [x] `ISSUE_TEMPLATE/new_wearable_support.yml` (fits the device-driver layer)
- [x] `ISSUE_TEMPLATE/config.yml`

### D. Community health + merge rules
- [x] `CONTRIBUTING.md`
- [x] `CODE_OF_CONDUCT.md` (Contributor Covenant)
- [x] `SECURITY.md` (health/privacy app — matters)
- [x] `.github/CODEOWNERS` (`* @saksham2001` → makes my review required)
- [x] `docs/BRANCH_PROTECTION.md` — exact settings + `gh` CLI to enforce the merge rule

## Tests we are doing (and why)
- Build + Unit tests (15 hermetic XCTest suites; mocked OpenAI, in-memory SwiftData → no secrets).
- SwiftLint for consistent contributor style.

## Tests we are deliberately NOT doing
- XCUITest / snapshot tests — app needs real BLE hardware; simulator can't reach the ring.
- TestFlight/fastlane deploy — not distributing via the store.
- Device farm — costs money, can't test the BLE core anyway.

## Review
(to be filled in after implementation)
