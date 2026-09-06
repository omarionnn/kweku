import Foundation
import CoreGraphics
import KwekuKit

/// Pure logic behind the Live panel: the two state axes that used to be one
/// overloaded string, the activity the panel names, and its formatting.
enum LiveUITests {
    static func all() {
        phases()
        vision()
        activity()
        formatting()
        sizing()
    }

    // MARK: Phase

    static func phases() {
        Check.run("phase labels read as status, not as debug output") {
            Check.ok(LivePhase.idle.label == "", "idle says nothing")
            Check.ok(LivePhase.connecting.label == "connecting", "connecting")
            Check.ok(LivePhase.live.label == "live", "live")
            Check.ok(LivePhase.resuming(attempt: 2).label == "resuming (2)", "counts attempts")
            Check.ok(LivePhase.closed(reason: "timeout").label == "closed: timeout",
                     "carries the reason")
        }
        Check.run("only live is live") {
            Check.ok(LivePhase.live.isLive, "live")
            Check.ok(!LivePhase.connecting.isLive, "connecting is not yet")
            Check.ok(!LivePhase.resuming(attempt: 1).isLive, "resuming is not still")
        }
        Check.run("trouble is what the panel should call out") {
            Check.ok(!LivePhase.idle.isTrouble, "idle is fine")
            Check.ok(!LivePhase.connecting.isTrouble, "connecting is fine")
            Check.ok(!LivePhase.live.isTrouble, "live is fine")
            Check.ok(LivePhase.resuming(attempt: 1).isTrouble, "a dropped socket is trouble")
            Check.ok(LivePhase.closed(reason: "x").isTrouble, "closed is trouble")
            Check.ok(LivePhase.failed(reason: "no API key").isTrouble, "failed is trouble")
        }
        Check.run("resume attempts are distinct states") {
            Check.ok(LivePhase.resuming(attempt: 1) != LivePhase.resuming(attempt: 2),
                     "so the count actually redraws")
        }
    }

    // MARK: Vision

    static func vision() {
        Check.run("the eye line names the window") {
            let seeing = LiveVision.watching(app: "Safari", title: "Inbox", redacted: false)
            Check.ok(seeing.label == "Safari · Inbox", "app and title")
            let untitled = LiveVision.watching(app: "Terminal", title: "", redacted: false)
            Check.ok(untitled.label == "Terminal", "app alone when there's no title")
        }
        Check.run("a redacted window never leaks its title") {
            let hidden = LiveVision.watching(app: "1Password", title: "Personal vault",
                                             redacted: true)
            Check.ok(!hidden.label.contains("Personal vault"),
                     "the point of redaction is that the title doesn't show either")
            Check.ok(hidden.label == "1Password · hidden", "says it's held back")
            Check.ok(hidden.isRedacted, "and knows it")
        }
        Check.run("blind and redacted are different states") {
            let blind = LiveVision.unavailable(reason: "Screen Recording denied")
            Check.ok(blind.isBlind, "blind")
            Check.ok(!blind.isRedacted, "not the same as redacted")
            let shown = LiveVision.watching(app: "Xcode", title: "main.swift", redacted: false)
            Check.ok(!shown.isBlind && !shown.isRedacted, "plainly watching")
            Check.ok(!LiveVision.pending.isBlind, "not yet aimed is not blind")
        }
    }

    // MARK: Activity

    static func activity() {
        func resolve(_ phase: LivePhase, speaking: Bool = false, composing: Bool = false,
                     muted: Bool = false, gated: Bool = false) -> LiveActivity {
            LiveActivity.resolve(phase: phase, speaking: speaking, composing: composing,
                                 muted: muted, gated: gated)
        }

        Check.run("a session that isn't up says so, whatever the audio is doing") {
            Check.ok(resolve(.idle) == .ended, "idle")
            Check.ok(resolve(.closed(reason: "x"), speaking: true) == .ended,
                     "closed outranks stale audio state")
            Check.ok(resolve(.connecting) == .connecting, "connecting")
            Check.ok(resolve(.resuming(attempt: 1)) == .connecting,
                     "a resume reads as connecting, because that's what it is")
        }
        Check.run("mute outranks everything the session is doing") {
            Check.ok(resolve(.live, muted: true) == .muted, "muted")
            Check.ok(resolve(.live, speaking: true, muted: true) == .muted,
                     "still muted while Kweku talks — the mic is the user's question")
            Check.ok(resolve(.live, composing: true, muted: true) == .muted, "and while thinking")
        }
        Check.run("speaking, thinking and listening rank in that order") {
            Check.ok(resolve(.live, speaking: true) == .speaking, "speaking")
            Check.ok(resolve(.live, speaking: true, composing: true) == .speaking,
                     "audio out beats a stale composing flag")
            Check.ok(resolve(.live, composing: true) == .thinking, "thinking")
            Check.ok(resolve(.live) == .listening, "listening")
        }
        Check.run("the half-duplex gate is named, not hidden") {
            // The gate outlives the audio by an echo tail. Without this state
            // that beat looks exactly like a microphone that stopped working.
            Check.ok(resolve(.live, gated: true) == .held, "held")
            Check.ok(resolve(.live, speaking: true, gated: true) == .speaking,
                     "while Kweku is actually talking, that's the better word")
        }
        Check.run("every activity has a label") {
            let all: [LiveActivity] = [.connecting, .listening, .thinking, .speaking,
                                       .muted, .held, .ended]
            Check.ok(all.allSatisfy { !$0.label.isEmpty }, "no blanks")
        }
    }

    // MARK: Formatting

    static func formatting() {
        Check.run("the session clock counts up sensibly") {
            Check.ok(LiveFormat.duration(0) == "0:00", "start")
            Check.ok(LiveFormat.duration(7) == "0:07", "pads seconds")
            Check.ok(LiveFormat.duration(271) == "4:31", "minutes")
            Check.ok(LiveFormat.duration(3729) == "1:02:09", "grows an hours field")
            Check.ok(LiveFormat.duration(-5) == "0:00", "clock skew clamps")
        }
        Check.run("titles are trimmed on the tail, keeping the identifying head") {
            Check.ok(LiveFormat.title("Inbox", limit: 10) == "Inbox", "short titles pass through")
            let long = LiveFormat.title("A very long window title indeed", limit: 10)
            Check.ok(long.count == 10, "cut to the limit, got \(long.count)")
            Check.ok(long.hasPrefix("A very "), "keeps the head")
            Check.ok(long.hasSuffix("…"), "and says it was cut")
            Check.ok(LiveFormat.title("  padded  ", limit: 20) == "padded", "trims whitespace")
        }
    }

    // MARK: Sizing

    static func sizing() {
        let base = CGSize(width: 200, height: 32)

        Check.run("the live panel sizes through the same arithmetic as a mode") {
            // Metrics taken from a mode, since the component itself is internal
            // — what's being checked is that the metrics-based overload agrees
            // with the mode-based one it now backs.
            let metrics = NookMode.stats.metrics(NookContext())
            let viaMode = NookLayout.size(base: base, mode: .stats, open: true,
                                          context: NookContext(), strips: [])
            let viaMetrics = NookLayout.size(base: base, metrics: metrics, open: true, strips: [])
            Check.eq(viaMetrics.width, viaMode.width, "same width")
            Check.eq(viaMetrics.height, viaMode.height, "same height")
        }
        Check.run("a takeover component still stacks its strips") {
            let metrics = NookMetrics(peek: 32, expandedBody: 116, expandedWidth: 380)
            let strips = [NookLayout.Strip(height: 40, minWidth: 340)]
            let open = NookLayout.size(base: base, metrics: metrics, open: true, strips: strips)
            Check.eq(open.width, 380, "the panel is wider than the strip")
            Check.eq(open.height, base.height + 116 + 40, "body plus strip")

            let closed = NookLayout.size(base: base, metrics: metrics, open: false, strips: strips)
            Check.eq(closed.width, 340, "closed, the strip sets the width")
            Check.eq(closed.height, base.height + 32 + 40, "peek plus strip")
        }
    }
}
