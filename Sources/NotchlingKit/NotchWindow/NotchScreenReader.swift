import AppKit

/// Thin AppKit adapter that reads live `NSScreen` state into pure
/// `NotchMetrics`. Not unit-tested — the maths it feeds is (`NotchGeometry`).
enum NotchScreenReader {
    /// The screen that should host the creature: prefer a physically notched
    /// display, else the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        NotchMetrics(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        )
    }
}
