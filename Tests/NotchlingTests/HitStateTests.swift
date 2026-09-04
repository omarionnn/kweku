import NotchlingKit

enum HitStateTests {
    static func all() {
        Check.run("starts passive and transparent to the mouse") {
            let m = HitStateMachine()
            Check.ok(m.state == .passive, "passive")
            Check.ok(m.ignoresMouseEvents, "ignores mouse")
            Check.ok(!m.expanded, "not expanded")
        }

        Check.run("hover enters and leaves") {
            var m = HitStateMachine()
            Check.ok(m.cursorMoved(inside: true), "passive -> hovering changes")
            Check.ok(m.state == .hovering, "hovering")
            Check.ok(!m.ignoresMouseEvents, "receives mouse while hovering")
            Check.ok(!m.cursorMoved(inside: true), "no-op when already hovering")
            Check.ok(m.cursorMoved(inside: false), "hovering -> passive changes")
            Check.ok(m.state == .passive, "passive")
        }

        Check.run("drag arms and expands") {
            var m = HitStateMachine()
            Check.ok(m.dragBegan(), "arms")
            Check.ok(m.state == .dragArmed, "dragArmed")
            Check.ok(m.expanded, "expanded")
            Check.ok(!m.ignoresMouseEvents, "receives mouse while armed")
            Check.ok(!m.dragBegan(), "idempotent while dragging")
        }

        Check.run("drag wins over cursor moves") {
            var m = HitStateMachine()
            m.dragBegan()
            Check.ok(!m.cursorMoved(inside: false), "move ignored while armed")
            Check.ok(m.state == .dragArmed, "still armed")
            Check.ok(!m.cursorMoved(inside: true), "move ignored while armed")
            Check.ok(m.state == .dragArmed, "still armed")
        }

        Check.run("drop inside resolves to hovering") {
            var m = HitStateMachine()
            m.dragBegan()
            Check.ok(m.dragEnded(insideNow: true), "changes")
            Check.ok(m.state == .hovering, "hovering")
            Check.ok(!m.expanded, "collapsed")
        }

        Check.run("drop outside resolves to passive") {
            var m = HitStateMachine()
            m.dragBegan()
            Check.ok(m.dragEnded(insideNow: false), "changes")
            Check.ok(m.state == .passive, "passive")
            Check.ok(m.ignoresMouseEvents, "transparent again")
        }

        Check.run("full hover -> drag -> drop-out cycle") {
            var m = HitStateMachine()
            m.cursorMoved(inside: true)
            m.dragBegan()
            m.dragEnded(insideNow: false)
            Check.ok(m.state == .passive, "ends passive")
        }
    }
}
