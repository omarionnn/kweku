import AppKit
import SwiftUI

/// The full-screen surface Kweku draws the Field on.
///
/// Everything about it is a refusal: it never takes the mouse, never takes the
/// keyboard, never activates the app, never appears in Mission Control or the
/// window cycle, and is ordered out entirely whenever it has nothing to say.
/// It is a pane of glass laid over the display, and the only thing that makes
/// it acceptable to leave over someone's work all day is that it cannot be
/// interacted with by accident.
///
/// It sits one level *below* `OverlayWindow`: the notch is the thing you act
/// on, so it always wins the top of the stack.
final class FieldWindow: NSPanel {

    private let hosting: NSHostingView<EdgeGlowView>

    init(screen: NSScreen) {
        hosting = NSHostingView(rootView: EdgeGlowView(glow: .none, shownAt: .distantPast))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // One below the notch's overlay. Above ordinary windows and above the
        // menu bar, so the glow hugs the true edge of the display rather than
        // the edge of the area apps are allowed to use.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false

        // Keep Kweku out of Kweku's own eyes.
        //
        // Without this the Field is in every frame the vision pipeline sends
        // to the model and in every screenshot Omari takes: a screen with an
        // amber border, which the model will describe back to him as though it
        // were part of his work. `.none` withholds the window from the window
        // server's capture path, so ScreenCaptureKit, screenshots and screen
        // sharing all miss it — which is the correct answer for all three.
        // The `frame` effect would otherwise annotate the very capture it is
        // reporting on.
        sharingType = .none

        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        contentView = hosting
    }

    // Nothing out here is ever focusable.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Push new state in. Cheap enough to call on every change: when the glow
    /// has settled the view holds no clock at all, so this is one static layer.
    func show(glow: EdgeGlow, shownAt: Date) {
        hosting.rootView = EdgeGlowView(glow: glow, shownAt: shownAt)
    }

    func follow(screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
