import AppKit

/// Synthesised keyboard input — the only way into a window that owns its own
/// input (a tty, a web form) from outside it.
///
/// Extracted from `AgentReply`, which needed exactly this to answer a waiting
/// agent, so that filling a form field doesn't grow a second copy of it.
public enum Keystrokes {

    /// UTF-16 units per synthesised event. `keyboardSetUnicodeString` is a
    /// fixed-size buffer in practice, so long text goes in chunks rather than
    /// being quietly clipped.
    static let chunk = 16

    /// Type text as unicode payloads rather than key codes: the text is
    /// whatever it is, and mapping it back onto a keyboard layout would break
    /// on the first non-US character.
    public static func type(_ text: String) {
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

    /// Virtual key 36 — a real Return, because a prompt listens for the key,
    /// not for a newline character in a paste.
    public static func pressReturn() {
        press(virtualKey: 36)
    }

    private static func press(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
