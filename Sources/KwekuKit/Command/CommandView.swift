import SwiftUI
import AppKit

/// Command mode: type at Kweku instead of talking to it.
///
/// Collapsed it's a prompt line. Expanded it's a field, a send, and a
/// "fix what's on screen" that reads the foreground window and hands the
/// failure to a coding agent.
struct CommandView: View, NookComponent {
    @ObservedObject var commands: CommandHub
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle

    static let peek: CGFloat = 30
    static let expandedBody: CGFloat = 124
    static let expandedWidth: CGFloat = 380

    static func metrics(_ context: NookContext) -> NookMetrics {
        NookMetrics(peek: peek, expandedBody: expandedBody, expandedWidth: expandedWidth)
    }

    /// True while the field holds the keyboard. Drives `vm.wantsKeyboard`, which
    /// is what actually lets the panel take key.
    @State private var editing = false
    /// Attach the screen to the next `ask`. Off by default — most commands
    /// don't need a picture, and one costs a capture and a chunk of upload.
    @State private var withScreen = false

    private var expanded: Bool { vm.isHovering || vm.expanded }

    var body: some View {
        let cutoutH = vm.notchSize.height
        let bodyH = expanded ? Self.expandedBody : Self.peek

        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .top) {
                Color.clear
                ZStack(alignment: .top) {
                    NotchPanelShape(notchWidth: vm.notchSize.width, notchHeight: cutoutH,
                                    bottom: expanded ? 22 : 12)
                        .fill(Color.black)
                    NotchRim(notchWidth: vm.notchSize.width, notchHeight: cutoutH,
                             bottom: expanded ? 22 : 12, style: rim)
                    Group { expanded ? AnyView(expandedPanel) : AnyView(collapsedBand) }
                        .frame(width: w, height: bodyH)
                        .offset(y: cutoutH)
                }
                .frame(width: w, height: cutoutH + bodyH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Collapsing the panel must also give the keyboard back, or the notch
        // sits on the key window with nothing visible to type into.
        .onChange(of: expanded) { if !$0 { stopEditing() } }
        .onDisappear { stopEditing() }
    }

    // MARK: - Collapsed

    private var collapsedBand: some View {
        HStack(spacing: 7) {
            Image(systemName: commands.state.isBusy ? "circle.dotted" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(commands.state.isBusy ? NotchRim.amber : .white.opacity(0.5))
            Text(commands.state.progressLabel ?? "ask Kweku")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(commands.state.isBusy ? 0.85 : 0.5))
                .lineLimit(1).truncationMode(.tail)
        }
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow
            output
            actionRow
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 9)
    }

    private var fieldRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(editing ? NotchRim.mint : .white.opacity(0.35))
            CommandField(text: $commands.input,
                         placeholder: "ask Kweku to do something",
                         focused: editing,
                         onFocusChange: { focused in
                             editing = focused
                             vm.wantsKeyboard = focused
                             if focused { commands.captureContext() }
                         },
                         onSubmit: submit,
                         onCancel: stopEditing)
                .frame(height: 18)
            iconButton("photo", help: "Attach the current screen to this command",
                       on: withScreen) { withScreen.toggle() }
            iconButton("arrow.up.circle.fill", help: "Send",
                       on: false, enabled: !commands.input.isEmpty && !commands.state.isBusy,
                       submit)
        }
        // The field is small; the whole row is the target for focusing it.
        .contentShape(Rectangle())
        .onTapGesture { startEditing() }
    }

    /// Progress while running, the answer when it lands. Scrolls, because a
    /// gateway result is whatever length it is.
    private var output: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                switch commands.state {
                case .idle:
                    Text(idleHint)
                        .foregroundStyle(.white.opacity(0.3))
                case .reading, .running:
                    HStack(alignment: .top, spacing: 6) {
                        WorkingDots()
                        Text(commands.state.progressLabel ?? "")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                case .result(let text, let ok):
                    Text(text)
                        .foregroundStyle(ok ? .white.opacity(0.85) : NotchRim.amber.opacity(0.95))
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 9.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Idle copy that names the last place work went, so "where did that go?"
    /// is answered before it's asked.
    private var idleHint: String {
        if let target = commands.lastTarget { return "last run: \(target.label)" }
        return "⏎ to send · reads your screen with the photo toggle"
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: commands.fixWhatsOnScreen) {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9, weight: .semibold))
                    Text("fix what's on screen")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(CommandButtonStyle(enabled: !commands.state.isBusy))
            .disabled(commands.state.isBusy)
            .help("Read the failure on the foreground window and hand it to the agent")

            Spacer(minLength: 6)

            // Where "fix" would land. Shown before you press it, because the
            // routing is a guess — the most actionable session, not necessarily
            // the repo you're looking at.
            if let cwd = commands.agentCwdProvider() {
                Text("→ \(CommandTarget.agent(cwd: cwd).label)")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1).truncationMode(.head)
            } else {
                Text("no agent session")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        guard !commands.input.isEmpty else { return }
        commands.send(withScreen: withScreen)
    }

    private func startEditing() {
        guard !editing else { return }
        commands.captureContext()
        editing = true
        vm.wantsKeyboard = true
    }

    private func stopEditing() {
        guard editing || vm.wantsKeyboard else { return }
        editing = false
        vm.wantsKeyboard = false
    }

    private func iconButton(_ symbol: String, help: String, on: Bool,
                            enabled: Bool = true,
                            _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? NotchRim.mint : .white)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(CommandButtonStyle(enabled: enabled))
        .disabled(!enabled)
        .help(help)
    }
}

/// `NSTextField` bridged into SwiftUI.
///
/// SwiftUI's own `TextField` would do the typing, but not the editing chords:
/// Kweku is an `LSUIElement` with no menu bar, so ⌘V has nothing to dispatch to
/// — the same bug `EditableTextField` was written to fix for the API-key
/// prompt. A command line you can't paste an error into would miss the point.
/// (Also the agent panel's reply field — same paste problem, same fix.)
struct CommandField: NSViewRepresentable {
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
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.28),
                         .font: NSFont.systemFont(ofSize: 12)])
        return field
    }

    func updateNSView(_ field: EditableTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
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
        private let parent: CommandField
        init(_ parent: CommandField) { self.parent = parent }

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

/// Three dots that cycle while something is in flight. A pure function of the
/// clock, like the rim's comet, so it can't drift or stall.
private struct WorkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.25) % 3
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index == step ? 0.8 : 0.25))
                        .frame(width: 3, height: 3)
                }
            }
            .padding(.top, 3)
        }
    }
}

private struct CommandButtonStyle: ButtonStyle {
    var enabled: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!enabled ? 0.28 : (configuration.isPressed ? 0.55 : (hovering ? 1 : 0.72)))
            .scaleEffect(configuration.isPressed && enabled ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
