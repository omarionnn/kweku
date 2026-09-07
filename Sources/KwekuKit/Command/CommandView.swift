import SwiftUI
import AppKit

/// Command mode: type at Kweku instead of talking to it.
///
/// Collapsed it's a prompt line with the critter on the end of it. Summoned
/// with ⌥Space — or opened by hovering — it grows *out of* the cutout into a
/// panel: what it's looking at, what it's carrying and where it's going, then
/// the field, then whatever came back and what you can do with it.
///
/// The open is one motion by construction. `NotchPanelShape` at notch width is
/// already a flush nook, so at `reveal == 0` the panel *is* the cutout; the
/// animation only has to widen and lengthen it. Nothing appears — the notch
/// just spreads.
struct CommandView: View, NookComponent {
    @ObservedObject var commands: CommandHub
    @ObservedObject var vm: NotchViewModel
    /// The critter rides in the panel's right wing, the way it rides in the
    /// music island's. It is never faded in or out: it sits at the trailing
    /// edge, so widening the shape carries it outward on its own.
    @ObservedObject var critter: CreatureState
    var rim: NotchRimStyle
    /// Bumped by the ⌥Space hotkey. A counter and not a flag, so summoning
    /// while the panel is already open still re-focuses the field.
    var summon: Int
    /// Lines the editor needs right now, reported up so the window grows with
    /// a pasted trace instead of clipping it.
    @Binding var editorLines: Int
    /// Take me to the session this command became.
    var onOpenSession: () -> Void

    static let peek: CGFloat = 30
    static let expandedWidth: CGFloat = 420
    /// Body with a one-line editor; each extra line adds a line height.
    static let expandedBody: CGFloat = 150
    /// Room reserved at the trailing edge for the critter.
    private static let wing: CGFloat = 30

    static func metrics(_ context: NookContext) -> NookMetrics {
        let extra = CGFloat(max(0, context.commandLines - 1)) * CommandFormat.editorLineHeight
        return NookMetrics(peek: peek,
                           expandedBody: expandedBody + extra,
                           expandedWidth: expandedWidth)
    }

    /// True while the field holds the keyboard. Drives `vm.wantsKeyboard`,
    /// which is what actually lets the panel take key.
    @State private var editing = false
    /// Attach the screen to the next `ask`. Off by default — most commands
    /// don't need a picture, and one costs a capture and a chunk of upload.
    @State private var withScreen = false

    /// 0 = the bare cutout, 1 = the full panel. The shape's only animation.
    @State private var reveal: CGFloat = 0
    /// Content rides a second, later animation. Sharing the shape's spring
    /// would stretch the type as the panel grows.
    @State private var contentIn = false
    /// One mint lap of the outline on open.
    @State private var sweep: CGFloat = 0
    @State private var collapseWork: DispatchWorkItem?

    /// Where ↑/↓ have walked to in the recall ring; `draftIndex` means the
    /// text is the user's own.
    @State private var recallIndex = CommandFormat.draftIndex
    /// What was being typed before recall took the field over.
    @State private var draft = ""
    /// Set while recall is writing the field, so the write isn't mistaken for
    /// typing and doesn't reset the walk.
    @State private var recalling = false
    /// Laid-out height of the editor's text.
    @State private var measured = CommandFormat.editorLineHeight

    private var expanded: Bool { vm.isHovering || vm.expanded }
    private var bodyHeight: CGFloat {
        Self.expandedBody
            + CGFloat(max(0, editorLines - 1)) * CommandFormat.editorLineHeight
    }
    /// The completion offered after the caret.
    private var ghost: String {
        CommandFormat.ghost(for: commands.input, in: commands.history)
    }

    var body: some View {
        let cutoutH = vm.notchSize.height
        let notchW = vm.notchSize.width

        GeometryReader { proxy in
            let fullW = min(proxy.size.width, Self.expandedWidth)
            let panelW = notchW + (fullW - notchW) * reveal
            let panelH = Self.peek + (bodyHeight - Self.peek) * reveal

            ZStack(alignment: .top) {
                Color.clear
                ZStack(alignment: .top) {
                    NotchPanelShape(notchWidth: notchW, notchHeight: cutoutH,
                                    bottom: 12 + 10 * reveal)
                        .fill(Color.black)
                    NotchRim(notchWidth: notchW, notchHeight: cutoutH,
                             bottom: 12 + 10 * reveal, style: rim)
                    wake(notchWidth: notchW, cutoutH: cutoutH)
                    ZStack(alignment: .top) {
                        collapsedBand.opacity(contentIn ? 0 : 1)
                        expandedPanel.opacity(contentIn ? 1 : 0)
                            .offset(y: contentIn ? 0 : 6)
                    }
                    .frame(width: panelW, height: panelH)
                    .offset(y: cutoutH)
                }
                .frame(width: panelW, height: cutoutH + panelH)
                .overlay(alignment: .topTrailing) { wing(cutoutH: cutoutH) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: expanded) { open in open ? openPanel() : collapsePanel() }
        .onChange(of: summon) { _ in summonNow() }
        .onChange(of: commands.input) { _ in
            // Any real edit ends the recall walk; recall's own writes don't.
            if recalling { recalling = false } else { recallIndex = CommandFormat.draftIndex }
        }
        // Summoned over the music island, the panel is *created* already
        // expanded — the keyboard claim is what put it on screen. Animate from
        // the cutout anyway, or the one path that most needs the open to look
        // deliberate is the one that snaps.
        .onAppear {
            if vm.wantsKeyboard {
                editing = true
                reveal = 0
                contentIn = false
                openPanel()
            } else if expanded {
                reveal = 1
                contentIn = true
            }
        }
        .onDisappear { stopEditing() }
    }

    // MARK: - The wake

    /// A single mint lap of the outline as the panel opens — the one signal
    /// that says "this is listening now". Derived from `sweep` alone, so it
    /// can't stall or repeat: the tail fades as the head reaches the end.
    private func wake(notchWidth: CGFloat, cutoutH: CGFloat) -> some View {
        NotchPanelShape(notchWidth: notchWidth, notchHeight: cutoutH,
                        bottom: 12 + 10 * reveal)
            .trim(from: max(0, sweep - 0.28), to: sweep)
            .stroke(NotchRim.mint.opacity(sweep >= 1 ? 0 : min(1, (1 - sweep) / 0.25)),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .allowsHitTesting(false)
    }

    /// The critter, trailing-anchored so the shape's growth carries it from
    /// the collapsed band out into the wing. It grows a little as it travels;
    /// it never fades, because it is the same creature the whole time.
    private func wing(cutoutH: CGFloat) -> some View {
        CritterFace(state: critter, vm: vm, showMotes: false)
            .frame(width: 30, height: 22)
            .scaleEffect(0.66 + 0.34 * reveal)
            .padding(.trailing, 8 + 4 * reveal)
            .padding(.top, cutoutH + 5)
            .allowsHitTesting(false)
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
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, Self.wing)
        .padding(.top, 7)
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipRow
            fieldRow
            output
            if commands.resultText != nil { verbRow } else { actionRow }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16 + Self.wing)
        .padding(.top, 7).padding(.bottom, 9)
    }

    /// What it's looking at, what it's carrying, where it goes — in that order,
    /// so the row reads as a sentence and each fact keeps its own position.
    private var chipRow: some View {
        HStack(spacing: 5) {
            ForEach(CommandFormat.chips(contextApp: commands.contextApp,
                                        withScreen: withScreen,
                                        target: .openClaw)) { chip in
                chipView(chip)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private func chipView(_ chip: CommandChip) -> some View {
        let body = HStack(spacing: 3) {
            Image(systemName: chip.symbol).font(.system(size: 8, weight: .semibold))
            Text(chip.label).font(.system(size: 8.5, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(chip.on ? NotchRim.mint : .white.opacity(0.42))
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(
            Capsule().fill(Color.white.opacity(chip.on ? 0.10 : 0.05))
        )

        return Group {
            if chip.actionable {
                Button { withScreen.toggle() } label: { body.contentShape(Capsule()) }
                    .buttonStyle(CommandButtonStyle(enabled: true))
                    .help("Attach the current screen to this command")
            } else {
                body
            }
        }
    }

    private var fieldRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(editing ? NotchRim.mint : .white.opacity(0.35))
                .padding(.top, 3)
            CommandEditor(text: $commands.input,
                          ghost: ghost,
                          placeholder: "ask Kweku to do something",
                          focused: editing,
                          onFocusChange: { focused in
                              editing = focused
                              vm.wantsKeyboard = focused
                              if focused { commands.captureContext() }
                          },
                          onSubmit: submit,
                          onCancel: stopEditing,
                          onRecall: recall,
                          onAcceptGhost: acceptGhost,
                          onMeasure: measure)
                .frame(height: CommandFormat.editorHeight(measured: measured))
            iconButton("arrow.up.circle.fill", help: "Send",
                       enabled: !commands.input.isEmpty && !commands.state.isBusy,
                       submit)
        }
        // The editor is thin; the whole row is the target for focusing it.
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
    /// is answered before it's asked, and teaches the two keys worth knowing.
    private var idleHint: String {
        if let target = commands.lastTarget { return "last run: \(target.label)" }
        return "⏎ send · ⇧⏎ newline · ↑ recall"
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
        .frame(height: 20)
    }

    /// What you can do with an answer. A result that can only be read is half
    /// an answer: the panel truncates, the notch is small, and the usual next
    /// move is to hand the whole thing to something that can change files.
    private var verbRow: some View {
        HStack(spacing: 6) {
            iconButton("doc.on.doc", help: "Copy the answer", enabled: true,
                       commands.copyResult)
            if commands.lastTarget == .openClaw {
                iconButton("arrow.clockwise", help: "Run it again", enabled: !commands.state.isBusy,
                           commands.rerun)
                Button(action: commands.escalateToAgent) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 9, weight: .semibold))
                        Text("hand to \(CommandTarget.agent(cwd: commands.agentCwdProvider()).label)")
                            .font(.system(size: 9.5, weight: .medium))
                            .lineLimit(1).truncationMode(.head)
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
                .help("Carry this command and its answer over to a coding agent")
            }
            iconButton("arrow.up.forward.app", help: "Open the session this became",
                       enabled: true, onOpenSession)
            Spacer(minLength: 4)
            iconButton("xmark", help: "Dismiss", enabled: true, commands.dismissResult)
        }
        .frame(height: 20)
    }

    // MARK: - Open and close

    /// Shape first, content after. The window is already at full size by the
    /// time this runs — the controller resizes on `wantsKeyboard`/hover before
    /// a frame is drawn — so the panel has room to grow into and never gets
    /// clipped mid-animation.
    private func openPanel() {
        collapseWork?.cancel(); collapseWork = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { reveal = 1 }
        sweep = 0
        withAnimation(.easeOut(duration: 0.3).delay(0.05)) { sweep = 1 }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) { contentIn = true }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Not the open reversed: the content goes first and the shape follows
    /// critically damped. A bounce on the way out reads as a bug.
    private func collapsePanel() {
        collapseWork?.cancel()
        stopEditing()
        withAnimation(.easeIn(duration: 0.1)) { contentIn = false }
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.26, dampingFraction: 1)) { reveal = 0 }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// ⌥Space from anywhere. Claiming the keyboard is what opens the panel:
    /// the controller turns `wantsKeyboard` into both a key window and a
    /// hover, so `expanded` flips and `openPanel` runs off the same change
    /// hover does. One open, one code path.
    /// The root captured the front app before claiming the keyboard, so this
    /// deliberately doesn't re-capture: by now the front app is Kweku.
    private func summonNow() {
        editing = true
        vm.wantsKeyboard = true
    }

    // MARK: - Actions

    private func submit() {
        guard !commands.input.isEmpty else { return }
        recallIndex = CommandFormat.draftIndex
        draft = ""
        commands.send(withScreen: withScreen)
    }

    /// ↑ walks back through the ring, ↓ walks forward and hands the draft back
    /// at the end of it — so recall can always be undone without retyping.
    private func recall(_ delta: Int) {
        let next = CommandFormat.recallIndex(from: recallIndex, by: delta,
                                             count: commands.history.count)
        guard next != recallIndex else { return }
        if recallIndex == CommandFormat.draftIndex { draft = commands.input }
        recallIndex = next
        recalling = true
        commands.input = CommandFormat.recall(commands.history, at: next) ?? draft
    }

    private func acceptGhost() -> Bool {
        let completion = ghost
        guard !completion.isEmpty else { return false }
        commands.input += completion
        return true
    }

    private func measure(_ height: CGFloat) {
        guard measured != height else { return }
        measured = height
        let lines = CommandFormat.editorLines(measured: height)
        if editorLines != lines {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editorLines = lines }
        }
    }

    private func startEditing() {
        guard !editing else { return }
        commands.captureContext()
        editing = true
        vm.wantsKeyboard = true
    }

    /// Give the keyboard back, and the machine with it. Summoning activates
    /// Kweku to receive keystrokes at all, so closing has to hand the front
    /// app back — otherwise ⌥Space, Escape leaves you typing into an accessory
    /// app with no window.
    private func stopEditing() {
        guard editing || vm.wantsKeyboard else { return }
        editing = false
        vm.wantsKeyboard = false
        NSApp.deactivate()
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool,
                            _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(CommandButtonStyle(enabled: enabled))
        .disabled(!enabled)
        .help(help)
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
