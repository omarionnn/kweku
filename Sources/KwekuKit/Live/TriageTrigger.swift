import Foundation

/// Decides when the screen looks broken enough for Kweku to speak first.
///
/// Kweku already sees the screen and can already dispatch a fix, but only ever
/// after being asked — which means the moment that most deserves help, staring
/// at a stack trace, is the moment nothing happens. This closes that gap.
///
/// The hard part is not detection, it's silence. An assistant that comments on
/// every red thing on screen is worse than one that says nothing, so the bar
/// is: a window title that genuinely reads like a failure, never the same
/// failure twice, and a long cooldown between interruptions. The title is only
/// the *trigger* — the model then looks at the actual frame and stays quiet if
/// there's nothing really wrong.
public enum TriageTrigger {

    /// Title fragments that read like something broke. Deliberately narrow:
    /// bare "error" appears in documentation, settings panes and this very
    /// file, so the phrases carry their own context.
    public static let failureFragments = [
        "build failed", "build error", "tests failed", "test failure",
        "compilation failed", "compile error", "fatal error", "fatal:",
        "traceback", "stack trace", "unhandled exception", "segmentation fault",
        "panic:", "exit code 1", "exit status 1", "command not found",
        "cannot find module", "module not found", "permission denied",
        "connection refused", "merge conflict", "✗", "failing",
    ]

    /// Titles that look like failures but are somebody reading about one.
    /// Without this, opening the docs for an error triggers help with the docs.
    public static let innocentFragments = [
        "stack overflow", "github", "issue #", "pull request", "documentation",
        "docs", "tutorial", "how to", "search", "google", "chatgpt", "claude",
    ]

    public struct State: Equatable {
        var lastFiredAt = Date.distantPast
        var lastSignature = ""

        public init() {}
    }

    /// Minimum gap between two unsolicited interruptions.
    public static let cooldown: TimeInterval = 240

    /// Whether to speak about this window, and the updated state.
    ///
    /// `speaking` and `composing` are respected because barging in mid-turn
    /// would cut Kweku off in the middle of its own sentence.
    public static func evaluate(app: String,
                                title: String,
                                state: State,
                                now: Date,
                                sessionLive: Bool,
                                busy: Bool,
                                cooldown: TimeInterval = cooldown) -> (fire: Bool, state: State) {
        guard sessionLive, !busy else { return (false, state) }
        let haystack = "\(app) \(title)".lowercased()
        guard failureFragments.contains(where: haystack.contains) else { return (false, state) }
        guard !innocentFragments.contains(where: haystack.contains) else { return (false, state) }

        // Same broken thing as last time: they know, they were there.
        let signature = haystack
        guard signature != state.lastSignature else { return (false, state) }
        guard now.timeIntervalSince(state.lastFiredAt) >= cooldown else { return (false, state) }

        var next = state
        next.lastFiredAt = now
        next.lastSignature = signature
        return (true, next)
    }

    /// The instruction sent into the Live conversation once a failure has
    /// actually been *read* off the screen by `ScreenGlance`.
    ///
    /// It carries the quoted error rather than asking the model to look,
    /// because on an unprompted notice it cannot: a `clientContent` turn does
    /// not see the video stream. Two measurements shaped this. Told the window
    /// title and asked to check the frame, the model invented a linker error
    /// over a screenshot of Spotify. Told nothing and asked to look, it
    /// reported receiving no frame at all — correctly, which is the whole
    /// problem. So the reading happens elsewhere and only the quote arrives.
    public static func prompt(app: String, evidence: String) -> String {
        "System notice, not from Omari — he did not say anything. Something on his "
            + "screen in \(app) has failed. This was read directly off it:\n\n"
            + "\(evidence)\n\n"
            + "Tell him in one short spoken sentence what broke, using only what is "
            + "quoted above, and offer one specific command you could run to fix it. "
            + "Do not invent details that are not in the quote."
    }
}
