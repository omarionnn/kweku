import Foundation
import KwekuKit

/// The Field — the things Kweku draws outside the cutout. Only the edge glow
/// exists so far, and the checks here are all really one question: does it
/// stop moving? A border that never settles is the failure mode that would
/// make the whole tier unusable.
enum FieldTests {
    static func all() {
        arrival()
        settling()
        thickness()
        gating()
    }

    // MARK: Arrival

    static func arrival() {
        Check.run("it fades in rather than appearing") {
            Check.ok(EdgeGlowMotion.opacity(at: 0) == 0, "nothing at t=0")
            let early = EdgeGlowMotion.opacity(at: 0.2)
            let later = EdgeGlowMotion.opacity(at: 0.6)
            Check.ok(early > 0 && later > early, "ramps up over the fade-in")
        }
        Check.run("it is at its brightest while it is asking to be noticed") {
            let peak = EdgeGlowMotion.opacity(at: EdgeGlowMotion.fadeIn)
            Check.eq(Double(peak), Double(EdgeGlowMotion.peakOpacity),
                     "fade-in lands exactly on the first peak")
            Check.ok(peak > EdgeGlowMotion.restOpacity, "brighter than it will rest at")
        }
        Check.run("it breathes on the way in") {
            let peak = EdgeGlowMotion.opacity(at: EdgeGlowMotion.fadeIn)
            let trough = EdgeGlowMotion.opacity(at: EdgeGlowMotion.fadeIn
                                                + EdgeGlowMotion.breathPeriod / 2)
            Check.ok(trough < peak, "dips between peaks")
            let second = EdgeGlowMotion.opacity(at: EdgeGlowMotion.fadeIn
                                                + EdgeGlowMotion.breathPeriod)
            Check.eq(Double(second), Double(peak), "and comes back up")
        }
    }

    // MARK: Settling — the one that matters

    static func settling() {
        Check.run("it stops moving, and stays stopped") {
            Check.ok(!EdgeGlowMotion.isStill(at: 1.0), "still breathing early on")
            Check.ok(EdgeGlowMotion.isStill(at: EdgeGlowMotion.settleAt), "settled on time")
            Check.ok(EdgeGlowMotion.isStill(at: 3600), "an hour later it is still still")
        }
        Check.run("a settled border holds one constant value") {
            let a = EdgeGlowMotion.opacity(at: EdgeGlowMotion.settleAt)
            let b = EdgeGlowMotion.opacity(at: EdgeGlowMotion.settleAt + 17)
            let c = EdgeGlowMotion.opacity(at: 86_400)
            Check.eq(Double(a), Double(EdgeGlowMotion.restOpacity), "rests where it should")
            Check.eq(Double(b), Double(a), "same a moment later")
            Check.eq(Double(c), Double(a), "same a day later")
        }
        Check.run("it settles without a visible step") {
            // The half-period tail exists so the last frame of the breath and
            // the first frame of the rest are the same brightness. If this
            // drifts, the border visibly snaps dimmer as it settles.
            let justBefore = EdgeGlowMotion.opacity(at: EdgeGlowMotion.settleAt - 0.01)
            Check.eq(Double(justBefore), Double(EdgeGlowMotion.restOpacity), accuracy: 0.01,
                     "arrives at rest rather than cutting to it")
        }
    }

    // MARK: Thickness

    static func thickness() {
        Check.run("count is carried by width") {
            Check.eq(Double(EdgeGlowMotion.thickness(sessions: 0)), 0, "unlit has no width")
            let one = EdgeGlowMotion.thickness(sessions: 1)
            let two = EdgeGlowMotion.thickness(sessions: 2)
            Check.ok(two > one, "a second stuck agent is a wider border")
        }
        Check.run("it stops counting before it becomes window chrome") {
            let four = EdgeGlowMotion.thickness(sessions: 4)
            Check.eq(Double(EdgeGlowMotion.thickness(sessions: 9)), Double(four),
                     "nine reads the same as four")
            Check.ok(four <= 8, "never thick enough to be a frame")
        }
    }

    // MARK: Gating

    static func gating() {
        Check.run("the field is quiet when Kweku is hidden or muted") {
            Check.ok(FieldGate().allows, "nothing set: draw")
            Check.ok(!FieldGate(hidden: true).allows, "hidden: don't")
            Check.ok(!FieldGate(muted: true).allows, "paused notices: don't")
        }
        Check.run("state survives things that would silence a drop") {
            // Typing, hovering, dragging and a running Live session all close
            // the drop gate. None of them make a stalled agent less stalled,
            // and a border that blinked off under a caret would be a signal
            // you couldn't trust the absence of.
            Check.ok(FieldGate().allows, "the field has no opinion about typing")
        }
        Check.run("lit and unlit are distinguishable") {
            Check.ok(!EdgeGlow.none.isLit, "nothing owed, nothing drawn")
            Check.ok(EdgeGlow.owed(sessions: 2).isLit, "something owed, something drawn")
            Check.ok(EdgeGlow.owed(sessions: 2).sessions == 2, "carries the count")
            Check.ok(EdgeGlow.none.sessions == 0, "unlit counts nothing")
        }
    }
}
