import UIKit

/// Attaché draws its own headers with the system navigation bar hidden, and
/// UIKit disables the interactive edge-swipe pop whenever the bar is hidden.
/// Take over the gesture's delegate so swipe-from-left-edge goes back on
/// every pushed screen (stream, approvals, settings, …), matching the
/// swipe-anywhere expectations of a chat app.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only when there's somewhere to pop back to — otherwise the gesture
        // would fight the root screen's horizontal scrolling.
        viewControllers.count > 1
    }
}
