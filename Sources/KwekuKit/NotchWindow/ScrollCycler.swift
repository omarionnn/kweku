import CoreGraphics

/// Turns a stream of raw scroll deltas into discrete "flip to the next mode"
/// steps.
///
/// A trackpad emits dozens of small deltas per swipe plus a momentum tail, so
/// the naive `delta > threshold` check fires four or five times per gesture.
/// This accumulates instead, fires **once**, then refuses to fire again until
/// the gesture ends or the deltas go quiet — the same one-flip-per-swipe feel
/// as a paged scroll view.
///
/// Pure value type, no AppKit — fully unit-testable.
public struct ScrollCycler {
    /// Accumulated scroll distance (points) that completes one flip.
    public var threshold: CGFloat
    /// Deltas at or below this are treated as the gesture going quiet, which
    /// re-arms the cycler for the next swipe.
    public var quietBelow: CGFloat

    private var accumulated: CGFloat = 0
    private var armed = true

    public init(threshold: CGFloat = 28, quietBelow: CGFloat = 1.5) {
        self.threshold = threshold
        self.quietBelow = quietBelow
    }

    /// Feed one scroll event.
    ///
    /// - Returns: `-1` for the previous mode, `+1` for the next, `0` for
    ///   "nothing yet". Following macOS's natural-scrolling convention, a
    ///   right-swipe or an upward scroll goes to the *previous* mode.
    public mutating func feed(deltaX: CGFloat, deltaY: CGFloat) -> Int {
        let dominant = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY

        if abs(dominant) <= quietBelow {
            // Gesture went quiet: drop the partial travel and take the next
            // swipe seriously again.
            accumulated = 0
            armed = true
            return 0
        }
        guard armed else { return 0 }

        // Direction reversal mid-gesture shouldn't cancel out — restart.
        if accumulated != 0 && (accumulated < 0) != (dominant < 0) { accumulated = 0 }
        accumulated += dominant

        guard abs(accumulated) >= threshold else { return 0 }
        let step = accumulated > 0 ? -1 : 1
        accumulated = 0
        armed = false
        return step
    }

    /// The gesture (or its momentum tail) ended: re-arm.
    public mutating func end() {
        accumulated = 0
        armed = true
    }
}
