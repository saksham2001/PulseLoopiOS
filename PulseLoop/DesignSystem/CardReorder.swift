import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Home-screen-style card reordering: enter an "edit" mode (via a card's context menu) where the
// cards wiggle and can be dragged to new positions. The model reorders live as a dragged card
// hovers a new slot; the caller persists the final order. In edit mode each card also shows a
// home-screen-style "–" badge to hide it, and exposes VoiceOver "Move up / Move down / Move to
// top / Hide" actions so reordering works without a visible drag.

// MARK: - Wiggle

private struct WiggleModifier: ViewModifier {
    let active: Bool
    /// How long this card waits before it starts swinging, somewhere inside one full cycle. Since every
    /// card then swings at the same speed, the offset it lands on is fixed — the cards sit at different
    /// points of the same wiggle and stay there, instead of pulsing in lockstep or drifting apart.
    let startDelay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var running = false

    /// Rotation amplitude. Deliberately smaller than the ~1.4° a home-screen icon uses: rotation
    /// displaces a corner in proportion to its distance from the centre, so on a ~180pt card the same
    /// angle throws the corner about three times as far as it does on a 60pt icon. Matching the
    /// *travel* rather than the angle is what makes this read as iOS's jiggle instead of a shudder.
    private static let amplitude: Double = 0.6
    /// One swing, extreme to extreme. Identical for every card; only the start time differs.
    static let halfCycle: Double = 0.20

    // A `PhaseAnimator`, not a `@State` flag driving `.repeatForever`.
    //
    // The flag version wiggled once and never again. Toggling edit mode flips the `if isEditing`
    // branch inside `DragDropModifier` and `ReorderAccessibility`, which rebuilds this subtree — so
    // the modifier is *recreated* with `active` already at its new value rather than updated through
    // a transition, and `onChange(of: active)` never fires (verified: it logged zero times across
    // three toggles). The flag was therefore never reset on exit, and on re-entry setting it `true`
    // again was a no-op, so `.animation(value:)` never triggered and the card sat at a static tilt.
    // A phase animator is rebuilt along with the subtree: entering edit mode always constructs a
    // fresh, already-running animation, and leaving removes it outright.
    func body(content: Content) -> some View {
        // Reduce Motion: no rotation at all. Reorder still works via drag and the VoiceOver actions.
        if active && !reduceMotion {
            Group {
                if running {
                    content.phaseAnimator([-Self.amplitude, Self.amplitude]) { view, angle in
                        view.rotationEffect(.degrees(angle))
                    } animation: { _ in
                        // Never vary this per card. A per-card duration desyncs by *speed*, so
                        // neighbours slide further apart every cycle until the grid looks ragged.
                        .easeInOut(duration: Self.halfCycle)
                    }
                } else {
                    content
                }
            }
            .task {
                // `@State` outlives an edit session here (the subtree is rebuilt but its storage is
                // reused), so reset rather than trusting a fresh `false`, and re-stagger on every entry.
                running = false
                try? await Task.sleep(for: .seconds(startDelay))
                running = true
            }
        } else {
            content
        }
    }
}

extension View {
    /// Adds the edit-mode wiggle. `startDelay` offsets this card within the shared swing so neighbours
    /// aren't in lockstep. Honors Reduce Motion.
    func wiggling(active: Bool, startDelay: Double = 0) -> some View {
        modifier(WiggleModifier(active: active, startDelay: startDelay))
    }
}

// MARK: - Reorder cell

/// Caches a card's rendered body across reorders.
///
/// Every card here is a Swift Charts view; several wrap a `Canvas` that re-tessellates its line on
/// each render. Reordering changes only a cell's *position*, so re-running those bodies once per
/// dragged-over cell is pure waste — and it is what made the drag stutter. `Equatable` is written by
/// hand (a stored `@ViewBuilder` closure can't be synthesised) and deliberately ignores `content`:
/// when `item` and `revision` match, the card's data is unchanged, so the cached render is still the
/// correct render and SwiftUI may skip `body` entirely.
///
/// `revision` must therefore be bumped by whatever rebuilds the card data — see `TodayStore.revision`.
struct ReorderCell<Item: Hashable, Content: View>: View, Equatable {
    let item: Item
    let revision: Int
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (lhs: ReorderCell, rhs: ReorderCell) -> Bool {
        lhs.item == rhs.item && lhs.revision == rhs.revision
    }
}

// MARK: - ReorderableForEach

/// Live-reordering `ForEach` for a `LazyVGrid` or `VStack`. While `isEditing`, each item wiggles,
/// its own taps are disabled (so a tap can't navigate), and it can be dragged; hovering over
/// another item reorders the model immediately via `move(from:to:)`. `commit` fires once when the
/// drag is dropped, so the caller can persist a single time instead of on every hover.
///
/// Entry into edit mode is the caller's long-press gesture on each card (kept as-is). In edit mode a
/// corner "–" badge hides the item (→ `hide`); VoiceOver move/hide actions drive the same
/// `move`/`hide` used by drag, since neither the drag nor the badge is reachable without sight.
struct ReorderableForEach<Item: Hashable, Content: View>: View {
    let items: [Item]
    let isEditing: Bool
    /// Data revision of the underlying cards; see `ReorderCell`. Reordering must not change this.
    let revision: Int
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void
    /// Called once when a drag is dropped on a cell, so the caller persists the final order.
    let commit: () -> Void
    /// Hide this item from the screen (edit-mode "–" badge, VoiceOver "Hide").
    let hide: (Item) -> Void
    /// Human-readable name for accessibility ("Heart rate", …) and the drag chip.
    let displayName: (Item) -> String
    /// SF Symbol for the drag chip.
    let symbolName: (Item) -> String
    @ViewBuilder let content: (Item) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element) { index, item in
            let isDragging = dragging == item && isEditing
            // Only the card itself goes inside the shim. Everything below reads `index`, `count`, or
            // `isDragging` — values that legitimately change on a reorder — and either transforms the
            // cached render (scale/opacity/shadow are compositing, not layout) or lives outside it.
            ReorderCell(item: item, revision: revision) { content(item) }
                .equatable()
                // `.disabled` writes the `isEnabled` environment, which does propagate through the
                // shim — but only on enter/exit of edit mode, never on a hover, so the hot path is safe.
                .disabled(isEditing)
                // The card visuals + wiggle are decorative for VoiceOver; the accessible label,
                // value, and actions live on the cell wrapper below.
                .accessibilityHidden(isEditing)
                .wiggling(active: isEditing, startDelay: Self.wiggleDelay(item))
                // Lift-on-pickup: the dragged card scales up with a shadow; the in-place copy dims so
                // the lift reads clearly. Scale is gated under Reduce Motion.
                .scaleEffect(liftScale(isDragging: isDragging))
                .opacity(isDragging ? 0.6 : 1)
                .shadow(color: .black.opacity(isDragging && !reduceMotion ? 0.16 : 0),
                        radius: isDragging && !reduceMotion ? 10 : 0, x: 0, y: 8)
                .animation(.spring(response: 0.30, dampingFraction: 0.85), value: isDragging)
                .zIndex(isDragging ? 1 : 0)
                .contentShape(Rectangle())   // full-cell drop target for the LazyVGrid case
                .modifier(DragDropModifier(
                    item: item, items: items, isEditing: isEditing,
                    dragging: $dragging, move: move, commit: commit,
                    preview: {
                        // A compact chip, not the card: rendering `content(item)` again would build a
                        // second Swift Charts view at pickup, which is the cost this whole path avoids.
                        ReorderDragChip(name: displayName(item), symbol: symbolName(item))
                    }
                ))
                // "–" hide badge as an overlay applied AFTER the drag modifier, so it sits above the
                // `.onDrag` layer and its Button wins the hit-test (otherwise the drag gesture swallows
                // the tap and hide never fires).
                .overlay(alignment: .topLeading) {
                    if isEditing {
                        RemoveBadge { withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) { hide(item) } }
                            .offset(x: RemoveBadge.cornerOffset, y: RemoveBadge.cornerOffset)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)   // exposed instead as the "Hide" action below
                    }
                }
                // VoiceOver: while editing, collapse the cell into one element carrying position +
                // move/hide actions (drag is invisible to VO). Outside edit mode the card keeps its own
                // native tap element untouched. Must sit outside the shim — position tracks moves.
                .modifier(ReorderAccessibility(
                    isEditing: isEditing,
                    label: displayName(item),
                    index: index,
                    count: items.count,
                    // A VoiceOver move is a discrete action, not a drag, so it never reaches a drop
                    // delegate — commit each one rather than waiting for an exit that a tab switch
                    // could tear down first.
                    move: { from, to in move(from, to); commit() },
                    hide: { hide(item) }
                ))
        }
    }

    /// Spreads the cards across one full swing cycle (two half-cycles), so no two neighbours start
    /// together and none share a phase. Derived from the item, not its index: an index-based value
    /// would change the moment a card moves, restarting its wiggle mid-drag.
    private static func wiggleDelay(_ item: Item) -> Double {
        let buckets = 5
        let cycle = WiggleModifier.halfCycle * 2
        return Double(abs(item.hashValue % buckets)) * (cycle / Double(buckets))
    }

    private func liftScale(isDragging: Bool) -> CGFloat {
        guard isDragging else { return 1 }
        return reduceMotion ? 1 : 1.02
    }
}

// MARK: - Drag chip

/// The lifted preview under the finger while dragging a card: a compact glass capsule naming the
/// metric. Cheap by construction — the real card stays in place, dimmed, so nothing is lost.
private struct ReorderDragChip: View {
    let name: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(PulseColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .pulseGlass(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Hidden tray

/// The "Hidden" restore tray shown only while editing, below the visible cards. Lists the metrics
/// hidden in this scope as compact dimmed rows with a "+" badge; tapping (or the VoiceOver "Show"
/// action) restores the metric. Renders nothing when nothing is hidden.
struct HiddenMetricsTray<Item: Hashable>: View {
    /// The hidden items, in a stable presentation order.
    let hidden: [Item]
    /// Restore this item (caller wraps `prefs.setHidden(item, false, scope:)`).
    let restore: (Item) -> Void
    /// Human-readable name for the row + accessibility.
    let displayName: (Item) -> String
    /// SF Symbol representing the metric, for the row's leading glyph.
    let symbolName: (Item) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("HIDDEN")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(PulseColors.textSecondary)
                    .padding(.leading, 4)

                VStack(spacing: 8) {
                    ForEach(hidden, id: \.self) { item in
                        HiddenRow(
                            name: displayName(item),
                            symbol: symbolName(item),
                            restore: {
                                if reduceMotion {
                                    restore(item)
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { restore(item) }
                                }
                            }
                        )
                    }
                }
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
    }
}

private struct HiddenRow: View {
    let name: String
    let symbol: String
    let restore: () -> Void

    var body: some View {
        Button(action: restore) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PulseColors.textSecondary)
                    .frame(width: 22)
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer(minLength: 8)
                // A solid disc, not another glass surface: glass inside glass muddies both.
                ZStack {
                    Circle().fill(PulseColors.card)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PulseColors.accent)
                }
                .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .pulseGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
            // As in `RemoveBadge`: the glass surface is a `.background`, so the row needs its own
            // shape or only the label glyphs and the "+" disc would answer a tap.
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), hidden")
        .accessibilityHint("Double-tap to show this card.")
        .accessibilityActions {
            Button("Show") { restore() }
        }
    }
}

// MARK: - Remove badge

/// Home-screen-style "–" badge shown at a card corner while editing. Tapping hides the metric.
private struct RemoveBadge: View {
    /// Visible disc. The tap target is `hitSize`, centred on it.
    static let size: CGFloat = 24
    private static let hitSize: CGFloat = 36
    /// How far the *hit frame* must be offset for the visible disc to straddle the card's corner.
    static let cornerOffset: CGFloat = -6 - (hitSize - size) / 2

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PulseColors.textPrimary)
                .frame(width: Self.size, height: Self.size)
                .pulseGlass(Circle(), interactive: true)
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                // `pulseGlass` draws through `.background`, which adds no hit region, so without an
                // explicit shape the button's target collapses to the minus glyph's strokes. Widen it
                // past the disc too — 24pt is a small thing to hit while every card is wiggling.
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Done bar

/// Floating "Drag to reorder / Done" pill, positioned by `MainTabView` just above the tab bar while
/// editing. Shared by Today and Vitals so the two edit modes can't drift apart.
struct ReorderDoneBar: View {
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
            Text("Drag to reorder").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 12)
            Button(action: done) {
                Text("Done").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            // `.pulseTap` brings its own `contentShape` and consumes the touch, so "Done" gets a real
            // hit area instead of only its glyphs.
            .buttonStyle(.pulseTap)
        }
        .foregroundStyle(PulseColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .pulseGlass(Capsule(), interactive: true)
        // `pulseGlass` paints its surface with `.background`, which draws but adds no hit region — so
        // without this, every touch outside the "Done" glyphs fell straight through to the card
        // beneath. `BottomNavBar` carries a `contentShape` for exactly this reason. Tapping the label
        // does nothing on purpose: exiting on a stray label tap would fire during fumbled drags.
        .contentShape(Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - VoiceOver reorder actions

private struct ReorderAccessibility: ViewModifier {
    let isEditing: Bool
    let label: String
    let index: Int
    let count: Int
    let move: (_ from: Int, _ to: Int) -> Void
    let hide: () -> Void

    func body(content: Content) -> some View {
        if isEditing {
            content
                // Collapse the wiggling card + badge into a single VoiceOver element that carries the
                // metric name, its slot position, and the move/hide actions.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue("\(index + 1) of \(count)")
                .accessibilityHint("Use actions to move or hide this card.")
                .accessibilityActions {
                    if index > 0 {
                        Button("Move up") { move(index, index - 1) }
                        Button("Move to top") { move(index, 0) }
                    }
                    if index < count - 1 {
                        Button("Move down") { move(index, index + 1) }
                    }
                    Button("Hide") { hide() }
                }
        } else {
            content
        }
    }
}

// MARK: - Drag & drop

private struct DragDropModifier<Item: Hashable, Preview: View>: ViewModifier {
    let item: Item
    let items: [Item]
    let isEditing: Bool
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void
    let commit: () -> Void
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if isEditing {
            content
                .onDrag {
                    dragging = item
                    return NSItemProvider(object: String(describing: item.hashValue) as NSString)
                } preview: {
                    preview()
                }
                // Attach the drop to the full-frame, `contentShape`-covered cell so hovering
                // anywhere over a card (not just its opaque pixels) triggers the reorder.
                .onDrop(of: [.text], delegate: ReorderDropDelegate(
                    item: item, items: items, dragging: $dragging, move: move, commit: commit
                ))
        } else {
            content
        }
    }
}

// MARK: - MetricKey presentation

extension MetricKey {
    /// Human-readable card name for reorder/hide accessibility and the Hidden tray. Reuses
    /// `MetricKind.title` for shared metrics; covers the Today-only tiles (steps, sleep) directly.
    var reorderDisplayName: String {
        switch self {
        case .steps: return "Activity"
        case .sleep: return "Sleep"
        case .heartRate: return MetricKind.heartRate.title
        case .spo2: return MetricKind.spo2.title
        case .hrv: return MetricKind.hrv.title
        case .temperature: return MetricKind.temperature.title
        case .stress: return MetricKind.stress.title
        case .fatigue: return MetricKind.fatigue.title
        case .bloodSugar: return MetricKind.glucose.title
        case .bloodPressureSystolic: return MetricKind.bloodPressure.title
        case .bloodPressureDiastolic: return "Blood pressure (diastolic)"
        case .calories: return "Calories"
        case .distance: return "Distance"
        case .activeMinutes: return "Active minutes"
        case .battery: return "Battery"
        }
    }

    /// SF Symbol for the Hidden tray's leading glyph.
    var reorderSymbolName: String {
        switch self {
        case .steps: return "figure.walk"
        case .sleep: return "bed.double.fill"
        case .heartRate: return "heart.fill"
        case .spo2: return "drop.fill"
        case .hrv: return "waveform.path.ecg"
        case .temperature: return "thermometer.medium"
        case .stress: return "brain.head.profile"
        case .fatigue: return "battery.25"
        case .bloodSugar: return "cube.fill"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "heart.text.square"
        case .calories: return "flame.fill"
        case .distance: return "location.fill"
        case .activeMinutes: return "figure.run"
        case .battery: return "battery.100"
        }
    }
}

private struct ReorderDropDelegate<Item: Hashable>: DropDelegate {
    let item: Item
    let items: [Item]
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = items.firstIndex(of: dragging),
              let to = items.firstIndex(of: item), from != to else { return }
        // Spring the model reorder so cards glide to their new slots instead of snapping. `move` is
        // expected to touch view-local state only — persisting here would put a synchronous encode on
        // the drag loop, which is what it used to do.
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            move(from, to)
        }
        MainActor.assumeIsolated { ReorderHaptics.selection.selectionChanged() }
    }

    func dropUpdated(info: DropInfo) -> DropProposal { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        commit()   // the single persist per drag
        return true
    }
}
