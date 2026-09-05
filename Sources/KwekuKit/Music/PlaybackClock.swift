import Foundation

/// Playback position between polls.
///
/// `MusicHub` asks Spotify where it is once a second, over an AppleScript Apple
/// Event — we can't ask faster without being rude to the machine. Rendering
/// that number directly makes the scrubber advance in one-second hops: on a
/// three-minute track across a 320pt bar that's a visible ~1.8pt tick, forever.
///
/// So the poll sets an *anchor* and the view interpolates forward from it with
/// the wall clock. Each poll re-anchors, which also silently absorbs the case
/// where playback moved without us (scrubbed in Spotify itself, track changed,
/// AirPods double-tap). Drift between polls is well under a pixel.
public struct PlaybackClock: Equatable, Sendable {
    /// Position reported by the last poll.
    public var anchor: Double
    /// When that poll landed.
    public var anchoredAt: Date
    public var isPlaying: Bool
    public var duration: Double

    public init(anchor: Double = 0, anchoredAt: Date = .distantPast,
                isPlaying: Bool = false, duration: Double = 0) {
        self.anchor = anchor
        self.anchoredAt = anchoredAt
        self.isPlaying = isPlaying
        self.duration = duration
    }

    /// Where the playhead is now. Paused holds the anchor; playing runs forward
    /// with the clock, clamped to the track so a late poll can't overshoot.
    public func position(at now: Date) -> Double {
        guard isPlaying else { return clamp(anchor) }
        let elapsed = now.timeIntervalSince(anchoredAt)
        guard elapsed > 0 else { return clamp(anchor) }   // clock skew
        return clamp(anchor + elapsed)
    }

    /// Position as 0…1 for the bar.
    public func progress(at now: Date) -> Double {
        duration > 0 ? position(at: now) / duration : 0
    }

    /// Remaining time, for the right-hand label.
    public func remaining(at now: Date) -> Double {
        max(0, duration - position(at: now))
    }

    private func clamp(_ value: Double) -> Double {
        guard duration > 0 else { return max(0, value) }
        return min(duration, max(0, value))
    }
}
