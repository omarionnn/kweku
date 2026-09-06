import Foundation
import CoreGraphics
import KwekuKit

/// Pure logic behind the notch's new UI: scroll-to-switch, mode cycling, and
/// the agent panel's labels.
enum NotchUITests {
    static func all() {
        scrollCycler()
        modeCycle()
        panelLabels()
        rimPriority()
    }

    // MARK: Rim priority

    /// Which of the notch's simultaneous signals wins the outline.
    static func rimPriority() {
        func rim(attention: Bool = false, live: Bool = false, speaking: Bool = false,
                 level: CGFloat = 0, working: Bool = false,
                 activity: AgentActivity? = nil) -> NotchRimStyle {
            NotchRimStyle.resolve(attention: attention, live: live, speaking: speaking,
                                  voiceLevel: level, working: working, activity: activity)
        }

        Check.run("nothing happening leaves the rim undrawn") {
            Check.ok(rim() == .none, "no signal, no stroke")
        }
        Check.run("attention beats everything else") {
            Check.ok(rim(attention: true, live: true, speaking: true, working: true) == .attention,
                     "a session waiting on Omari is the one with a deadline")
        }
        Check.run("a speaking Kweku owns the rim over background work") {
            Check.ok(rim(live: true, speaking: true, level: 0.5,
                         working: true, activity: .tooling) == .live(level: 0.5),
                     "the rim is his mouth while a sentence is coming out")
        }
        Check.run("work shows through a silent live session") {
            // The regression this ordering exists for: dispatch a task by voice
            // and the tool comet was suppressed by the idle Live glow for the
            // whole run — the one moment the work was worth watching.
            Check.ok(rim(live: true, speaking: false, working: true, activity: .tooling)
                        == .working(activity: .tooling),
                     "silent live session yields to the running tool")
            Check.ok(rim(live: true, speaking: false, working: true, activity: .thinking)
                        == .working(activity: .thinking), "same for reasoning")
        }
        Check.run("an idle live session still glows when there is no work") {
            Check.ok(rim(live: true, level: 0.2) == .live(level: 0.2), "falls back to the live rim")
        }
        Check.run("working with no reported phase reads as thinking") {
            Check.ok(rim(working: true) == .working(activity: .thinking),
                     "the calmest thing to be wrong about")
        }
    }

    // MARK: Scroll cycler

    static func scrollCycler() {
        Check.run("one swipe flips exactly once") {
            var c = ScrollCycler(threshold: 28)
            var fired = 0
            // A trackpad swipe: many small deltas well past the threshold.
            for _ in 0..<12 {
                if c.feed(deltaX: -8, deltaY: 0) != 0 { fired += 1 }
            }
            Check.ok(fired == 1, "fired once, not once per delta (got \(fired))")
        }
        Check.run("gesture end re-arms for the next swipe") {
            var c = ScrollCycler(threshold: 28)
            for _ in 0..<12 { _ = c.feed(deltaX: -8, deltaY: 0) }
            c.end()
            var fired = 0
            for _ in 0..<12 where c.feed(deltaX: -8, deltaY: 0) != 0 { fired += 1 }
            Check.ok(fired == 1, "second swipe flips again")
        }
        Check.run("going quiet re-arms without an explicit end") {
            var c = ScrollCycler(threshold: 28)
            for _ in 0..<12 { _ = c.feed(deltaX: -8, deltaY: 0) }
            _ = c.feed(deltaX: 0, deltaY: 0)          // momentum died out
            var fired = 0
            for _ in 0..<12 where c.feed(deltaX: -8, deltaY: 0) != 0 { fired += 1 }
            Check.ok(fired == 1, "re-armed by quiet deltas")
        }
        Check.run("direction follows natural scrolling") {
            var right = ScrollCycler(threshold: 20)
            Check.ok(right.feed(deltaX: 30, deltaY: 0) == -1, "swipe right -> previous")
            var left = ScrollCycler(threshold: 20)
            Check.ok(left.feed(deltaX: -30, deltaY: 0) == 1, "swipe left -> next")
            var up = ScrollCycler(threshold: 20)
            Check.ok(up.feed(deltaX: 0, deltaY: 30) == -1, "scroll up -> previous")
            var down = ScrollCycler(threshold: 20)
            Check.ok(down.feed(deltaX: 0, deltaY: -30) == 1, "scroll down -> next")
        }
        Check.run("dominant axis wins on a diagonal") {
            var c = ScrollCycler(threshold: 20)
            Check.ok(c.feed(deltaX: -30, deltaY: 8) == 1, "mostly-horizontal reads as horizontal")
        }
        Check.run("sub-threshold travel never flips") {
            var c = ScrollCycler(threshold: 28)
            // Nudges that reverse direction must not accumulate into a flip.
            Check.ok(c.feed(deltaX: -10, deltaY: 0) == 0, "first nudge")
            Check.ok(c.feed(deltaX: 10, deltaY: 0) == 0, "reversal restarts, doesn't cancel")
            Check.ok(c.feed(deltaX: 10, deltaY: 0) == 0, "still short of threshold")
        }
    }

    // MARK: Mode cycling

    static func modeCycle() {
        Check.run("modes advance and wrap both ways") {
            Check.ok(NookMode.critter.advanced(by: 1) == .weather, "critter -> weather")
            Check.ok(NookMode.weather.advanced(by: 1) == .agents, "weather -> agents")
            Check.ok(NookMode.agents.advanced(by: 1) == .critter, "wraps forward")
            Check.ok(NookMode.critter.advanced(by: -1) == .agents, "wraps backward")
            Check.ok(NookMode.critter.advanced(by: 0) == .critter, "zero is identity")
        }
        Check.run("multi-step flips stay in range") {
            Check.ok(NookMode.critter.advanced(by: 7) == .weather, "7 forward")
            Check.ok(NookMode.critter.advanced(by: -7) == .agents, "7 backward")
        }
        Check.run("modes survive a round trip through UserDefaults") {
            for mode in NookMode.allCases {
                Check.ok(NookMode(rawValue: mode.rawValue) == mode, "\(mode.rawValue)")
            }
        }
    }

    // MARK: Agent panel labels

    static func panelLabels() {
        let t0 = Date(timeIntervalSince1970: 10_000)

        Check.run("elapsed label picks a sensible unit") {
            Check.ok(AgentPanelFormat.elapsed(since: t0, now: t0 + 5) == "5s", "seconds")
            Check.ok(AgentPanelFormat.elapsed(since: t0, now: t0 + 59) == "59s", "just under a minute")
            Check.ok(AgentPanelFormat.elapsed(since: t0, now: t0 + 60) == "1m", "minutes")
            Check.ok(AgentPanelFormat.elapsed(since: t0, now: t0 + 3600) == "1h", "hours")
            Check.ok(AgentPanelFormat.elapsed(since: t0, now: t0 - 5) == "0s", "clock skew clamps to zero")
        }
        Check.run("band summary counts and pluralises") {
            Check.ok(AgentPanelFormat.summary(total: 1, waiting: 0) == "1 agent", "singular")
            Check.ok(AgentPanelFormat.summary(total: 3, waiting: 0) == "3 agents", "plural")
            Check.ok(AgentPanelFormat.summary(total: 3, waiting: 1) == "3 agents · 1 waiting",
                     "calls out waiting")
        }
        Check.run("row label is the repo, with a fallback") {
            var table = AgentSessionTable()
            func session(id: String, cwd: String) -> AgentSession? {
                table.apply(AgentEvent(sessionID: id, cwd: cwd, pid: 1, state: .idle), at: t0)
                return table.sessions[id]
            }
            Check.ok(session(id: "a", cwd: "/Users/o/code/kweku")?.displayName == "kweku", "repo name")
            Check.ok(session(id: "openclaw", cwd: "")?.displayName == "OpenClaw", "synthetic session")
            Check.ok(session(id: "abcdef123456", cwd: "")?.displayName == "abcdef12",
                     "unknown falls back to a short id")
        }
        Check.run("panel order puts waiting first, then working, newest-first") {
            var table = AgentSessionTable()
            table.apply(AgentEvent(sessionID: "idle", cwd: "/i", pid: 1, state: .idle), at: t0 + 30)
            table.apply(AgentEvent(sessionID: "work1", cwd: "/w1", pid: 2, state: .working), at: t0)
            table.apply(AgentEvent(sessionID: "work2", cwd: "/w2", pid: 3, state: .working), at: t0 + 10)
            table.apply(AgentEvent(sessionID: "wait", cwd: "/n", pid: 4, state: .waiting), at: t0 - 100)

            let ids = table.ordered.map(\.id)
            Check.ok(ids == ["wait", "work2", "work1", "idle"], "got \(ids)")
            Check.ok(table.ordered.first?.id == table.focusTarget()?.id,
                     "the list's head is what a click focuses")
        }
        Check.run("panel height grows with the list, then caps") {
            let one = AgentPanelFormat.bodyHeight(for: 1)
            let four = AgentPanelFormat.bodyHeight(for: 4)
            let twenty = AgentPanelFormat.bodyHeight(for: 20)
            Check.ok(four > one, "taller with more sessions")
            // Past the cap it's the four rows plus one "+N more" line, forever.
            Check.ok(twenty == four + AgentPanelFormat.rowHeight, "caps at maxRows + overflow line")
            Check.ok(AgentPanelFormat.bodyHeight(for: 50) == twenty, "and stays there")
        }
    }
}
