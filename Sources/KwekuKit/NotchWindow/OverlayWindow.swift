import AppKit

/// Borderless, transparent overlay that floats one level above the status
/// window (i.e. above the menu bar) and joins every Space.
public final class OverlayWindow: NSWindow {
    public init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Default: transparent to the mouse so the menu bar keeps its clicks.
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // Keep the window itself from ever stealing key/main from real apps.
        hidesOnDeactivate = false
    }

    // Borderless windows refuse key/main by default; the overlay never needs
    // either — it observes global events instead of holding focus.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
