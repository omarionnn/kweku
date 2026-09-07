import Foundation
import KwekuKit

/// Pure logic behind the notch command line: the state machine the panel reads,
/// the recall ring, and the instruction handed to a coding agent.
enum CommandTests {
    static func all() {
        states()
        targets()
        history()
        instructions()
        condensing()
        ghosting()
        recalling()
        growth()
        chipping()
        escalations()
    }

    // MARK: State

    static func states() {
        Check.run("busy is exactly the states with work in flight") {
            Check.ok(!CommandState.idle.isBusy, "idle")
            Check.ok(CommandState.reading.isBusy, "reading the screen")
            Check.ok(CommandState.running(phase: "x").isBusy, "running")
            Check.ok(!CommandState.result(text: "done", ok: true).isBusy, "finished")
            Check.ok(!CommandState.result(text: "nope", ok: false).isBusy, "failed is finished")
        }
        Check.run("progress copy exists exactly while busy") {
            Check.ok(CommandState.idle.progressLabel == nil, "idle says nothing")
            Check.ok(CommandState.result(text: "x", ok: true).progressLabel == nil,
                     "a result is not progress")
            Check.ok(CommandState.reading.progressLabel == "reading the screen…", "reading")
            Check.ok(CommandState.running(phase: "cloning").progressLabel == "cloning",
                     "the gateway's own phase")
            // A gateway that sends an empty status must not blank the line.
            Check.ok(CommandState.running(phase: "").progressLabel == "working…",
                     "empty phase falls back")
        }
    }

    // MARK: Target

    static func targets() {
        Check.run("the panel can always name where work went") {
            Check.ok(CommandTarget.openClaw.label == "OpenClaw", "gateway")
            Check.ok(CommandTarget.agent(cwd: "/Users/o/code/kweku").label == "kweku",
                     "agent target reads as the repo")
            Check.ok(CommandTarget.agent(cwd: nil).label == "agent", "no cwd known")
            Check.ok(CommandTarget.agent(cwd: "").label == "agent", "empty cwd is no cwd")
        }
    }

    // MARK: History

    static func history() {
        Check.run("recall keeps newest first") {
            var h: [String] = []
            h = CommandFormat.remember("one", in: h)
            h = CommandFormat.remember("two", in: h)
            Check.ok(h == ["two", "one"], "newest first, got \(h)")
        }
        Check.run("re-running the same thing doesn't fill the list with it") {
            // The common case for a notch command is running it again after it
            // failed; eight copies of one line would recall nothing.
            var h = ["build", "test"]
            h = CommandFormat.remember("test", in: h)
            Check.ok(h == ["test", "build"], "moves to the front instead, got \(h)")
        }
        Check.run("recall is bounded and ignores blanks") {
            var h: [String] = []
            for i in 0..<20 { h = CommandFormat.remember("cmd \(i)", in: h) }
            Check.ok(h.count == CommandFormat.maxHistory, "capped at \(CommandFormat.maxHistory)")
            Check.ok(h.first == "cmd 19", "newest survives")
            let before = h
            h = CommandFormat.remember("   ", in: h)
            Check.ok(h == before, "whitespace isn't a command")
        }
    }

    // MARK: Instruction

    static func instructions() {
        Check.run("the fix instruction carries the error and names its source") {
            let text = CommandFormat.fixInstruction(
                error: "AssertionError: expected 3, got 4", app: "Terminal")
            Check.ok(text.contains("AssertionError: expected 3, got 4"), "the failure itself")
            Check.ok(text.contains("Terminal"), "where it was seen")
            // The agent must know the text is a screenshot reading, not truth.
            Check.ok(text.lowercased().contains("ocr")
                     || text.lowercased().contains("screenshot"),
                     "warns the transcription may be wrong")
            Check.ok(text.lowercased().contains("say so"),
                     "tells it to stop rather than invent a fix")
        }
        Check.run("a nameless app still reads as a sentence") {
            let text = CommandFormat.fixInstruction(error: "boom", app: "")
            Check.ok(text.contains("the foreground app"), "falls back, got: \(text.prefix(80))")
        }
    }

    // MARK: Condensing

    static func condensing() {
        Check.run("output is trimmed from the front, keeping the tail") {
            let long = String(repeating: "a", count: 5000) + "THE ANSWER"
            let short = CommandFormat.condense(long, limit: 100)
            Check.ok(short.count == 100, "cut to the limit, got \(short.count)")
            Check.ok(short.hasSuffix("THE ANSWER"), "an answer lives at the end of the output")
            Check.ok(short.hasPrefix("…"), "and says it was cut")
        }
        Check.run("short output passes through untouched") {
            Check.ok(CommandFormat.condense("done") == "done", "unchanged")
            Check.ok(CommandFormat.condense("  done  ") == "done", "trimmed")
        }
        Check.run("silence gets a word rather than an empty panel") {
            Check.ok(CommandFormat.condense("") == "(no output)", "empty")
            Check.ok(CommandFormat.condense("   \n ") == "(no output)", "whitespace only")
        }
    }

    // MARK: Ghost completion

    static let ring = ["fix the failing test", "fix the build", "open the PR"]

    static func ghosting() {
        Check.run("the ghost is the rest of the newest matching command") {
            Check.ok(CommandFormat.ghost(for: "fix the f", in: ring) == "ailing test",
                     "got \(CommandFormat.ghost(for: "fix the f", in: ring))")
            Check.ok(CommandFormat.ghost(for: "open", in: ring) == " the PR", "later entries match too")
        }
        Check.run("matching ignores case but the suffix comes from history") {
            // Accepting the ghost should leave you with the command that ran
            // before, not a half-cased hybrid of it.
            Check.ok(CommandFormat.ghost(for: "FIX THE B", in: ring) == "uild",
                     "got \(CommandFormat.ghost(for: "FIX THE B", in: ring))")
        }
        Check.run("nothing to offer stays silent") {
            Check.ok(CommandFormat.ghost(for: "", in: ring).isEmpty, "empty draft")
            Check.ok(CommandFormat.ghost(for: "deploy", in: ring).isEmpty, "no match")
            Check.ok(CommandFormat.ghost(for: "fix the build", in: ring).isEmpty,
                     "an exact match has no remainder to show")
            Check.ok(CommandFormat.ghost(for: "fix", in: []).isEmpty, "no history")
        }
        Check.run("a pasted trace predicts nothing") {
            Check.ok(CommandFormat.ghost(for: "fix the\nbuild", in: ring).isEmpty,
                     "multi-line drafts are not one-line commands")
        }
    }

    // MARK: Recall

    static func recalling() {
        Check.run("↑ walks back and stops at the oldest") {
            var i = CommandFormat.draftIndex
            i = CommandFormat.recallIndex(from: i, by: 1, count: 3); Check.ok(i == 0, "first ↑")
            i = CommandFormat.recallIndex(from: i, by: 1, count: 3); Check.ok(i == 1, "second ↑")
            i = CommandFormat.recallIndex(from: i, by: 1, count: 3); Check.ok(i == 2, "third ↑")
            i = CommandFormat.recallIndex(from: i, by: 1, count: 3)
            Check.ok(i == 2, "stops rather than wrapping to the newest, got \(i)")
        }
        Check.run("↓ walks forward and hands the draft back") {
            var i = 1
            i = CommandFormat.recallIndex(from: i, by: -1, count: 3); Check.ok(i == 0, "one back")
            i = CommandFormat.recallIndex(from: i, by: -1, count: 3)
            Check.ok(i == CommandFormat.draftIndex, "past the newest is the draft")
            i = CommandFormat.recallIndex(from: i, by: -1, count: 3)
            Check.ok(i == CommandFormat.draftIndex, "and stays there, got \(i)")
        }
        Check.run("an empty ring never leaves the draft") {
            Check.ok(CommandFormat.recallIndex(from: -1, by: 1, count: 0) == CommandFormat.draftIndex,
                     "nothing to recall")
        }
        Check.run("the draft index reads as no entry") {
            Check.ok(CommandFormat.recall(ring, at: CommandFormat.draftIndex) == nil, "draft")
            Check.ok(CommandFormat.recall(ring, at: 1) == "fix the build", "an entry")
            Check.ok(CommandFormat.recall(ring, at: 9) == nil, "off the end")
        }
    }

    // MARK: Editor growth

    static func growth() {
        Check.run("the editor grows by lines and then stops") {
            let line = CommandFormat.editorLineHeight
            Check.ok(CommandFormat.editorHeight(measured: 4) == line, "never thinner than a line")
            Check.ok(CommandFormat.editorHeight(measured: line * 3) == line * 3, "three lines")
            let ceiling = line * CGFloat(CommandFormat.editorMaxLines)
            Check.ok(CommandFormat.editorHeight(measured: line * 400) == ceiling,
                     "a pasted log must not turn the notch into a window")
        }
        Check.run("line count is clamped the same way") {
            let line = CommandFormat.editorLineHeight
            Check.ok(CommandFormat.editorLines(measured: 0) == 1, "always at least one")
            Check.ok(CommandFormat.editorLines(measured: line * 2) == 2, "two")
            Check.ok(CommandFormat.editorLines(measured: line * 99) == CommandFormat.editorMaxLines,
                     "capped")
        }
    }

    // MARK: Chips

    static func chipping() {
        Check.run("the row reads: looking at, carrying, going to") {
            let chips = CommandFormat.chips(contextApp: "Xcode", withScreen: false,
                                            target: .openClaw)
            Check.ok(chips.map(\.kind) == [.context, .screen, .route],
                     "fixed order, got \(chips.map(\.kind))")
            Check.ok(chips[0].label == "Xcode", "names the app it will read")
            Check.ok(chips[2].label == "OpenClaw", "names where ⏎ goes")
        }
        Check.run("no known app means no chip claiming one") {
            Check.ok(!CommandFormat.chips(contextApp: nil, withScreen: false, target: .openClaw)
                        .contains { $0.kind == .context }, "nil")
            Check.ok(!CommandFormat.chips(contextApp: "   ", withScreen: false, target: .openClaw)
                        .contains { $0.kind == .context }, "blank")
        }
        Check.run("the screen chip is the only one you can press") {
            let chips = CommandFormat.chips(contextApp: "Safari", withScreen: true,
                                            target: .agent(cwd: "/Users/o/notch"))
            let screen = chips.first { $0.kind == .screen }
            Check.ok(screen?.on == true, "lit while attached")
            Check.ok(screen?.actionable == true, "and pressable")
            Check.ok(chips.filter(\.actionable).count == 1, "the others only state facts")
            Check.ok(chips.last?.label == "notch", "route names the repo for an agent target")
        }
    }

    // MARK: Escalation

    static func escalations() {
        Check.run("escalation carries the answer, not just the question") {
            let text = CommandFormat.escalation(prompt: "why is the build red",
                                                result: "missing symbol _foo")
            Check.ok(text.contains("why is the build red"), "the original ask")
            Check.ok(text.contains("missing symbol _foo"), "what came back")
            Check.ok(text.lowercased().contains("openclaw"), "says who tried first")
        }
        Check.run("nothing came back, so there is nothing to quote") {
            Check.ok(CommandFormat.escalation(prompt: "ship it", result: "") == "ship it", "bare")
            Check.ok(CommandFormat.escalation(prompt: "ship it", result: "  \n ") == "ship it",
                     "whitespace is nothing")
        }
    }
}
