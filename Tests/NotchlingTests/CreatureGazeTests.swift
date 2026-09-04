import CoreGraphics
import NotchlingKit

enum CreatureGazeTests {
    static func all() {
        let center = CGPoint(x: 100, y: 100)

        Check.run("centred cursor => no gaze") {
            let g = CreatureState.gazeVector(cursor: center, center: center)
            Check.eq(g.width, 0, "no x")
            Check.eq(g.height, 0, "no y")
        }

        Check.run("cursor to the right => pupils right") {
            let g = CreatureState.gazeVector(cursor: CGPoint(x: 300, y: 100), center: center)
            Check.eq(g.width, 1, "saturated right (200px = reach)")
            Check.eq(g.height, 0, "no vertical")
        }

        Check.run("cursor above => pupils up (y flipped)") {
            // Global y-up: cursor above center has larger y. View y-down => negative.
            let g = CreatureState.gazeVector(cursor: CGPoint(x: 100, y: 300), center: center)
            Check.eq(g.height, -1, "up is negative in view space")
        }
        Check.run("cursor below => pupils down") {
            let g = CreatureState.gazeVector(cursor: CGPoint(x: 100, y: 0), center: center, reach: 200)
            Check.eq(g.height, 0.5, "100px below / 200 reach")
        }
        Check.run("partial deflection is linear") {
            let g = CreatureState.gazeVector(cursor: CGPoint(x: 200, y: 100), center: center, reach: 200)
            Check.eq(g.width, 0.5, "100px right / 200 reach")
        }

        Check.run("both axes clamp to unit square") {
            let g = CreatureState.gazeVector(cursor: CGPoint(x: 9999, y: -9999), center: center)
            Check.eq(g.width, 1, "clamped x")
            Check.eq(g.height, 1, "clamped y (far below => +1)")
        }
    }
}
