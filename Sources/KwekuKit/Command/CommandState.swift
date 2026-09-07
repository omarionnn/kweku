import Foundation

/// Where a notch command is in its life. Pure, so the state machine that
/// decides what the panel shows is testable without a gateway.
public enum CommandState: Equatable, Sendable {
    case idle
    /// Reading the screen before dispatching (the vision pass).
    case reading
    /// Handed off and in flight. `phase` is the gateway's own status line.
    case running(phase: String)
    /// Finished. `ok` false means it failed or was refused.
    case result(text: String, ok: Bool)

    public var isBusy: Bool {
        switch self {
        case .reading, .running: return true
        case .idle, .result:     return false
        }
    }

    /// What the panel says while there's nothing to read yet.
    public var progressLabel: String? {
        switch self {
        case .reading:            return "reading the screen…"
        case .running(let phase): return phase.isEmpty ? "working…" : phase
        case .idle, .result:      return nil
        }
    }
}

/// Which engine a command goes to.
///
/// Two very different things wear the same text box. `ask` goes to OpenClaw,
/// which can reach the whole machine; `fix` goes to a coding agent in a repo.
/// Keeping them as separate destinations rather than one "smart" router means
/// the panel can always say where the work went before it goes there.
public enum CommandTarget: Equatable, Sendable {
    /// The OpenClaw gateway — browser, files, shell, messaging, automations.
    case openClaw
    /// A coding agent, headless, in this working directory.
    case agent(cwd: String?)

    public var label: String {
        switch self {
        case .openClaw:            return "OpenClaw"
        case .agent(let cwd):
            guard let cwd, !cwd.isEmpty else { return "agent" }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
    }
}

/// Pure helpers for the command panel.
public enum CommandFormat {
    /// Longest prompt worth keeping in the recall ring.
    public static let maxHistory = 8

    /// Add a prompt to the recent list: newest first, no duplicates, bounded.
    ///
    /// De-duplicating matters more here than in a shell history — the common
    /// case for a notch command is running the *same* thing again after it
    /// failed, and a list of eight identical lines recalls nothing.
    public static func remember(_ prompt: String, in history: [String]) -> [String] {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return history }
        var next = history.filter { $0 != clean }
        next.insert(clean, at: 0)
        if next.count > maxHistory { next.removeLast(next.count - maxHistory) }
        return next
    }

    /// The instruction handed to a coding agent for a failure read off screen.
    ///
    /// States where the text came from. An agent told "fix this error" with a
    /// transcription it can't verify should know the transcription is a
    /// screenshot reading and not gospel — the file on disk wins.
    public static func fixInstruction(error: String, app: String) -> String {
        """
        This failure is currently on screen in \(app.isEmpty ? "the foreground app" : app), \
        read from a screenshot:

        \(error)

        Find the cause in this repository and fix it. The transcription above may \
        have OCR errors — trust the actual files and command output over it. If the \
        failure isn't reproducible here, say so instead of changing anything.
        """
    }

    /// Trim gateway/agent output to something a notch panel can hold. Keeps the
    /// tail, which is where a command's answer and its errors both live.
    public static func condense(_ text: String, limit: Int = 600) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "(no output)" }
        guard clean.count > limit else { return clean }
        return "…" + String(clean.suffix(limit - 1))
    }
}
