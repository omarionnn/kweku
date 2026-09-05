import SwiftUI
import AppKit


/// What lives in the nook when music isn't playing. Scrolling over the notch
/// steps through these in order.
public enum NookMode: String, CaseIterable {
    case critter, weather, agents

    /// The mode `step` places away, wrapping in both directions.
    public func advanced(by step: Int) -> NookMode {
        let all = NookMode.allCases
        guard let index = all.firstIndex(of: self) else { return .critter }
        let n = all.count
        return all[((index + step) % n + n) % n]
    }
}

/// Top-level content injected into the notch window. Owns the creature, shelf,
/// sensor and music models; handles drops and the right-click menu. Each mode
/// (creature+shelf, weather, agents, Spotify) is a self-contained view that
/// draws the shared `NotchPanelShape` as its own seamless background and
/// strokes a `NotchRim` over it for ambient state.
struct NotchContentRoot: View {
    @ObservedObject var vm: NotchViewModel
    @StateObject private var creature: CreatureState
    @StateObject private var shelf = ShelfStore()
    @StateObject private var sensors: SensorHub
    @StateObject private var music = MusicHub()
    @StateObject private var agents = AgentWatchHub()
    @StateObject private var weather = WeatherHub()
    @StateObject private var live = LiveSessionController()

    @State private var isTargeted = false
    @State private var hidden = false
    @State private var mode: NookMode =
        NookMode(rawValue: UserDefaults.standard.string(forKey: "nookMode") ?? "") ?? .critter
    /// Last `vm.cycleSteps` value applied, so scroll flips are diffed rather
    /// than counted — a dropped update can't desynchronise the mode.
    @State private var lastCycleStep = 0
    /// Transient confirmation after a drop is dispatched.
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?

    private let shelfPanelHeight: CGFloat = 66
    private let shelfPanelWidth: CGFloat = 200

    init(viewModel: NotchViewModel) {
        _vm = ObservedObject(wrappedValue: viewModel)
        _creature = StateObject(wrappedValue: CreatureState(viewModel: viewModel))
        _sensors = StateObject(wrappedValue: SensorHub(viewModel: viewModel))
    }

    private var open: Bool { vm.isHovering || vm.expanded }
    private var showShelf: Bool { !hidden && !shelf.items.isEmpty && open && !vm.expanded }
    /// A drag is armed: offer the drop destinations instead of the usual body.
    private var showDropTargets: Bool { !hidden && vm.expanded && !music.isShowing }
    /// The hover-reveal session list, offered in critter mode as well as its
    /// own mode — it's the thing most worth surfacing when you look at Kweku.
    private var showAgentPanel: Bool {
        !hidden && mode == .critter && open && !vm.expanded && agents.table.count > 0
    }
    private var showCaptions: Bool {
        !hidden && live.running && !(live.caption.isEmpty && live.heard.isEmpty)
    }

    /// One ambient signal on the rim at a time, most urgent first.
    private var rim: NotchRimStyle {
        NotchRimStyle.resolve(attention: creature.agentWaiting,
                              live: live.running,
                              voiceLevel: creature.voiceLevel,
                              working: creature.agentWorking)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if music.isShowing {
                NowPlayingView(music: music, vm: vm, rim: rim)
            } else if mode == .weather && !hidden {
                weatherStack
            } else if mode == .agents && !hidden {
                agentStack
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
        .onChange(of: music.enabled) { _ in syncDraggable(); updateSize() }
        .onChange(of: sensors.snapshot) { creature.apply($0) }
        .onChange(of: agents.table) { _ in
            creature.setAgents(working: agents.anyWorking, waiting: agents.anyWaiting)
            updateSize()
        }
        .onChange(of: vm.tapCount) { _ in
            if !music.isShowing { agents.focusCurrent() }
        }
        .onChange(of: vm.cycleSteps) { steps in
            let delta = steps - lastCycleStep
            lastCycleStep = steps
            guard delta != 0, !music.isShowing, !hidden else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                mode = mode.advanced(by: delta)
            }
        }
        .onChange(of: weather.snapshot) { _ in updateSize() }
        // The controller clears these on real playback drain, so the strip can
        // mirror them directly — it appears and goes exactly with the audio.
        .onChange(of: live.caption) { _ in updateSize() }
        .onChange(of: live.heard) { _ in updateSize() }
        .onChange(of: live.running) { running in
            creature.setLive(running)
            updateSize()
        }
        .onChange(of: mode) { m in
            UserDefaults.standard.set(m.rawValue, forKey: "nookMode")
            weather.setActive(m == .weather)
            updateSize()
        }
        .onReceive(live.audio.$currentSpeakerAmplitude) { creature.setVoice(level: $0) }
        .onAppear {
            syncDraggable(); updateSize(); creature.apply(sensors.snapshot)
            lastCycleStep = vm.cycleSteps
            if mode == .weather { weather.setActive(true) }
            live.ompCwdProvider = { agents.table.focusTarget()?.cwd }
            live.externalActivity = { id, state in agents.noteExternal(id: id, state: state) }
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

    private func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    /// The creature may be dragged along the notch; the music island (with its
    /// scrubber and buttons) must never move the window.
    private func syncDraggable() {
        let draggable = !music.isShowing
        if vm.contentDraggable != draggable { vm.contentDraggable = draggable }
    }

    // MARK: - Sizing

    private var weatherBody: CGFloat { open ? WeatherView.expandedBody : WeatherView.peek }
    private var agentModeBody: CGFloat {
        open ? AgentModeView.expandedBody(for: agents.table.count) : AgentModeView.peek
    }

    private func updateSize() {
        let base = vm.notchSize
        guard base != .zero else { return }
        var width = base.width
        var height = base.height

        if music.isShowing {
            if open {
                width = NowPlayingView.expandedWidth
                height = base.height + NowPlayingView.expandedBody
            } else {
                // Notch grows sideways: art | cutout | equalizer, cutout height.
                width = base.width + 2 * NowPlayingView.wing
                height = base.height + NowPlayingView.lip
            }
            vm.desiredSize = CGSize(width: width, height: height)
            return
        }

        switch mode {
        case .critter:
            height += CreatureView.peek
        case .weather:
            height += weatherBody
            if open { width = max(width, WeatherView.expandedWidth) }
        case .agents:
            height += agentModeBody
            if open { width = max(width, AgentModeView.expandedWidth) }
        }

        // Strips below the mode body.
        if showDropTargets {
            width = max(width, DropTargetsView.expandedWidth)
            height += DropTargetsView.bodyHeight
        } else {
            if showAgentPanel {
                width = max(width, AgentPanelView.expandedWidth)
                height += AgentPanelFormat.bodyHeight(for: agents.table.count)
            }
            if showCaptions {
                width = max(width, LiveCaptionView.expandedWidth)
                height += LiveCaptionView.bodyHeight
            }
            if showShelf {
                width = max(width, shelfPanelWidth)
                height += shelfPanelHeight
            }
        }
        vm.desiredSize = CGSize(width: width, height: height)
    }

    /// Small modal for the manual-city fallback (spec: CoreLocation with a
    /// manual city fallback). Only reachable from the Weather menu.
    private func promptForCity() {
        let alert = NSAlert()
        alert.messageText = "Weather location"
        alert.informativeText = "Enter a city for Kweku's weather."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
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
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
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
        Button(action: { mode = .critter }) {
            Label("Critter", systemImage: mode == .critter ? "checkmark" : "")
        }
        Button(action: { mode = .weather }) {
            Label("Weather", systemImage: mode == .weather ? "checkmark" : "")
        }
        Button(action: { mode = .agents }) {
            Label("Agents", systemImage: mode == .agents ? "checkmark" : "")
        }
        if mode == .weather {
            Button("Set City…") { promptForCity() }
        }
        Button(action: { music.setEnabled(!music.enabled) }) {
            Label("Music — Spotify", systemImage: music.enabled ? "checkmark" : "")
        }
        Button(hidden ? "Show" : "Hide") { hidden.toggle() }
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
