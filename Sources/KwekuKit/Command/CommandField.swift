import SwiftUI
import AppKit

/// The notch's text editor.
///
/// An `NSTextView` rather than SwiftUI's `TextField`, for three reasons that
/// each came up in use:
///
/// 1. **Paste.** Kweku is an `LSUIElement` with no menu bar, so ⌘V has nothing
///    to dispatch to — the same bug `EditableTextField` exists to fix. A
///    command line you can't paste an error into would miss the point.
/// 2. **Height.** A stack trace is the single most likely thing to arrive here,
///    and a one-line field turns it into a slit you scroll sideways through.
///    This grows to `CommandFormat.editorMaxLines` and then scrolls.
/// 3. **The ghost.** The dim completion after the caret is drawn by hand, over
///    the text view's own rendering, so it can never be selected, submitted or
///    copied by accident — it isn't in the string at all until you accept it.
struct CommandEditor: NSViewRepresentable {
    @Binding var text: String
    /// Dim remainder shown after the caret. Not part of `text`.
    var ghost: String
    var placeholder: String
    var focused: Bool
    var onFocusChange: (Bool) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// +1 for older (↑), -1 for newer (↓). Only sent for a single-line draft;
    /// once there are newlines the arrows belong to the caret.
    var onRecall: (Int) -> Void
    /// Tab or → at the end of the line. Returns true when there was a ghost to
    /// take, so the key falls through to its normal job when there wasn't.
    var onAcceptGhost: () -> Bool
    /// Laid-out height of the text, so the panel can grow with it.
    var onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let view = CommandTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 12)
        view.textColor = .white
        view.insertionPointColor = .white
        // No inset: the panel already owns the padding, and a text view that
        // adds its own puts the caret out of line with the chevron.
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0,
                                                   height: CGFloat.greatestFiniteMagnitude)

        view.onSubmit = onSubmit
        view.onCancel = onCancel
        view.onRecall = onRecall
        view.onAcceptGhost = onAcceptGhost
        view.placeholder = placeholder
        view.ghost = ghost

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CommandTextView else { return }
        // Callbacks are re-made every render and capture current state; a stale
        // closure here would submit the previous draft.
        view.onSubmit = onSubmit
        view.onCancel = onCancel
        view.onRecall = onRecall
        view.onAcceptGhost = onAcceptGhost

        if view.string != text {
            view.string = text
            // Recall and clear both replace the whole string; the caret goes to
            // the end so ↑ then typing continues the recalled command.
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if view.ghost != ghost { view.ghost = ghost }
        if view.placeholder != placeholder { view.placeholder = placeholder }

        measure(view)
        syncFocus(view)
    }

    /// Report the laid-out height so the panel can grow a line at a time.
    private func measure(_ view: CommandTextView) {
        guard let manager = view.layoutManager, let container = view.textContainer else { return }
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height
        let measured = height > 0 ? height : CommandFormat.editorLineHeight
        DispatchQueue.main.async { onMeasure(measured) }
    }

    private func syncFocus(_ view: CommandTextView) {
        guard let window = view.window else { return }
        let isFirstResponder = window.firstResponder === view
        if focused, !isFirstResponder {
            // Deferred: the panel may only just have been allowed to take key,
            // and making first responder before that lands silently no-ops.
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        } else if !focused, isFirstResponder {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: CommandEditor
        init(_ parent: CommandEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? CommandTextView else { return }
            parent.text = view.string
        }

        func textDidBeginEditing(_ note: Notification) { parent.onFocusChange(true) }
    }
}

/// The text view itself: editing chords without a menu bar, the keys the
/// command line gives its own meaning, and the two pieces of text that are
/// drawn but never stored — the placeholder and the ghost.
final class CommandTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRecall: (Int) -> Void = { _ in }
    var onAcceptGhost: () -> Bool = { false }

    var ghost = "" { didSet { if ghost != oldValue { needsDisplay = true } } }
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingKeyEquivalents.handle(event, from: self)
            || super.performKeyEquivalent(with: event)
    }

    /// True once the draft has a newline in it — at which point the arrows go
    /// back to being caret movement, because a four-line paste you can't move
    /// around inside is worse than no recall.
    private var isMultiline: Bool { string.contains("\n") }

    private var caretAtEnd: Bool {
        let range = selectedRange()
        return range.length == 0 && range.location == (string as NSString).length
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit()
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⇧⏎ is the newline, so ⏎ can stay "send" even once the field has
            // grown into a paragraph.
            insertText("\n", replacementRange: selectedRange())
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
        case #selector(NSResponder.moveUp(_:)):
            if isMultiline { super.doCommand(by: selector) } else { onRecall(1) }
        case #selector(NSResponder.moveDown(_:)):
            if isMultiline { super.doCommand(by: selector) } else { onRecall(-1) }
        case #selector(NSResponder.insertTab(_:)):
            if !onAcceptGhost() { super.doCommand(by: selector) }
        case #selector(NSResponder.moveRight(_:)):
            if caretAtEnd, onAcceptGhost() { return }
            super.doCommand(by: selector)
        default:
            super.doCommand(by: selector)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            draw(text: placeholder, at: .zero, alpha: 0.28)
        } else if !ghost.isEmpty, let point = caretPoint() {
            draw(text: ghost, at: point, alpha: 0.26)
        }
    }

    /// Where the ghost starts: the trailing edge of the last laid-out glyph.
    private func caretPoint() -> NSPoint? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return .zero }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1),
                                        actualCharacterRange: nil)
        let box = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return NSPoint(x: box.maxX, y: box.minY)
    }

    private func draw(text: String, at point: NSPoint, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
