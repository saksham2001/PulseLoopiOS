import SwiftUI
import UIKit

/// Which screen, if any, is currently in card-reorder edit mode.
///
/// Edit mode is entered deep inside a tab (a long-press on a Today tile or a Vitals card) but its
/// chrome is rendered at the root: the Done bar floats above the tab bar, and the coach FAB has to
/// get out of the way. A shared observable is how that crosses the gap.
///
/// A `PreferenceKey` would be the usual way to bubble state up, but it can't work here: on iOS
/// 18–25 the paged `TabView` keeps adjacent tabs alive, so an off-screen tab would publish
/// `editing == false` and stomp the active tab's `true`.
@MainActor
@Observable
final class CardReorderSession {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = CardReorderSession()

    /// The scope being edited, or `nil` when no screen is in edit mode. Only one at a time: the
    /// long-press that enters edit mode is only reachable on the visible tab.
    private(set) var editingScope: MetricScope?

    var isEditing: Bool { editingScope != nil }

    func begin(_ scope: MetricScope) { editingScope = scope }

    func end() { editingScope = nil }
}

/// One retained, pre-warmed selection generator. `dropEntered` fires on every cell a dragged card
/// crosses, and allocating a fresh `UISelectionFeedbackGenerator` there both costs time and skips
/// the warm-up that makes the tap land promptly.
@MainActor
enum ReorderHaptics {
    static let selection = UISelectionFeedbackGenerator()
}

// MARK: - Order helpers

/// Pure list operations behind the drag. Free functions so they can be unit-tested without a view.
enum CardOrder {

    /// Moves `from` to `to`, matching drag semantics: `to` indexes the array *before* the removal.
    static func moving<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: min(max(to, 0), result.count))
        return result
    }

    /// Folds a freshly-derived `target` into the order the user is currently looking at.
    ///
    /// A ring sync can rebuild the store mid-edit. Re-deriving the list outright would throw away an
    /// in-progress reorder, so instead: keep `current`'s order for every key that survives, drop the
    /// ones that vanished, and slot genuinely-new keys in at the index `target` puts them.
    static func reconcile<T: Hashable>(current: [T], target: [T]) -> [T] {
        let wanted = Set(target)
        var result = current.filter(wanted.contains)
        let present = Set(result)
        for (index, key) in target.enumerated() where !present.contains(key) {
            result.insert(key, at: min(index, result.count))
        }
        return result
    }
}
