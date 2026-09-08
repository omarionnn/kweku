import SwiftUI

/// Light bleeding in from the edge of the display, because something has
/// stopped and is waiting on Omari.
///
/// The notch already carries this — the rim pulses amber and the creature
/// throws up exclamation eyes — and both are answers for someone whose eyes
/// are near the top of the screen. This is the answer for the other case, and
/// it is the whole reason the Field exists: a border is legible from anywhere
/// on the display with no eye movement at all, and there is no window you can
/// open that hides it.
struct EdgeGlowView: View {
    var glow: EdgeGlow
    /// When it was lit. Opacity is read off this and the clock.
    var shownAt: Date

    /// Eyeballed against the real display corners, like the rest of the
    /// layout in this project. Slightly under the true radius on a MacBook,
    /// which reads as light pooling in the corner rather than as a drawn box
    /// that has missed its target.
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        if glow.isLit {
            // While it is arriving the opacity has to be read per frame; once
            // it has settled there is nothing left to read, and the timeline
            // is dropped rather than left spinning at 20Hz behind a constant
            // value. A lit border costs one static layer.
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: settled)) { context in
                border(opacity: EdgeGlowMotion.opacity(
                    at: context.date.timeIntervalSince(shownAt)))
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// True once the motion is over. Read once per rebuild rather than per
    /// frame — the view is rebuilt when the state changes, and the state
    /// changing is the only thing that can un-settle it.
    private var settled: Bool {
        EdgeGlowMotion.isStill(at: Date().timeIntervalSince(shownAt))
    }

    private func border(opacity: CGFloat) -> some View {
        let thickness = EdgeGlowMotion.thickness(sessions: glow.sessions)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let colour = NotchRim.amber

        // Three passes, tightest last: a wide soft wash for presence, a
        // mid blur for the body of the light, and one crisp hairline so the
        // edge has somewhere to actually be. Same construction as the rim's
        // comet, for the same reason — a single blurred stroke reads as a
        // smudge rather than as something lit.
        return ZStack {
            shape.strokeBorder(colour.opacity(0.20 * opacity), lineWidth: thickness * 3.4)
                .blur(radius: thickness * 3.0)
            shape.strokeBorder(colour.opacity(0.55 * opacity), lineWidth: thickness)
                .blur(radius: thickness * 0.85)
            shape.strokeBorder(colour.opacity(0.85 * opacity), lineWidth: 1)
        }
        .compositingGroup()
        .drawingGroup()
    }
}
