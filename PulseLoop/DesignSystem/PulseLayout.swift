import SwiftUI

/// Shared bottom-chrome geometry. The floating tab bar, the coach FAB, and the reorder Done bar all
/// have to clear each other, and on iOS 26 the tab bar is Apple's (system-sized) rather than ours —
/// so the clearances are tuned by eye and belong in one place instead of being re-typed per screen.
enum PulseLayout {
    /// Where a floating control sits above the tab bar. The coach FAB and the reorder Done bar share
    /// this baseline, so the bar can run full width once the FAB is hidden.
    static let floatingBottomInset: CGFloat = 72

    /// Bottom padding a scroll view needs so its last card clears the floating tab bar.
    static let scrollBottomInset: CGFloat = 96

    /// As `scrollBottomInset`, plus room for the reorder Done bar so the last card stays draggable.
    static let scrollBottomInsetEditing: CGFloat = 150
}
