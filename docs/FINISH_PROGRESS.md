# PulseLoop — Finish-the-App Progress Tracker

Live tracker for the run-to-done loop in `docs/FINISH_THE_APP_LOOP_PROMPT.md`.
Visual north-star: `claude design/Black and white modular redesign/PulseLoop App.dc.html`.
Build gate: `xcodebuild -project PulseLoop.xcodeproj -scheme PulseLoop -destination 'platform=iOS Simulator,id=CFAB47DC-4676-469B-AA5F-29EED5A93200' build`.

## Canonical recipe (locked reference — the Home/Today screen)

- **Canvas:** `PulseColors.background` / `PulseColors.canvas` (warm off-white in light, near-black in dark).
- **Cards:** `PulseCard` / `.pulseCardSurface()` — white fill, `PulseRadius.large` corners, hairline border + 1px soft shadow.
- **Inset panels:** `PulseColors.fillSubtle` fill, same radius, no shadow.
- **Hero card:** solid **black** = `PulseColors.accent` (token resolves `#161616` light / white dark), white text, `PulseRadius.xLarge`. *(Confirmed: the monochrome "ink" accent IS the hero/primary color; data colors are separate.)*
- **Type:** Newsreader (`PulseFont.title*`) for display titles; Hanken Grotesk (`PulseFont.body*`) for everything else; uppercase letter-spaced eyebrows via `EyebrowLabel`; `.monospacedDigit()` on numbers.
- **Controls:** `PrimaryButton` (black), `SecondaryButton` (outline), `PillToggle`/new `SegmentedControl`, `StatusChip`, icon tile = SF Symbol in `fillSubtle` rounded square.
- **Rhythm:** `EyebrowLabel`/`SectionHeader` + content, hairline dividers inside cards, generous whitespace.

## Definition of Done status (§0)

| # | Criterion | Status |
|---|---|---|
| 1 | Beautiful & consistent (one design system, 3 themes) | in progress |
| 2 | Nothing is a dead end | done (all 10 DEADENDS cleared, build green) ✓ |
| 3 | Nothing missing (onboarding, every menu item real, module states) | pending |
| 4 | Lived-in (seed data + reset-to-empty) | pending |
| 5 | Single next action obvious (black hero) | partial (Home has it) |
| 6 | Data shown beautifully (flat graphs) | partial (chart kit exists) |
| 7 | AI is connective tissue (context FAB, inbox nudges, per-module AI) | partial |
| 8 | Quality (build green, a11y, tests) | build green ✓ |

## Iterations

### A1 — Lock canonical + create trackers — DONE
- Confirmed `pulseAccent` = `#161616` light / white dark → the black hero/primary is already the accent token. Recipe locked above.
- Audited `App/AppTheme.swift` + `DesignSystem/Components.swift`. Existing shared primitives: `PulseCard`, `MetricTile`, `MiniSparkline`, `PrimaryButton`, `SecondaryButton`, `PillToggle`, `StatusChip`, `EyebrowLabel`, `SectionHeader` (in RootViews), `HeroInsightCardView`, `CoachMessageCard`, `MetricCardButton`, `ProgressRingView`, `DetailCard`, `QuickActionButton`, `ActivitySectionCard`, charts.
- Missing shared components identified: `HeroCard` (black next-action), `IconTileRow`, `SegmentedControl`, `EmptyStateCard` (designed). 
- Created: `docs/FINISH_PROGRESS.md`, `docs/DEADENDS.md`.

### A2 — Promote shared components — DONE
- Added `HeroCard`, `IconTileRow`, `SegmentedControl`, `EmptyStateCard` to `DesignSystem/Components.swift` with previews; documented in `.cursor/rules/design-system.mdc`.

### C1 — Kill every dead end — DONE
- Cleared all 10 items in `docs/DEADENDS.md` (TodayView Ask Assistant, Privacy activity-log + export/delete, Profile/Friends invite share sheets, Messenger compose + send, NoteEditor settings, Vitals coming-soon → designed "calibrating" cards). Build green.

### B1 — Emoji → SF Symbols consistency sweep — DONE
Removed every pictographic emoji from rendered UI (design-system rule #1) and fixed several latent "emoji-in-a-symbol-field" rendering bugs where a literal glyph was being passed to `Image(systemName:)`:
- **`Models/JournalCatalog.swift`** — converted all 21 metric icons from emoji to SF Symbols; `JournalView` row now renders via `Image(systemName:)`.
- **`Coach/Config/CoachSettings.swift`** — `CoachPersonality.emoji` → `iconSystemName` (SF Symbols); updated 3 render sites (`CommandPaletteView` ×2, `CoachSettingsSection`).
- **`Views/QuitProgramView.swift`** — substance presets + custom + hero now SF Symbols, rendered via `Image`.
- **`Views/FriendsView.swift`** — `moodEmoji` → SF Symbols (weather scale) with `moodColor`; vice icon via `Image`.
- **`Views/WorkoutBodyHabitsViews.swift`** — habit row icon via `Image` (picker was already SF Symbols).
- **`Views/HealthView.swift`** — `emojiForType` workout icons → SF Symbols via `Image`.
- **`Views/MessengerView.swift`** — mood picker uses word labels instead of emoji glyphs.
- **`Views/ProductScanView.swift`**, **`Views/ProtocolDetailView.swift`** — product/medication icons via `Image`.
- Fixed literal-emoji values feeding symbol fields in: `SupplementKnowledge.swift` (☀️/❤️), `SeedData.swift` (☀️/☕), `OpenFDAService.swift` (💊), `OpenFoodFactsService.swift` (💊/🍽️), `CommandPaletteView.swift` (💊/🧬), `TrackerView.swift` (🍽️), `NoteTools.swift`/`NoteEditorView.swift` (📁/🗂 collections).

### B1-bonus — `.gitignore` latent bug — FIXED
- `Models/` and `Frameworks/` patterns were **un-anchored**, so they silently git-ignored the app's own `PulseLoop/Models/*.swift` source (8 files incl. `LifeOSModels`, `JournalCatalog`, `FitnessModels`). Anchored to `/Models/` and `/Frameworks/` (repo-root only). App model sources are tracked again; root espeak `Models/` data stays ignored.

### B2 — `.font(.system(...))` → `PulseFont` (shared Components) — DONE
- Converted every **text** `.system` font in `DesignSystem/Components.swift` to `PulseFont` (Newsreader for display numbers/titles, Hanken for body/labels); left `.system` only on `Image` (SF Symbol sizing, the correct convention). Highest leverage since all screens compose from this file.
- Flattened `HeroInsightCardView` from a colored `LinearGradient` to a flat white `PulseColors.card` surface with `EyebrowLabel` + Newsreader title, per the locked recipe.
- Replaced the week-strip "✓"/"•" glyphs with an SF Symbol checkmark + a filled today-dot.
- `QuickActionButton` accent foreground `.white` → `PulseColors.background` (flips correctly in dark).

## NEXT ITEM
B3 — extend the `.font(.system(...))` → `PulseFont` text sweep into the high-traffic screens (NoteEditorView, FriendsView, TrackerView, HomeView), one file per iteration with a build gate.

## Follow-ups / notes
- Many screens still use `.font(.system(...))` and hardcoded radii (incl. parts of Home + Components.swift). Tracked for Phase B/C consistency sweep.
- `HeroInsightCardView` uses a gradient — spec wants flat monochrome; revisit in Phase B.
