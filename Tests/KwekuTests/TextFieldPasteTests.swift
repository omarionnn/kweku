import AppKit
import KwekuKit

/// The Gemini key prompt could not accept a pasted key: Kweku is an
/// `LSUIElement` app with no Edit menu, and ⌘V is a menu key equivalent.
/// These pin the chord mapping that replaces it.
enum TextFieldPasteTests {
    static func all() {
        typealias K = TextEditingKeyEquivalents

        Check.run("command-V pastes") {
            Check.ok(K.selector(forCharacter: "v", modifiers: .command) == #selector(NSText.paste(_:)),
                     "the chord that was broken")
        }

        Check.run("the other editing verbs are wired") {
            Check.ok(K.selector(forCharacter: "c", modifiers: .command) == #selector(NSText.copy(_:)), "copy")
            Check.ok(K.selector(forCharacter: "x", modifiers: .command) == #selector(NSText.cut(_:)), "cut")
            Check.ok(K.selector(forCharacter: "a", modifiers: .command) == #selector(NSText.selectAll(_:)), "select all")
            Check.ok(K.selector(forCharacter: "z", modifiers: .command) == Selector(("undo:")), "undo")
        }

        Check.run("shift-command-Z is redo, not undo") {
            Check.ok(K.selector(forCharacter: "z", modifiers: [.command, .shift]) == Selector(("redo:")),
                     "redo")
        }

        Check.run("uppercase characters still map") {
            // charactersIgnoringModifiers reports "V" under caps lock.
            Check.ok(K.selector(forCharacter: "V", modifiers: .command) == #selector(NSText.paste(_:)),
                     "caps lock doesn't break paste")
        }

        Check.run("plain keys are left alone") {
            Check.ok(K.selector(forCharacter: "v", modifiers: []) == nil, "typing v inserts v")
            Check.ok(K.selector(forCharacter: "q", modifiers: .command) == nil, "command-Q is not ours")
        }

        Check.run("foreign modifier combinations fall through") {
            // The usual bug in this override: check only for .command, and
            // swallow every chord that happens to include it.
            Check.ok(K.selector(forCharacter: "v", modifiers: [.command, .option]) == nil, "option-command-V")
            Check.ok(K.selector(forCharacter: "v", modifiers: [.command, .control]) == nil, "control-command-V")
            Check.ok(K.selector(forCharacter: "v", modifiers: [.command, .shift]) == nil, "shift-command-V")
            Check.ok(K.selector(forCharacter: "a", modifiers: [.command, .shift]) == nil, "shift-command-A")
        }

        Check.run("stray non-chord flags don't defeat the match") {
            // Caps lock is the one that bites: it rides along in
            // `deviceIndependentFlagsMask`, so masking with that instead of the
            // four chord modifiers silently disables paste while it's on.
            Check.ok(K.selector(forCharacter: "V", modifiers: [.command, .capsLock]) == #selector(NSText.paste(_:)),
                     "paste survives caps lock")
            Check.ok(K.selector(forCharacter: "v", modifiers: [.command, .function]) == #selector(NSText.paste(_:)),
                     "paste survives a function flag")
            Check.ok(K.selector(forCharacter: "v", modifiers: [.command, .numericPad]) == #selector(NSText.paste(_:)),
                     "paste survives a numeric-pad flag")
        }
    }
}
