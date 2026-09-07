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

    /// The instruction that carries a finished command over to a coding agent.
    ///
    /// Escalation is not a re-run: the gateway already had a go, and what makes
    /// the second attempt worth anything is that the agent is told what the
    /// first one came back with.
    public static func escalation(prompt: String, result: String) -> String {
        let tail = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return prompt }
        return """
        \(prompt)

        I already asked OpenClaw this and it came back with:

        \(tail)

        Pick it up from here in this repository.
        """
    }

    // MARK: - Recall

    /// Index meaning "not recalling — the draft is the user's own text".
    public static let draftIndex = -1

    /// Step through the recall ring. `delta` is +1 for older (↑) and -1 for
    /// newer (↓); the walk stops at the oldest entry and at the live draft
    /// rather than wrapping, because a ring that wraps silently hands you the
    /// oldest command when you meant to get back to what you were typing.
    public static func recallIndex(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return draftIndex }
        return min(max(index + delta, draftIndex), count - 1)
    }

    /// The prompt at a recall index, or nil for the draft.
    public static func recall(_ history: [String], at index: Int) -> String? {
        guard index >= 0, index < history.count else { return nil }
        return history[index]
    }

    // MARK: - Ghost completion

    /// The dim remainder shown after the caret: the rest of the most recent
    /// command that starts with what's typed so far.
    ///
    /// Case-insensitive on the match but the *suffix comes from history*, so
    /// accepting it fixes your casing to whatever ran before. Returns empty for
    /// a multi-line draft — a pasted stack trace has no business predicting a
    /// one-line command.
    public static func ghost(for input: String, in history: [String]) -> String {
        guard !input.isEmpty, !input.contains("\n") else { return "" }
        let lower = input.lowercased()
        guard let match = history.first(where: {
            $0.count > input.count && $0.lowercased().hasPrefix(lower)
        }) else { return "" }
        return String(match.dropFirst(input.count))
    }

    // MARK: - Editor sizing

    /// One line of the command editor, in points.
    public static let editorLineHeight: CGFloat = 15
    /// Lines the editor will grow to before it starts scrolling. Four is what
    /// fits under the notch without the panel becoming a window.
    public static let editorMaxLines = 4

    /// Height the editor should be for text that lays out to `measured` points.
    ///
    /// Clamped rather than free-growing: paste a thousand-line log and the
    /// notch must still be a notch.
    public static func editorHeight(measured: CGFloat) -> CGFloat {
        let ceiling = editorLineHeight * CGFloat(editorMaxLines)
        return min(max(measured, editorLineHeight), ceiling)
    }

    /// Lines the panel should budget for, from the same measurement.
    public static func editorLines(measured: CGFloat) -> Int {
        let raw = Int((measured / editorLineHeight).rounded())
        return min(max(raw, 1), editorMaxLines)
    }
}

/// One fact about the command you're about to send, shown above the field.
///
/// Chips exist because every one of these was already true and invisible: the
/// hub captured the frontmost app and never said so, the screen toggle was an
/// unlabelled icon, and where ⏎ went was only ever stated after the fact. A
/// command that reads the wrong window or goes to the wrong engine is worth
/// catching *before* it runs.
public struct CommandChip: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// The app that was frontmost when the field took focus.
        case context
        /// Whether the screen rides along with the prompt. The only toggle.
        case screen
        /// Where ⏎ sends this.
        case route
    }

    public var kind: Kind
    public var symbol: String
    public var label: String
    /// Lit — a toggle that's on. Informational chips stay unlit.
    public var on: Bool
    /// Clicking does something. False for chips that only state a fact.
    public var actionable: Bool

    public var id: String { kind.rawValue }
}

public extension CommandFormat {
    /// The chip row for the current draft.
    ///
    /// Order is fixed — what it looks at, what it carries, where it goes — so
    /// the row reads as a sentence and the eye learns one position per fact.
    static func chips(contextApp: String?, withScreen: Bool,
                      target: CommandTarget) -> [CommandChip] {
        var chips: [CommandChip] = []
        if let app = contextApp?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            chips.append(CommandChip(kind: .context, symbol: "macwindow", label: app,
                                     on: false, actionable: false))
        }
        chips.append(CommandChip(kind: .screen, symbol: withScreen ? "photo.fill" : "photo",
                                 label: withScreen ? "screen attached" : "screen",
                                 on: withScreen, actionable: true))
        chips.append(CommandChip(kind: .route, symbol: "arrow.turn.down.right",
                                 label: target.label, on: false, actionable: false))
        return chips
    }
}
