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
}
