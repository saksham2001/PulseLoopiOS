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
    let phase: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swing = false

    func body(content: Content) -> some View {
        // Reduce Motion: no rotation, no repeating animation. Reorder still works via drag and the
        // VoiceOver move actions — we simply pin rotation to 0 and skip the wiggle entirely.
        let wiggle = active && !reduceMotion
        return content
            .rotationEffect(.degrees(wiggle ? (swing ? 1.4 : -1.4) : 0))
            .animation(
                wiggle
                    ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(phase)
                    : .easeOut(duration: 0.15),
                value: swing
            )
            .onChange(of: active) { _, now in swing = now && !reduceMotion }
            .onAppear { if wiggle { swing = true } }
    }
}

extension View {
    /// Adds the edit-mode wiggle. `phase` desynchronizes neighboring cards. Honors Reduce Motion.
    func wiggling(active: Bool, phase: Double = 0) -> some View {
        modifier(WiggleModifier(active: active, phase: phase))
    }
}

// MARK: - ReorderableForEach

/// Live-reordering `ForEach` for a `LazyVGrid` or `VStack`. While `isEditing`, each item wiggles,
/// its own taps are disabled (so a tap can't navigate), and it can be dragged; hovering over
/// another item reorders the model immediately via `move(from:to:)`.
///
/// Entry into edit mode is the caller's long-press gesture on each card (kept as-is). In edit mode a
/// corner "–" badge hides the item (→ `hide`); VoiceOver move/hide actions drive the same
/// `move`/`hide` used by drag, since neither the drag nor the badge is reachable without sight.
struct ReorderableForEach<Item: Hashable, Content: View>: View {
    let items: [Item]
    let isEditing: Bool
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void
    /// Hide this item from the screen (edit-mode "–" badge, VoiceOver "Hide").
    let hide: (Item) -> Void
    /// Human-readable name for accessibility ("Heart rate", …).
    let displayName: (Item) -> String
    @ViewBuilder let content: (Item) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element) { index, item in
            let isDragging = dragging == item && isEditing
            content(item)
                .disabled(isEditing)
                // The card visuals + wiggle are decorative for VoiceOver; the accessible label,
                // value, and actions live on the cell wrapper below.
                .accessibilityHidden(isEditing)
                .wiggling(active: isEditing, phase: Double(index % 4) * 0.03)
                // Lift-on-pickup: the dragged card scales up with a shadow; the in-place copy dims and
                // shrinks so the lift reads clearly. Scale is gated under Reduce Motion.
                .scaleEffect(liftScale(isDragging: isDragging))
                .opacity(isDragging ? 0.35 : 1)
                .shadow(color: .black.opacity(isDragging && !reduceMotion ? 0.25 : 0),
                        radius: isDragging && !reduceMotion ? 14 : 0, x: 0, y: 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
                .zIndex(isDragging ? 1 : 0)
                .contentShape(Rectangle())   // full-cell drop target for the LazyVGrid case
                .modifier(DragDropModifier(
                    item: item, items: items, isEditing: isEditing,
                    dragging: $dragging, move: move,
                    preview: {
                        // A picked-up preview: the card lifted with a subtle shadow.
                        content(item)
                            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
                    }
                ))
                // "–" hide badge as an overlay applied AFTER the drag modifier, so it sits above the
                // `.onDrag` layer and its Button wins the hit-test (otherwise the drag gesture swallows
                // the tap and hide never fires).
                .overlay(alignment: .topLeading) {
                    if isEditing {
                        RemoveBadge { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hide(item) } }
                            .offset(x: -6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)   // exposed instead as the "Hide" action below
                    }
                }
                // VoiceOver: while editing, collapse the cell into one element carrying position +
                // move/hide actions (drag is invisible to VO). Outside edit mode the card keeps its own
                // native tap element untouched.
                .modifier(ReorderAccessibility(
                    isEditing: isEditing,
                    label: displayName(item),
                    index: index,
                    count: items.count,
                    move: move,
                    hide: { hide(item) }
                ))
        }
    }

    private func liftScale(isDragging: Bool) -> CGFloat {
        guard isDragging else { return 1 }
        return reduceMotion ? 1 : 1.05
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
                ZStack {
                    Circle().fill(PulseColors.card)
                    Circle().stroke(PulseColors.borderSubtle, lineWidth: 1)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PulseColors.accent)
                }
                .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(PulseColors.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PulseColors.borderSubtle, lineWidth: 1))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(PulseColors.card)
                Circle().stroke(PulseColors.borderSubtle, lineWidth: 1)
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PulseColors.textPrimary)
            }
            .frame(width: 24, height: 24)
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
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
                    item: item, items: items, dragging: $dragging, move: move
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

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = items.firstIndex(of: dragging),
              let to = items.firstIndex(of: item), from != to else { return }
        // Spring the model reorder so cards glide to their new slots instead of snapping.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            move(from, to)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func dropUpdated(info: DropInfo) -> DropProposal { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
