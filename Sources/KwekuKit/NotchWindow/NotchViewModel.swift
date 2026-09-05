import SwiftUI

/// The only channel between `NotchWindow` and whatever view it hosts.
///
/// `NotchWindow` publishes geometry + interaction state here; the injected
/// view (and its own model) read it. This keeps the window free of any
/// knowledge of the creature.
///
/// Uses `ObservableObject` rather than the `@Observable` macro because the
/// deployment target is macOS 13 (Observation is 14+).
@MainActor
public final class NotchViewModel: ObservableObject {
    // MARK: Geometry (window -> content)

    /// Current notch size in points (content pins to the top edge).
    @Published public var notchSize: CGSize = .zero
    /// `true` while the drop zone is expanded (a drag is armed).
    @Published public var expanded: Bool = false
    /// `true` on a non-notched display (synthetic pill).
    @Published public var isSynthetic: Bool = false

    // MARK: Interaction (window -> content)

    /// Absolute cursor position in global (bottom-left) screen coordinates,
    /// republished from the shared `.mouseMoved` monitor — no extra monitor.
    @Published public var globalCursor: CGPoint = .zero
    /// Current on-screen centre of the hosted content, in global coordinates.
    /// Tracks the window as it slides, so eye direction stays correct.
    @Published public var contentCenter: CGPoint = .zero
    /// `true` while the user is dragging the creature sideways.
    @Published public var isDragging: Bool = false
    /// `true` while the cursor is within the (possibly grown) content window.
    @Published public var isHovering: Bool = false
    /// Whether the hosted content wants the sideways window-drag gesture
    /// (creature: yes; music island with scrubber/buttons: no).
    @Published public var contentDraggable: Bool = true
    /// Incremented on a plain click (down+up, no drag) inside the content.
    @Published public var tapCount: Int = 0
    /// Running total of mode flips requested by scrolling over the notch:
    /// `+1` per "next", `-1` per "previous". Content diffs it against the last
    /// value it saw, so a missed update can never desynchronise the mode.
    @Published public var cycleSteps: Int = 0
    /// Horizontal speed of the notch window in points/second — positive
    /// rightwards. Published while the creature is being dragged and while it
    /// springs home, so the content can lean into the motion.
    @Published public var slideVelocity: CGFloat = 0

    // MARK: Layout (content -> window)

    /// Size the hosted content wants the window to be. The controller sizes
    /// the window to this, pinned to the notch's top edge and centred (unless
    /// mid-slide). Lets the content grow to reveal the shelf without the
    /// window ever knowing what a shelf is.
    @Published public var desiredSize: CGSize = .zero

    public init() {}
}
