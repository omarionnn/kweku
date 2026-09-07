import Foundation
import KwekuKit

/// The notch speaking on its own: what it queues, when it's allowed to, and
/// how the rim divides itself between several sessions.
enum DropTests {
    static func all() {
        dwell()
        lines()
        queueing()
        gating()
        headlines()
        segments()
        rimPriority()
    }

    private static func drop(_ id: String, detail: String = "x") -> NotchDrop {
        NotchDrop(id: id, symbol: "circle", title: id, detail: detail, tint: .neutral)
    }

    // MARK: Dwell

    static func dwell() {
        Check.run("a line hangs there for about as long as it takes to read") {
            let short = NotchDrop.dwell(for: "done")
            let long = NotchDrop.dwell(for: String(repeating: "a", count: 60))
            Check.ok(long > short, "more to read, longer on screen")
        }
        Check.run("nothing flashes and nothing overstays") {
            Check.ok(NotchDrop.dwell(for: "") >= 2.4, "a two-word line is still readable")
            Check.ok(NotchDrop.dwell(for: String(repeating: "a", count: 4000)) <= 5.5,
                     "a long one is still a glance, not a takeover")
        }
    }

    // MARK: First line

    static func lines() {
        Check.run("the headline of a block of output is its first real line") {
            Check.ok(NotchDrop.firstLine("\n\n  built ok  \nand more") == "built ok",
                     "leading blanks skipped and trimmed")
            Check.ok(NotchDrop.firstLine("") == "", "nothing is nothing")
        }
        Check.run("and it says when it cut") {
            let long = String(repeating: "x", count: 200)
            let cut = NotchDrop.firstLine(long, limit: 20)
            Check.ok(cut.count == 20, "cut to the limit, got \(cut.count)")
            Check.ok(cut.hasSuffix("…"), "and shows it")
        }
    }

    // MARK: Queue

    static func queueing() {
        Check.run("one session speaking twice is one thing to say") {
            var q = DropQueue()
            q.enqueue(drop("a", detail: "first"))
            q.enqueue(drop("a", detail: "second"))
            Check.ok(q.pending.count == 1, "replaced, not queued twice")
            Check.ok(q.pending.first?.detail == "second", "and it's the newer one")
        }
        Check.run("the queue is bounded, and says how many it dropped") {
            var q = DropQueue()
            for i in 0..<6 { q.enqueue(drop("s\(i)")) }
            Check.ok(q.pending.count == DropQueue.maxPending, "capped")
            Check.ok(q.missed == 6 - DropQueue.maxPending, "the rest are counted")
            Check.ok(q.pending.first?.id == "s3", "the newest are the ones kept")
        }
        Check.run("the count is said last, after the ones that got their turn") {
            var q = DropQueue()
            for i in 0..<5 { q.enqueue(drop("s\(i)")) }
            var said: [String] = []
            while let next = q.take() { said.append(next.title) }
            Check.ok(said.count == DropQueue.maxPending + 1, "three lines and a tally")
            Check.ok(said.last == "+2 more", "the tally comes last, got \(said.last ?? "nil")")
            Check.ok(q.isEmpty, "and then there is nothing left")
        }
        Check.run("an empty queue says nothing at all") {
            var q = DropQueue()
            Check.ok(q.isEmpty, "empty")
            Check.ok(q.take() == nil, "and has nothing to take")
        }
        Check.run("opening the notch answers everything at once") {
            var q = DropQueue()
            for i in 0..<5 { q.enqueue(drop("s\(i)")) }
            q.clear()
            Check.ok(q.isEmpty, "cleared, including the overflow count")
            Check.ok(q.take() == nil, "nothing to say to someone already looking")
        }
    }

    // MARK: Gate

    static func gating() {
        Check.run("silence by default is wrong — an idle notch may speak") {
            Check.ok(DropGate().allows, "nothing in the way")
        }
        Check.run("every reason to stay quiet is a reason you're already there") {
            Check.ok(!DropGate(hidden: true).allows, "hidden")
            Check.ok(!DropGate(hovering: true).allows, "you're looking at it")
            Check.ok(!DropGate(typing: true).allows, "nothing moves under a caret")
            Check.ok(!DropGate(live: true).allows, "it'll say it out loud instead")
            Check.ok(!DropGate(dragging: true).allows, "mid-drop-target")
            Check.ok(!DropGate(muted: true).allows, "you asked for quiet")
        }
    }

    // MARK: Headline

    static func headlines() {
        Check.run("the glance version is counts, never a verdict") {
            let work = AgentReport.Work(files: 3, insertions: 40, deletions: 2,
                                        commits: ["fix the thing"])
            let line = AgentReport.headline(work)
            Check.ok(line.contains("1 commit"), "commits")
            Check.ok(line.contains("3 files"), "files")
            Check.ok(line.contains("+40"), "insertions")
            Check.ok(!line.lowercased().contains("success"), "a diff is not a verdict")
        }
        Check.run("nothing to show says so rather than inventing something") {
            Check.ok(AgentReport.headline(nil) == "waiting on you", "not a repo")
            Check.ok(AgentReport.headline(AgentReport.Work()) == "waiting on you", "nothing changed")
        }
    }

    // MARK: Rim segments

    static func segments() {
        Check.run("the outline divides evenly, with a gap between neighbours") {
            let arcs = RimSegments.arcs(count: 3)
            Check.ok(arcs.count == 3, "one each")
            let span = arcs[1].start - arcs[0].start
            Check.eq(Double(span), 1.0 / 3.0, "evenly spaced")
            Check.ok(arcs[0].length < span, "and separated, or it reads as one ring")
        }
        Check.run("one session takes the whole outline") {
            let arcs = RimSegments.arcs(count: 1)
            Check.ok(arcs.count == 1, "one")
            Check.ok(arcs[0].length > 0.9, "nearly all of it, got \(arcs[0].length)")
        }
        Check.run("past a handful the rim stops trying to be a list") {
            Check.ok(RimSegments.arcs(count: 20).count == RimSegments.maxArcs, "capped")
            Check.ok(RimSegments.arcs(count: 0).isEmpty, "and nothing for nothing")
        }
        Check.run("arcs never collapse to invisible") {
            for count in 1...RimSegments.maxArcs {
                Check.ok(RimSegments.arcs(count: count).allSatisfy { $0.length > 0 },
                         "\(count) sessions")
            }
        }
    }

    // MARK: Rim priority

    static func rimPriority() {
        let two = [RimSegment(id: "a", state: .waiting),
                   RimSegment(id: "b", state: .working(.tooling))]

        Check.run("several sessions outrank the attention pulse") {
            // The pulse says "something needs you" and blanks everything else.
            // The segmented rim says that *and* what the others are doing.
            let style = NotchRimStyle.resolve(attention: true, live: false, voiceLevel: 0,
                                              working: true, activity: .tooling,
                                              segments: two)
            Check.ok(style == .sessions(two), "got \(style)")
        }
        Check.run("one session still gets the pulse, which is the better signal") {
            let one = [RimSegment(id: "a", state: .waiting)]
            let style = NotchRimStyle.resolve(attention: true, live: false, voiceLevel: 0,
                                              working: false, segments: one)
            Check.ok(style == .attention, "got \(style)")
        }
        Check.run("nothing running is still nothing to say") {
            let style = NotchRimStyle.resolve(attention: false, live: false, voiceLevel: 0,
                                              working: false, segments: [])
            Check.ok(style == .none, "got \(style)")
        }
    }
}
