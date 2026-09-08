import Foundation
import KwekuKit

/// The tab — the amber tongue a retracting drop leaves behind when something
/// is still owed. The arithmetic here is small; what it is really protecting
/// is that the tab stays *countable* and stays *narrow*.
enum NotchTabTests {
    static func all() {
        counting()
        width()
    }

    static func counting() {
        Check.run("one pip per stuck session") {
            Check.ok(NotchTab.pips(sessions: 0) == 0, "nothing owed, no tab")
            Check.ok(NotchTab.pips(sessions: 1) == 1, "one")
            Check.ok(NotchTab.pips(sessions: 3) == 3, "three")
        }
        Check.run("it stops counting before the pips stop being countable") {
            Check.ok(NotchTab.pips(sessions: 9) == NotchTab.maxPips,
                     "nine reads the same as four — the rim is the list, not this")
            Check.ok(NotchTab.maxPips <= 4, "four is already the edge of a glance")
        }
        Check.run("a negative count is not a tab") {
            Check.ok(NotchTab.pips(sessions: -2) == 0, "clamped rather than crashing a ForEach")
        }
    }

    static func width() {
        Check.run("nothing owed has no width at all") {
            Check.eq(Double(NotchTab.width(sessions: 0)), 0, "no tongue")
        }
        Check.run("width carries the count") {
            let one = NotchTab.width(sessions: 1)
            let two = NotchTab.width(sessions: 2)
            let four = NotchTab.width(sessions: 4)
            Check.ok(two > one, "a second stuck agent is a wider tab")
            Check.ok(four > two, "and a fourth wider still")
            Check.eq(Double(NotchTab.width(sessions: 12)), Double(four),
                     "past the cap it stops growing")
        }
        Check.run("it stays a bookmark, not a second notch") {
            // The physical cutout is ~180pt. A tab approaching that width has
            // stopped hanging off the notch and started being one.
            Check.ok(NotchTab.width(sessions: NotchTab.maxPips) < 90,
                     "four pips still hang off the middle of the bottom edge")
            Check.ok(NotchTab.bodyHeight <= 12,
                     "it claims almost no height — you glance at it, you don't read it")
        }
    }
}
