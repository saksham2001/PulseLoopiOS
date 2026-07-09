import SwiftUI
import UIKit

/// Re-enables the interactive edge-swipe-back gesture on screens that hide the system
/// navigation bar. Hiding the bar (`toolbar(.hidden, for: .navigationBar)`) makes UIKit
/// disable `interactivePopGestureRecognizer`, so swipe-to-go-back silently dies. This
/// zero-size representative re-enables it and installs a delegate that permits the swipe
/// whenever there's something to pop back to. Installed once via `pageChrome`.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.reenablePopGesture()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            reenablePopGesture()
        }

        func reenablePopGesture() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = self
        }

        // Allow the edge swipe only when a pop target exists (not on the stack root).
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

extension View {
    /// Restores edge-swipe-back on a nav-bar-hidden screen. No-op cost: a 0×0 host.
    /// Use on any screen that hides the system nav bar inside a `NavigationStack`.
    func enablesBackSwipe() -> some View {
        background(SwipeBackEnabler().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Standard page chrome for pushed screens: a glass circular back button on the
/// left, a centered title with consistent typography, and an optional trailing
/// control. Used in place of the system navigation bar so every detail/settings
/// page reads the same — and, since there's no nav-bar content inset, the zoom
/// transition into a page never reflows the content.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Centered title — one canonical style for every page.
            Text(title)
                .font(PulseFont.headline)
                .foregroundStyle(PulseColors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(PulseFont.bodyEmphasis)
                        .foregroundStyle(PulseColors.textPrimary)
                        .frame(width: 36, height: 36)
                        .pulseGlass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

extension View {
    /// Standard glass page chrome (centered title + glass back button), replacing
    /// the system nav bar. Apply to the screen's root content.
    func pageChrome(_ title: String) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title) { EmptyView() }
            self
        }
        .toolbar(.hidden, for: .navigationBar)
        .enablesBackSwipe()
    }

    /// Same, with a trailing control (e.g. an edit/delete button) in the header —
    /// for pages that used to put actions in the system toolbar.
    func pageChrome<T: View>(_ title: String, @ViewBuilder trailing: @escaping () -> T) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title, trailing: trailing)
            self
        }
        .toolbar(.hidden, for: .navigationBar)
        .enablesBackSwipe()
    }
}
