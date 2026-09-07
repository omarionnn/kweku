import SwiftUI
import AppKit


/// Top-level content injected into the notch window. Owns the creature, shelf,
/// sensor and music models; handles drops and the right-click menu. Each mode
/// (creature+shelf, weather, agents, system, Spotify) is a self-contained view
/// that draws the shared `NotchPanelShape` as its own seamless background and
/// strokes a `NotchRim` over it for ambient state.
///
/// The modes themselves live in `NookComponent.swift`: a component declares its
/// own sizing there, so adding one doesn't mean editing the sizing arithmetic
/// down in `updateSize()` as well.
struct NotchContentRoot: View {
    @ObservedObject var vm: NotchViewModel
    @StateObject private var creature: CreatureState
    @StateObject private var shelf = ShelfStore()
    @StateObject private var sensors: SensorHub
    @StateObject private var music = MusicHub()
    @StateObject private var agents = AgentWatchHub()
    @StateObject private var weather = WeatherHub()
    @StateObject private var stats = StatsHub()
    @StateObject private var commands = CommandHub()
    @StateObject private var live = LiveSessionController()

    @State private var isTargeted = false
    @State private var hidden = false
    @State private var mode: NookMode = {
        let stored = NookMode(rawValue: UserDefaults.standard.string(forKey: "nookMode") ?? "")
        // Only a cycleable mode can be resumed. `command` is summoned, never
        // landed on — and an earlier build that persisted it is exactly how
        // the notch ended up stuck as a text box across restarts.
        guard let stored, NookMode.cycle.contains(stored) else { return .critter }
        return stored
    }()
    /// Where to go back to when the summoned command panel closes.
    @State private var modeBeforeSummon: NookMode?
    /// Last `vm.cycleSteps` value applied, so scroll flips are diffed rather
    /// than counted — a dropped update can't desynchronise the mode.
    @State private var lastCycleStep = 0
    /// Transient confirmation after a drop is dispatched.
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?
    /// Bumped by ⌥Space. The command panel watches it rather than a flag, so
    /// summoning twice re-focuses the field instead of doing nothing.
    @State private var commandSummon = 0
    /// Lines the command editor is showing, reported up by the panel so the
    /// window grows under a pasted stack trace.
    @State private var commandLines = 1

    private let shelfPanelHeight: CGFloat = 66
    private let shelfPanelWidth: CGFloat = 200

    init(viewModel: NotchViewModel) {
        _vm = ObservedObject(wrappedValue: viewModel)
        _creature = StateObject(wrappedValue: CreatureState(viewModel: viewModel))
        _sensors = StateObject(wrappedValue: SensorHub(viewModel: viewModel))
    }

    private var open: Bool { vm.isHovering || vm.expanded }
    /// The shelf hangs under the open notch — except while typing. A strip
    /// pinned at the panel's full height would float detached under the panel
    /// as it grows out of the cutout, and a caret is no time to be filing.
    private var showShelf: Bool {
        !hidden && !shelf.items.isEmpty && open && !vm.expanded && mode != .command
    }
    /// A drag is armed: offer the drop destinations instead of the usual body.
    private var showDropTargets: Bool { !hidden && vm.expanded && !music.isShowing }
    /// The command panel outranks the Spotify island while it holds the
    /// keyboard.
    ///
    /// Without this, ⌥Space is dead for as long as music is playing — the
    /// island wins the nook, and the field you just summoned is never drawn.
    /// A caret is like a running Live session: something you are *doing*, and
    /// it beats something happening in the background.
    ///
    /// It gates the *island's* branch rather than adding one of its own. Given
    /// its own `else if`, `commandStack` would appear at two positions in the
    /// chain, SwiftUI would read those as two different views, and flipping
    /// the takeover would tear the panel down and build it again — running
    /// `onDisappear`, which hands the keyboard back, which flips the takeover
    /// off again. The summon undid itself in about 20ms.
    private var commandTakeover: Bool { !hidden && mode == .command && vm.wantsKeyboard }
    /// The one-line invitation under the notch, in the two modes that are a
    /// resting state rather than something you scrolled to in order to read.
    /// Weather and stats deliberately don't get it: a text field under a
    /// number you came to check is noise.
    private var showCommandPrompt: Bool {
        !hidden && open && !vm.expanded && !live.running
            && (mode == .critter || music.isShowing)
    }
    /// The hover-reveal session list, offered in critter mode as well as its
    /// own mode — it's the thing most worth surfacing when you look at Kweku.
    private var showAgentPanel: Bool {
        !hidden && open && !vm.expanded && agents.table.count > 0
            && (mode == .critter || music.isShowing)
    }
    /// The caption strip is the *collapsed* session's transcript. Expanded, the
    /// Live panel carries the same two lines itself, so showing both would be
    /// the same words twice.
    private var showCaptions: Bool {
        !hidden && live.running && !open && !(live.caption.isEmpty && live.heard.isEmpty)
    }

    /// One ambient signal on the rim at a time, most urgent first.
    private var rim: NotchRimStyle {
        NotchRimStyle.resolve(attention: creature.agentWaiting,
                              live: live.running,
                              speaking: live.speaking,
                              voiceLevel: creature.voiceLevel,
                              working: creature.agentWorking,
                              activity: creature.agentActivity)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if live.running && !hidden {
                liveStack
            } else if music.isShowing && !commandTakeover {
                musicStack
            } else if mode == .weather && !hidden {
                weatherStack
            } else if mode == .agents && !hidden {
                agentStack
            } else if mode == .stats && !hidden {
                statsStack
            } else if mode == .command && !hidden {
                commandStack
            } else {
                critterStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { toastLabel }
        // A drop anywhere outside the explicit targets still means "shelf it".
        .onDrop(of: ShelfStore.acceptedTypes, isTargeted: $isTargeted) { providers in
            shelf.ingest(providers); return true
        }
        .onChange(of: isTargeted) { creature.setMouth(open: $0 ? 1 : 0) }
        .onChange(of: vm.isHovering) { _ in updateSize() }
        .onChange(of: vm.expanded) { _ in updateSize() }
        .onChange(of: vm.notchSize) { _ in updateSize() }
        .onChange(of: shelf.items.count) { _ in updateSize() }
        .onChange(of: hidden) { _ in updateSize() }
        .onChange(of: music.now) { _ in syncDraggable(); updateSize() }
        .onChange(of: music.showing) { _ in syncDraggable(); updateSize() }
        .onChange(of: sensors.snapshot) { creature.apply($0) }
        .onChange(of: agents.table) { table in
            creature.setAgents(working: agents.anyWorking, waiting: agents.anyWaiting,
                               activity: table.activity)
            updateSize()
        }
        .onChange(of: vm.tapCount) { _ in
            // A click that opened the command line is not also a request to
            // jump to a session. The tap comes from an event monitor with no
            // idea which view was hit, so the field's own claim is what tells
            // it to stand down.
            guard !music.isShowing, !vm.wantsKeyboard else { return }
            // A click on the notch means "take me to whatever wants me" — the
            // session behind the exclamation eyes. Name the reason when there's
            // nothing to open; a click that silently does nothing reads as
            // broken, and "no window" is a different problem from "not found".
            guard !agents.focusCurrent() else { return }
            switch agents.table.focusTarget()?.destination {
            case .gateway:
                showToast("OpenClaw runs in the background — no window to open")
            case .terminal:
                showToast("That session's terminal has gone")
            case .unreachable:
                showToast("Nothing to open for that session")
            case nil:
                break                       // no sessions at all: stay quiet
            }
        }
        .onChange(of: vm.cycleSteps) { steps in
            let delta = steps - lastCycleStep
            lastCycleStep = steps
            // Never cycle out from under a caret: a trackpad twitch while
            // typing would otherwise throw away the half-written command.
            guard delta != 0, !music.isShowing, !hidden, !vm.wantsKeyboard else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                mode = mode.advanced(by: delta)
            }
        }
        .onChange(of: weather.snapshot) { _ in updateSize() }
        .onChange(of: commandLines) { _ in updateSize() }
        // The controller clears these on real playback drain, so the strip can
        // mirror them directly — it appears and goes exactly with the audio.
        .onChange(of: live.caption) { _ in updateSize() }
        .onChange(of: live.heard) { _ in updateSize() }
        .onChange(of: live.running) { running in
            creature.setLive(running)
            syncDraggable()
            updateSize()
        }
        .onChange(of: live.composing) { creature.setLiveThinking($0) }
        // Releasing the keyboard ends the summon: hand the notch back to
        // whatever it was showing before.
        .onChange(of: vm.wantsKeyboard) { wants in
            guard !wants, mode == .command else { return }
            let previous = modeBeforeSummon ?? .critter
            modeBeforeSummon = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { mode = previous }
        }
        .onChange(of: mode) { m in
            // Never persist the summoned mode — resuming into it is the bug.
            if m != .command { UserDefaults.standard.set(m.rawValue, forKey: "nookMode") }
            // Components that poll only do so while they're the one showing.
            weather.setActive(m == .weather)
            stats.setActive(m == .stats)
            // Leaving command mode gives the keyboard back even if the field
            // never saw its own teardown.
            if m != .command, vm.wantsKeyboard { vm.wantsKeyboard = false }
            syncDraggable()
            updateSize()
        }
        // No `onChange(of: stats.snapshot)`: the stats panel is a fixed size
        // whatever the numbers say, and re-laying out the window twice a
        // second to discover that would be pure churn.
        .onReceive(live.audio.$currentSpeakerAmplitude) { creature.setVoice(level: $0) }
        .onAppear {
            syncDraggable(); updateSize(); creature.apply(sensors.snapshot)
            lastCycleStep = vm.cycleSteps
            if mode == .weather { weather.setActive(true) }
            if mode == .stats { stats.setActive(true) }
            live.ompCwdProvider = { agents.table.focusTarget()?.cwd }
            // The typed command line routes "fix this" the same way the voice
            // session does — to the most actionable session's repo.
            commands.agentCwdProvider = { agents.table.focusTarget()?.cwd }
            live.externalActivity = { id, state in agents.noteExternal(id: id, state: state) }
            // A command typed at the notch is the same kind of thing as one
            // spoken at it: same ember, same row in the session list, same
            // click-to-open. Without this the typed path was the one piece of
            // work Kweku did that Kweku didn't show.
            commands.externalActivity = { id, state in agents.noteExternal(id: id, state: state) }
            // A stalled agent is only visible to someone looking at the panel.
            // When a Live session is open, say it instead — `interject` is a
            // no-op when there isn't one, or when Kweku is already talking.
            agents.onAttention = { prompt in live.interject(prompt) }
            // ⌥⌘K starts and stops Live from anywhere, so opening a session
            // doesn't mean finding the notch and right-clicking it first. Same
            // path as the menu item, key prompt included. The manager ignores a
            // repeat, so this is safe if the view reappears.
            HotKeyManager.shared.register(.toggleLive) { [live] in
                if live.running { live.stop() } else { self.startLive() }
            }
            // ⌥Space drops the caret into the notch from whatever app you're
            // in. It switches modes first: summoning a text box that then
            // isn't showing would be worse than no shortcut at all.
            HotKeyManager.shared.register(.summonCommand) { summonCommand() }
        }
        .contextMenu { menu }
    }

    // MARK: - Mode stacks

    private var critterStack: some View {
        VStack(spacing: 0) {
            CreatureView(state: creature, vm: vm, rim: rim)
                .frame(height: vm.notchSize.height + CreatureView.peek)
                .opacity(hidden ? 0 : 1)
            strips
        }
    }

    private var weatherStack: some View {
        VStack(spacing: 0) {
            WeatherView(weather: weather, vm: vm, rim: rim)
                .frame(height: vm.notchSize.height + weatherBody)
            strips
        }
    }

    private var agentStack: some View {
        VStack(spacing: 0) {
            AgentModeView(agents: agents, vm: vm, rim: rim)
                .frame(height: vm.notchSize.height + agentModeBody)
            strips
        }
    }

    /// A running session takes the nook over — it outranks even the music
    /// island, because a voice conversation is something you're doing and the
    /// island is something happening in the background. The island comes back
    /// the moment the session ends.
    private var liveStack: some View {
        VStack(spacing: 0) {
            LiveModeView(live: live, audio: live.audio, vm: vm, rim: rim)
                .frame(height: vm.notchSize.height + liveBody)
            strips
        }
    }

    private var statsStack: some View {
        VStack(spacing: 0) {
            StatsView(stats: stats, vm: vm, rim: rim)
                .frame(height: vm.notchSize.height + body(for: .stats))
            strips
        }
    }

    private var commandStack: some View {
        VStack(spacing: 0) {
            CommandView(commands: commands, vm: vm, critter: creature, rim: rim,
                        summon: commandSummon, editorLines: $commandLines,
                        onOpenSession: { agents.focusCurrent() })
                .frame(height: vm.notchSize.height + body(for: .command))
            strips
        }
    }

    /// Spotify island with the mode's strips (agent panel, captions, shelf)
    /// stacked under it when open — so music and agents show at once. The
    /// critter rides in the island's collapsed wing.
    private var musicStack: some View {
        VStack(spacing: 0) {
            NowPlayingView(music: music, vm: vm, rim: rim, critter: creature)
                .frame(height: vm.notchSize.height + musicBody)
            strips
        }
    }

    /// The stack of optional strips that hang under whichever mode is showing.
    /// Drop targets replace the rest while a drag is armed — mid-drag is no
    /// time to be reading captions.
    @ViewBuilder
    private var strips: some View {
        if showDropTargets {
            DropTargetsView(shelf: shelf,
                            agentCwd: { agents.table.focusTarget()?.cwd },
                            onDispatch: showToast)
                .transition(.opacity)
        } else {
            if showAgentPanel {
                AgentPanelView(agents: agents).transition(.opacity)
            }
            if showCaptions {
                LiveCaptionView(heard: live.heard, spoken: live.caption, level: creature.voiceLevel)
                    .transition(.opacity)
            }
            if showShelf {
                ShelfView(store: shelf).transition(.opacity)
            }
            // Last, so it sits on the bottom edge: the thing you reach *down*
            // to, under whatever you came to read.
            if showCommandPrompt {
                CommandPromptStrip(busy: commands.state.isBusy,
                                   label: commands.state.progressLabel,
                                   onOpen: summonCommand)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var toastLabel: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Open the command line: ⌥Space from anywhere, or a click on the prompt.
    ///
    /// The mode change is *borrowed*. `modeBeforeSummon` is what the notch goes
    /// back to when the keyboard is released, so a summon can never leave the
    /// notch as a text box — which is what it did when this simply set the
    /// mode and the mode was persisted.
    private func summonCommand() {
        // A running Live session owns the nook; summoning a field it would
        // draw over is worse than the shortcut doing nothing.
        guard !hidden, !live.running else { return }
        // Read the front app *first*. Claiming the keyboard makes Kweku's
        // panel key, and after that "the app you were in" is no longer a
        // question the system can answer.
        commands.captureContext()
        // Then activate. A `.nonactivatingPanel` will report itself key and
        // hold first responder while the window server goes on delivering
        // every keystroke to the app that was in front — the panel looked
        // focused and typing went to Finder. Only becoming the active app
        // actually gets the keys. Kweku is an accessory with no menu bar, so
        // this costs no visible chrome, and the front app is handed back on
        // close.
        NSApp.activate(ignoringOtherApps: true)
        if mode != .command {
            modeBeforeSummon = mode
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { mode = .command }
        }
        // Claim the keyboard here rather than inside the panel: while the
        // island is showing, the panel isn't on screen to claim it for itself,
        // and the claim is what puts it there.
        vm.wantsKeyboard = true
        commandSummon += 1
    }

    private func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    /// The creature may be dragged along the notch; panels with controls in
    /// them — the music island's scrubber, the Live panel's mic meter and
    /// buttons — must never move the window instead of taking the click.
    private func syncDraggable() {
        let draggable = !music.isShowing && !live.running && mode != .command
        if vm.contentDraggable != draggable { vm.contentDraggable = draggable }
    }

    // MARK: - Sizing

    /// The live facts a component's size may depend on.
    private var nookContext: NookContext {
        NookContext(agentCount: agents.table.count, commandLines: commandLines)
    }

    /// Body height a mode wants right now, in the current open state.
    private func body(for mode: NookMode) -> CGFloat {
        mode.metrics(nookContext).body(open: open)
    }

    private var weatherBody: CGFloat { body(for: .weather) }
    private var agentModeBody: CGFloat { body(for: .agents) }
    private var musicBody: CGFloat { open ? NowPlayingView.expandedBody : NowPlayingView.lip }
    private var liveMetrics: NookMetrics { LiveModeView.metrics(nookContext) }
    private var liveBody: CGFloat { liveMetrics.body(open: open) }

    /// Everything hanging below the mode body, in stacking order. Drop targets
    /// replace the rest while a drag is armed, matching `strips`.
    private var stripMetrics: [NookLayout.Strip] {
        if showDropTargets {
            return [.init(height: DropTargetsView.bodyHeight,
                          minWidth: DropTargetsView.expandedWidth)]
        }
        var strips: [NookLayout.Strip] = []
        if showAgentPanel {
            strips.append(.init(height: AgentPanelFormat.bodyHeight(for: agents.table.count),
                                minWidth: AgentPanelView.expandedWidth))
        }
        if showCaptions {
            strips.append(.init(height: LiveCaptionView.bodyHeight,
                                minWidth: LiveCaptionView.expandedWidth))
        }
        if showShelf {
            strips.append(.init(height: shelfPanelHeight, minWidth: shelfPanelWidth))
        }
        if showCommandPrompt {
            strips.append(.init(height: CommandPromptStrip.bodyHeight,
                                minWidth: CommandPromptStrip.expandedWidth))
        }
        return strips
    }

    private func updateSize() {
        let base = vm.notchSize
        guard base != .zero else { return }

        // Same precedence as the body: a running session, then the island,
        // then whichever mode is selected.
        guard !live.running else {
            vm.desiredSize = NookLayout.size(base: base, metrics: liveMetrics,
                                             open: open, strips: stripMetrics)
            return
        }

        guard !music.isShowing || commandTakeover else {
            // The island is its own layout: it *contains* the cutout rather
            // than hanging below it, so it doesn't go through NookLayout.
            var width: CGFloat
            var height: CGFloat
            if open {
                width = NowPlayingView.expandedWidth
                height = base.height + NowPlayingView.expandedBody
            } else {
                // Notch grows sideways: art | cutout | critter, cutout height.
                width = base.width + 2 * NowPlayingView.wing
                height = base.height + NowPlayingView.lip
            }
            for strip in stripMetrics {
                width = max(width, strip.minWidth)
                height += strip.height
            }
            vm.desiredSize = CGSize(width: width, height: height)
            return
        }

        vm.desiredSize = NookLayout.size(base: base, mode: mode, open: open,
                                         context: nookContext, strips: stripMetrics)
    }

    /// Small modal for the manual-city fallback (spec: CoreLocation with a
    /// manual city fallback). Only reachable from the Weather menu.
    private func promptForCity() {
        let alert = NSAlert()
        alert.messageText = "Weather location"
        alert.informativeText = "Enter a city for Kweku's weather."
        let field = EditableTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. Grand Rapids"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task { await weather.setManualCity(name) }
    }

    private func startLive() {
        if LiveSessionController.apiKey == nil { promptForGeminiKey() }
        guard LiveSessionController.apiKey != nil else { return }
        live.start()
    }

    private func promptForGeminiKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API key"
        alert.informativeText = "Used only for Kweku Live (voice + screen). Stored in app preferences."
        let field = EditableSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "AIza…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { LiveSessionController.storeAPIKey(key) }
    }

    @ViewBuilder private var menu: some View {
        // Built from the component list, so a new component appears in the
        // menu and the scroll cycle from the same one-line registration.
        ForEach(NookMode.cycle, id: \.self) { item in
            Button(action: { mode = item }) {
                Label(item.title, systemImage: mode == item ? "checkmark" : "")
            }
        }
        if mode == .weather {
            Button("Set City…") { promptForCity() }
        }
        Button(hidden ? "Show" : "Hide") { hidden.toggle() }
        // The shelf's own escape hatch. Per-item Remove needs you to hover the
        // notch and hit a 40pt thumbnail; this always reaches, and it's the
        // only way out when an item's thumbnail won't render.
        if !shelf.items.isEmpty {
            Button("Clear Shelf (\(shelf.items.count))", role: .destructive) { shelf.clear() }
        }
        Divider()
        if live.running {
            Button("Stop Kweku Live") { live.stop() }
        } else {
            Button("Start Kweku Live") { startLive() }
        }
        if !live.status.isEmpty {
            Button("Live: \(live.status)") {}.disabled(true)
        }
        Button("Set Gemini API Key…") { promptForGeminiKey() }
        Button("Forget Conversations") { live.forgetConversations() }
        Button("Forget Screen History") { live.forgetScreenHistory() }
        Divider()
        Button(action: { agents.runSetup() }) {
            Label("Set Up Agent Watch", systemImage: agents.setupDone ? "checkmark" : "")
        }
        Divider()
        Button("Enter licence key…") {}.disabled(true)
        Divider()
        Button("Quit Kweku") { NSApp.terminate(nil) }
    }
}
