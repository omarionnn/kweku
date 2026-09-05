import AppKit

/// Standard editing shortcuts for text fields in a menu-less app.
///
/// Kweku runs as an `LSUIElement` accessory with no main menu, and AppKit
/// implements ⌘V/⌘C/⌘X/⌘A as *menu* key equivalents rather than as anything
/// the field editor handles itself. With no Edit menu there is nothing to
/// dispatch to, so those chords silently do nothing inside an `NSAlert`
/// accessory view — which is how the Gemini key prompt ended up unable to
/// accept a pasted key.
///
/// `performKeyEquivalent` is offered to the view hierarchy before the menu, so
/// handling it here restores the editing verbs without giving the app a menu
/// bar it otherwise has no use for.
public enum TextEditingKeyEquivalents {
    /// Selector for a standard editing chord, or nil to fall through.
    ///
    /// Pure and separately tested: the modifier bookkeeping is where this kind
    /// of override usually goes wrong — swallowing ⌥⌘V or ⇧⌘A because it only
    /// checked for `.command` and ignored the rest.
    public static func selector(forCharacter character: String,
                                modifiers: NSEvent.ModifierFlags) -> Selector? {
        // Only the four chord modifiers are consulted. `deviceIndependentFlagsMask`
        // would be the obvious choice and is wrong: it also carries .capsLock,
        // .function and .numericPad, so caps lock being on would be read as a
        // foreign modifier and swallow ⌘V — the exact bug this file exists to fix.
        let flags = modifiers.intersection([.command, .shift, .control, .option])
        guard flags.contains(.command) else { return nil }
        // Shift is the only other modifier that maps to a standard verb (⇧⌘Z).
        // Control/option chords belong to the field editor or to nobody.
        guard flags.subtracting([.command, .shift]).isEmpty else { return nil }
        let shifted = flags.contains(.shift)
        switch character.lowercased() {
        case "v": return shifted ? nil : #selector(NSText.paste(_:))
        case "c": return shifted ? nil : #selector(NSText.copy(_:))
        case "x": return shifted ? nil : #selector(NSText.cut(_:))
        case "a": return shifted ? nil : #selector(NSText.selectAll(_:))
        case "z": return shifted ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    /// Routes the chord to the field editor via the responder chain.
    static func handle(_ event: NSEvent, from view: NSView) -> Bool {
        guard let characters = event.charactersIgnoringModifiers,
              let action = selector(forCharacter: characters,
                                    modifiers: event.modifierFlags) else { return false }
        return NSApp.sendAction(action, to: nil, from: view)
    }
}

/// `NSTextField` that accepts ⌘V and friends without a menu bar.
public final class EditableTextField: NSTextField {
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingKeyEquivalents.handle(event, from: self)
            || super.performKeyEquivalent(with: event)
    }
}

/// Masked variant, for credentials.
///
/// The secure field editor refuses copy and cut on its own, so those chords
/// resolve to nothing here — deliberately. Paste is the one that matters.
public final class EditableSecureTextField: NSSecureTextField {
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingKeyEquivalents.handle(event, from: self)
            || super.performKeyEquivalent(with: event)
    }
}
