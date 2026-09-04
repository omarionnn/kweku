/// Hit-testing lifecycle for the overlay window.
///
/// The window must sit above the menu bar yet never swallow menu-bar clicks,
/// so it defaults to ignoring mouse events and only opts in while the cursor
/// is inside the notch (`hovering`) or a drag is in flight (`dragArmed`).
public enum HitState: Equatable {
    /// Transparent to the mouse; menu bar / Control Center click through.
    case passive
    /// Cursor is inside the notch rect; the creature can be interacted with.
    case hovering
    /// A drag is in progress anywhere on screen; the drop zone is expanded.
    case dragArmed
}

/// Small deterministic state machine so the mouse-move and drag monitors
/// cannot fight each other. Pure value type — fully unit-testable.
public struct HitStateMachine {
    public private(set) var state: HitState

    public init(state: HitState = .passive) {
        self.state = state
    }

    /// Cursor moved (no drag). Ignored while a drag is armed so drags win.
    /// - Returns: `true` if the state changed.
    @discardableResult
    public mutating func cursorMoved(inside: Bool) -> Bool {
        guard state != .dragArmed else { return false }
        return set(inside ? .hovering : .passive)
    }

    /// A drag began somewhere on screen.
    /// - Returns: `true` if the state changed.
    @discardableResult
    public mutating func dragBegan() -> Bool {
        set(.dragArmed)
    }

    /// A drag ended. Resolves back to hovering/passive from cursor position.
    /// - Returns: `true` if the state changed.
    @discardableResult
    public mutating func dragEnded(insideNow: Bool) -> Bool {
        set(insideNow ? .hovering : .passive)
    }

    @discardableResult
    private mutating func set(_ next: HitState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    /// Whether the window should ignore mouse events in the current state.
    public var ignoresMouseEvents: Bool { state == .passive }

    /// Whether the window frame should be the expanded drop zone.
    public var expanded: Bool { state == .dragArmed }
}
