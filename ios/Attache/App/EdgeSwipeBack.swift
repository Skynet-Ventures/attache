import SwiftUI

/// Swipe-from-left-edge to go back on pushed screens.
///
/// Attaché hides the system navigation bar for its custom headers, and on
/// current iOS the SwiftUI NavigationStack doesn't expose UIKit's interactive
/// pop gesture to re-enable. This puts an invisible 24pt strip along the
/// leading edge that dismisses on a rightward drag — narrow enough not to
/// fight horizontal scrolling in the content.
struct EdgeSwipeBack: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Color.clear
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .highPriorityGesture(
                    DragGesture(minimumDistance: 15)
                        .onEnded { value in
                            if value.translation.width > 50, abs(value.translation.height) < 90 {
                                dismiss()
                            }
                        }
                )
        }
    }
}

extension View {
    func edgeSwipeBack() -> some View {
        modifier(EdgeSwipeBack())
    }
}
