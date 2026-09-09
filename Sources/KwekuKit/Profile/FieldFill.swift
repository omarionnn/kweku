import AppKit
import ApplicationServices

/// Typing a known value into the form field Omari is sitting in.
///
/// `AgentReply` established the shape of this: there is no API for writing into
/// someone else's text field, so the only honest way in is the way a human does
/// it — real keystrokes at whatever holds focus. That makes *aim* the dangerous
/// part rather than the typing, and a form is a worse place to miss than a
/// terminal: the wrong field silently carries the wrong answer into a
/// submission, and an email address typed into a page body is a mess he has to
/// notice before he can fix it.
///
/// So every fill is gated on the focused element actually being an editable
/// text control, and on it being empty. Both are refusals, not degrades — the
/// caller is told why and Omari hears it, which is far better than a
/// best-effort guess landing somewhere unrecoverable.
///
/// Return is never pressed. `AgentReply` submits because a waiting agent's
/// prompt needs it; a form submits *the whole application*, so filling stops
/// at the value and leaves the button to him.
public enum FieldFill {

    /// Why a fill didn't happen. Each case is a sentence Kweku can say out loud.
    public enum Refusal: Equatable {
        case noAccessibility
        case noFocusedField
        case notEditable(role: String)
        case fieldNotEmpty(existing: String)
        case unknownField(String)

        public var spoken: String {
            switch self {
            case .noAccessibility:
                return "I don't have Accessibility permission, so I can't type for you. "
                    + "System Settings › Privacy & Security › Accessibility, enable Kweku."
            case .noFocusedField:
                return "Nothing's focused — click into the field first and I'll fill it."
            case .notEditable(let role):
                return "What's focused isn't a text field (\(role)), so I didn't type anything."
            case .fieldNotEmpty(let existing):
                return "That field already has \"\(existing)\" in it — clear it and I'll fill it, "
                    + "or tell me to replace it."
            case .unknownField(let name):
                return "I don't have a \(name) on file for you."
            }
        }
    }

    public enum Outcome: Equatable {
        case filled(key: String)
        case refused(Refusal)
    }

    /// Roles that accept typed text. Web inputs in Safari and Chrome report
    /// `AXTextField`; multi-line answers report `AXTextArea`; some framework
    /// inputs report `AXComboBox` with an editable text child.
    static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
    ]

    /// Look `label` up in the profile and type it into the focused field.
    ///
    /// `replacing` is opt-in and only reachable when Omari says so out loud;
    /// the default refuses rather than overwriting something he typed.
    @MainActor
    @discardableResult
    public static func fill(label: String,
                            from profile: PersonalProfile,
                            replacing: Bool = false) -> Outcome {
        guard let value = profile.value(for: label) else {
            return .refused(.unknownField(label))
        }
        return type(value, key: PersonalProfile.canonicalKey(for: label) ?? label,
                    replacing: replacing)
    }

    /// The delivery half, separated so the gates can be read in one place.
    @MainActor
    static func type(_ value: String, key: String, replacing: Bool) -> Outcome {
        // Same lazy prompt as click-to-focus and agent reply. Without the grant
        // keystrokes go nowhere at all, so this is a refusal, not a degrade.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return .refused(.noAccessibility) }

        guard let element = focusedElement() else { return .refused(.noFocusedField) }

        let role = string(from: element, attribute: kAXRoleAttribute as String) ?? "unknown"
        guard editableRoles.contains(role) else { return .refused(.notEditable(role: role)) }

        let existing = (string(from: element, attribute: kAXValueAttribute as String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            guard replacing else { return .refused(.fieldNotEmpty(existing: existing)) }
            selectAll()
        }

        Keystrokes.type(value)
        return .filled(key: key)
    }

    // MARK: - Accessibility reads

    /// The system-wide focused element — whatever has the caret, in whichever
    /// app is frontmost. Asking the system rather than a specific app is what
    /// lets this work in Safari, Chrome, and a native window alike.
    static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let found = value, CFGetTypeID(found) == AXUIElementGetTypeID()
        else { return nil }
        return (found as! AXUIElement)
    }

    static func string(from element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// ⌘A, so a replacing fill overwrites rather than appends.
    private static func selectAll() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
