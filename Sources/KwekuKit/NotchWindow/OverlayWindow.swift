import AppKit

/// Borderless, transparent overlay that floats one level above the status
/// window (i.e. above the menu bar) and joins every Space.
///
/// An `NSPanel` rather than a plain `NSWindow`, and specifically a
/// `.nonactivatingPanel`: the notch has to be able to take keyboard focus for
/// the command field, but it must never pull the whole app forward to do it.
/// A normal window would require `NSApp.activate`, which deactivates whatever
/// you were working in — and since the command line's whole purpose is to act
/// on what you were just looking at, stealing that context to ask about it
/// would be self-defeating.
public final class OverlayWindow: NSPanel {
    /// Whether the panel will accept key right now. Off by default: an overlay
    /// that sits above the menu bar all day must not hold focus, and only the
    /// command field has any use for it.
    public var acceptsKeyboard = false {
        didSet {
            guard acceptsKeyboard != oldValue else { return }
            if acceptsKeyboard {
                makeKeyAndOrderFront(nil)
            } else if isKeyWindow {
                // Hand key back rather than merely dropping the claim, or the
                // keystrokes go nowhere until something else is clicked.
                resignKey()
                orderFrontRegardless()
            }
        }
    }

    public init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
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
        // Panels hide themselves when their app deactivates; this one is the
        // whole UI of an accessory app and has to outlive that.
        hidesOnDeactivate = false
        // Don't let AppKit decide on our behalf that a click "needs" key.
        becomesKeyOnlyIfNeeded = false
    }

    // Borderless windows refuse key by default, and the overlay wants none of
    // it except while the command field is up. `main` stays refused always —
    // there is no menu bar for it to own.
    public override var canBecomeKey: Bool { acceptsKeyboard }
    public override var canBecomeMain: Bool { false }
}
