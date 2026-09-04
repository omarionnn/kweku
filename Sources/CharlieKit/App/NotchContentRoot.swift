import SwiftUI
import AppKit

/// Top-level content injected into the notch window. Owns the creature, shelf,
/// sensor and music models; handles drops and the right-click menu. Each mode
/// (creature+shelf, Spotify) is a self-contained view that draws the shared
/// `NotchPanelShape` as its own seamless background.
struct NotchContentRoot: View {
    @ObservedObject var vm: NotchViewModel
    @StateObject private var creature: CreatureState
    @StateObject private var shelf = ShelfStore()
    @StateObject private var sensors: SensorHub
    @StateObject private var music = MusicHub()
    @StateObject private var agents = AgentWatchHub()

    @State private var isTargeted = false
    @State private var hidden = false

    private let shelfPanelHeight: CGFloat = 66
    private let shelfPanelWidth: CGFloat = 200

    init(viewModel: NotchViewModel) {
        _vm = ObservedObject(wrappedValue: viewModel)
        _creature = StateObject(wrappedValue: CreatureState(viewModel: viewModel))
        _sensors = StateObject(wrappedValue: SensorHub(viewModel: viewModel))
    }

    private var showShelf: Bool {
        !hidden && !shelf.items.isEmpty && (vm.isHovering || vm.expanded)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if music.isShowing {
                NowPlayingView(music: music, vm: vm)
            } else {
                VStack(spacing: 0) {
                    CreatureView(state: creature, vm: vm)
                        .frame(height: vm.notchSize.height + CreatureView.peek)
                        .opacity(hidden ? 0 : 1)
                    if showShelf {
                        ShelfView(store: shelf).transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        }
        .onChange(of: vm.tapCount) { _ in
            if !music.isShowing { agents.focusCurrent() }
        }
        .onAppear { syncDraggable(); updateSize(); creature.apply(sensors.snapshot) }
        .contextMenu { menu }
    }

    /// The creature may be dragged along the notch; the music island (with its
    /// scrubber and buttons) must never move the window.
    private func syncDraggable() {
        let draggable = !music.isShowing
        if vm.contentDraggable != draggable { vm.contentDraggable = draggable }
    }

    private func updateSize() {
        let base = vm.notchSize
        guard base != .zero else { return }
        var width = base.width
        var height = base.height + CreatureView.peek

        if music.isShowing {
            if vm.isHovering || vm.expanded {
                width = NowPlayingView.expandedWidth
                height = base.height + NowPlayingView.expandedBody
            } else {
                // Notch grows sideways: art | cutout | equalizer, cutout height.
                width = base.width + 2 * NowPlayingView.wing
                height = base.height + NowPlayingView.lip
            }
        } else if showShelf {
            width = max(width, shelfPanelWidth)
            height += shelfPanelHeight
        } else if vm.expanded {
            height = max(height, base.height * 3)
        }
        vm.desiredSize = CGSize(width: width, height: height)
    }

    @ViewBuilder private var menu: some View {
        Button { } label: { Label("Critter", systemImage: "checkmark") }
        Button("Weather") {}.disabled(true)
        Button(action: { music.setEnabled(!music.enabled) }) {
            Label("Music — Spotify", systemImage: music.enabled ? "checkmark" : "")
        }
        Button(hidden ? "Show" : "Hide") { hidden.toggle() }
        Divider()
        Button(action: { agents.runSetup() }) {
            Label("Set Up Agent Watch", systemImage: agents.setupDone ? "checkmark" : "")
        }
        Divider()
        Button("Enter licence key…") {}.disabled(true)
        Divider()
        Button("Quit Charlie") { NSApp.terminate(nil) }
    }
}
