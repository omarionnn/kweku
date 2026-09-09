import SwiftUI
import AppKit

/// The agent panel's one-line reply field: an `NSTextField` bridged into
/// SwiftUI.
///
/// SwiftUI's own `TextField` would do the typing, but not the editing chords:
/// Kweku is an `LSUIElement` with no menu bar, so ⌘V has nothing to dispatch to
/// — the same bug `EditableTextField` was written to fix for the API-key prompt.
/// A reply you can't paste into would miss half the point.
///
/// Deliberately not the command panel's `CommandEditor`. That one is a text
/// *view*: it grows with a pasted stack trace, offers ghost completions and
/// walks a recall ring, all of which are right for a command line and wrong for
/// a 32-point row whose entire job is one line and a Return.
struct AgentReplyField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focused: Bool
    var onFocusChange: (Bool) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> EditableTextField {
        let field = EditableTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.28),
                         .font: NSFont.systemFont(ofSize: 11)])
        return field
    }

    func updateNSView(_ field: EditableTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        // The placeholder carries the failure state — it changes when a send
        // didn't land — so it has to be refreshed, not just set at birth.
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.28),
                             .font: NSFont.systemFont(ofSize: 11)])
        }
        guard let window = field.window else { return }
        let isFirstResponder = window.firstResponder === field.currentEditor()
            && field.currentEditor() != nil
        if focused, !isFirstResponder {
            // Deferred: the panel may only just have been allowed to take key,
            // and making first responder before that lands silently no-ops.
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        } else if !focused, isFirstResponder {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: AgentReplyField
        init(_ parent: AgentReplyField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            parent.onFocusChange(true)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
