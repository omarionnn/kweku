import Foundation
import CoreGraphics

/// The Field: everything Kweku draws *outside* the cutout.
///
/// The notch is where Kweku says things to someone who is looking at it. The
/// Field is for the times they aren't — and that reach is exactly why it needs
/// a harder rule than the notch does, not a softer one. An effect out here is
/// either **persistent and still**, or **rare and transient**. Never
/// repetitive and moving: anything that fires often enough out here to become
/// familiar stops being a signal and becomes wallpaper you have trained
/// yourself not to see, which is worse than never having drawn it at all.
///
/// The other rule the Field inherits from the rim: colour is the category,
/// motion is the feeling. A new state does not get a new colour.
public enum Field {}

/// What the screen border is saying.
///
/// Only one thing, on purpose: *something has stopped and is waiting on you*.
/// A border is the most expensive real estate Kweku has — it is in peripheral
/// vision of every window on the display and it cannot be occluded, covered or
/// scrolled past. Spending that on "an agent is working" would mean it is lit
/// most of the working day, and a signal that is usually on is not a signal.
public enum EdgeGlow: Equatable, Sendable {
    case none
    /// `sessions` have stopped and need Omari.
    case owed(sessions: Int)

    public var isLit: Bool { self != .none }

    public var sessions: Int {
        if case .owed(let n) = self { return n }
        return 0
    }
}

/// The glow's arithmetic, kept pure so the thing that decides whether a border
/// is still moving can be checked without a screen.
///
/// The shape of it is *arrive, then settle*: it fades in, breathes three times
/// so it is caught rather than merely present, and then holds one constant
/// opacity until it is resolved. That is how it satisfies both halves of the
/// Field rule at once — the change is the animation, and the state that
/// follows is still. A border that breathed for as long as an agent was stuck
/// would be a hostage situation, and one that appeared with no motion at all
/// would never be seen arriving.
public enum EdgeGlowMotion {
    /// Ramp from nothing to full.
    public static let fadeIn: TimeInterval = 0.9
    /// One breath.
    public static let breathPeriod: TimeInterval = 1.2
    /// Three peaks — at `fadeIn`, and one period either side of it — then down
    /// to rest. The half-period tail is what lands it *on* rest rather than
    /// cutting from a bright frame to a dim one.
    public static let settleAt: TimeInterval = fadeIn + 2.5 * breathPeriod

    /// Where it rests, once it has been noticed. Low enough to live with for
    /// an hour, high enough to still read as lit against a white window.
    public static let restOpacity: CGFloat = 0.34
    public static let peakOpacity: CGFloat = 0.72

    /// Thinnest border, in points, and how much a second, third and fourth
    /// waiting session each add.
    public static let baseThickness: CGFloat = 3
    public static let perSession: CGFloat = 1
    public static let maxExtraSessions = 3

    /// Opacity at `elapsed` seconds since the glow was lit.
    ///
    /// A pure read of the clock, like the drop countdown and the comet, so the
    /// view can be rebuilt at any moment — or not rebuilt at all once it is
    /// still — without the border jumping.
    public static func opacity(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        if elapsed >= settleAt { return restOpacity }
        if elapsed < fadeIn {
            // Smoothstep, so it doesn't arrive with a linear edge.
            let t = CGFloat(elapsed / fadeIn)
            return peakOpacity * (t * t * (3 - 2 * t))
        }
        let phase = (elapsed - fadeIn) / breathPeriod
        let wave = 0.5 + 0.5 * cos(2 * Double.pi * phase)
        return restOpacity + (peakOpacity - restOpacity) * CGFloat(wave)
    }

    /// Whether the border has stopped moving. The view stops driving a clock
    /// the moment this is true, which is what makes a lit border free to leave
    /// up: no timeline, no redraws, one static layer.
    public static func isStill(at elapsed: TimeInterval) -> Bool {
        elapsed >= settleAt
    }

    /// How thick, from how many sessions are waiting.
    ///
    /// Count is carried by width rather than by brightness or by rate, because
    /// width is the only one of the three that can encode a number while
    /// holding perfectly still. Past four it stops counting: "four or more
    /// things are stuck" is one fact, and a border wide enough to distinguish
    /// seven from eight is a border that has become a window chrome.
    public static func thickness(sessions: Int) -> CGFloat {
        guard sessions > 0 else { return 0 }
        let extra = min(sessions - 1, maxExtraSessions)
        return baseThickness + CGFloat(extra) * perSession
    }
}

/// Whether Kweku may draw in the Field at all.
///
/// Deliberately much narrower than `DropGate`. A drop is an interruption, so
/// almost anything you are doing is a reason to hold it back; the edge glow is
/// *state*, and state is not less true because you are typing. Flickering the
/// border off every time a caret appeared would make it useless as a thing you
/// can rely on being there — the whole value of a persistent signal is that
/// its absence means something. So only the two switches that mean "not now,
/// at all" close this gate.
public struct FieldGate: Equatable, Sendable {
    /// Kweku is hidden entirely.
    public var hidden = false
    /// "Pause notices" — the same explicit switch the drops obey.
    public var muted = false

    public init(hidden: Bool = false, muted: Bool = false) {
        self.hidden = hidden
        self.muted = muted
    }

    public var allows: Bool { !(hidden || muted) }
}
