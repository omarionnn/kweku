import AppKit
import ApplicationServices

/// Answering a waiting agent without leaving the notch.
///
/// The panel could already take you *to* a session that wants you. That's the
/// right move for a design call, and the wrong one for the question most agents
/// actually stop on — "shall I go ahead?" — where the walk to the terminal
/// costs more than the answer does. This types the answer for you.
///
/// There is no API for this. An interactive agent owns its tty and nothing
/// outside can write to it (see `OMPBridgeManager`), so the only honest way in
/// is the way a human does it: raise the window, then send real keystrokes.
/// That makes the aim the dangerous part, not the typing — text delivered to
/// the wrong window is text typed into whatever *is* in front — so delivery
/// refuses unless the intended app is confirmed frontmost first.
public enum AgentReply {

    // MARK: - Pure

    /// One line of plain text, or nil if there's nothing worth sending.
    ///
    /// Newlines are the point: a pasted multi-line answer submits at the first
    /// one and leaves the rest to be interpreted as whatever comes next in a
    /// TUI. Folding them into spaces sends the whole thought as one turn.
    public static func sanitize(_ raw: String) -> String? {
        // Control characters carry terminal meaning — ^C, ^D, escape sequences
        // — that a reply has no business expressing; newlines are among them.
        let flattened = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let text = String(flattened)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Whether a session can be answered this way: it has to be a real process
    /// in a real window, and it has to actually be waiting. Typing at a working
    /// agent lands mid-turn, where the keystrokes mean something else.
    public static func canReply(to session: AgentSession) -> Bool {
        guard session.state == .waiting else { return false }
        if case .terminal = session.destination { return true }
        return false
    }

    // MARK: - Delivery

    /// How long to let the window come forward before typing at it. Activation
    /// is asynchronous, and the check below is only meaningful once it lands.
    static let focusSettle: TimeInterval = 0.35

    /// Raise the session's terminal and type `raw` into it, followed by Return.
    ///
    /// Returns false when the text was empty, the session isn't answerable, or
    /// — the case that matters — the intended terminal did not come to the
    /// front. Nothing is typed in that last case: a silent no-op is a far
    /// better outcome than a sentence appearing in someone's editor.
    @MainActor
    @discardableResult
    public static func send(_ raw: String, to session: AgentSession) async -> Bool {
        guard let text = sanitize(raw), canReply(to: session),
              let appPid = TerminalFocus.owningApp(from: session.pid,
                                                   parent: TerminalFocus.realParent(of:),
                                                   isApp: TerminalFocus.isRegularApp(_:))
        else { return false }

        // Same lazy Accessibility prompt as click-to-focus. Without the grant
        // the keystrokes go nowhere, so this is a refusal, not a degrade.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        TerminalFocus.focus(session: session)
        try? await Task.sleep(nanoseconds: UInt64(focusSettle * 1_000_000_000))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == appPid else { return false }

        type(text)
        // A beat before Return: TUIs redraw on input, and submitting inside
        // that redraw is how half a line ends up in the prompt.
        try? await Task.sleep(nanoseconds: 80_000_000)
        pressReturn()
        return true
    }

    /// UTF-16 units per synthesised event. `keyboardSetUnicodeString` is a
    /// fixed-size buffer in practice, so long replies go in chunks rather than
    /// being quietly clipped.
    private static let chunk = 16

    /// Type text as unicode payloads rather than key codes — the reply is
    /// whatever he typed, and mapping that back onto a keyboard layout would
    /// break on the first non-US character.
    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let slice = Array(units[index..<min(index + chunk, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                else { continue }
                var buffer = slice
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
                event.post(tap: .cghidEventTap)
            }
            index += chunk
        }
        units.removeAll()
    }

    /// Virtual key 36 — a real Return, because an agent's prompt is listening
    /// for the key, not for a newline character in a paste.
    private static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
