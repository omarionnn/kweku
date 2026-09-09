import SwiftUI

/// The nook, with everything on at once.
///
/// Closed it is what it always was: the face, and at most one fact beside it.
/// Open it is a stack of one-line rows — weather, agents, system — with the
/// `ask Kweku` prompt underneath, and whichever row you point at unfolds into
/// the full panel that component has always drawn.
///
/// Rows, not a grid. Enlarging a tile in a grid has to reflow the row it sits
/// in, so the things you *weren't* pointing at move out from under the cursor;
/// a column only ever changes one height, and everything below it slides by a
/// predictable amount. Rows are also how the shelf and the agent panel already
/// stack, so the notch keeps one way of putting things under itself.
struct DashboardView: View {
    @ObservedObject var critter: CreatureState
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var weather: WeatherHub
    @ObservedObject var agents: AgentWatchHub
    @ObservedObject var stats: StatsHub
    @ObservedObject var commands: CommandHub
    var rim: NotchRimStyle
    /// Which row is enlarged. `.critter` is none of them.
    @Binding var enlarged: NookMode
    var onSummonCommand: () -> Void

    /// How long the cursor must rest on a row before it unfolds.
    ///
    /// Without it, crossing the stack to reach the bottom row unfolds and
    /// refolds every row on the way down, and the thing you were aiming at
    /// moves before you get there.
    private static let dwell: TimeInterval = 0.18

    @State private var reveal: CGFloat = 0
    @State private var contentIn = false
    @State private var hoverWork: DispatchWorkItem?
    @State private var collapseWork: DispatchWorkItem?

    private var open: Bool { vm.isHovering || vm.expanded }
    private var bodyHeight: CGFloat {
        open ? DashboardLayout.openBody(enlarged: enlarged, agentCount: agents.table.count)
             : DashboardLayout.closedBody
    }

    var body: some View {
        let cutoutH = vm.notchSize.height
        let notchW = vm.notchSize.width

        GeometryReader { proxy in
            let fullW = min(proxy.size.width, DashboardLayout.width)
            let panelW = notchW + (fullW - notchW) * reveal
            let panelH = DashboardLayout.closedBody
                + (bodyHeight - DashboardLayout.closedBody) * reveal

            ZStack(alignment: .top) {
                Color.clear
                ZStack(alignment: .top) {
                    NotchPanelShape(notchWidth: notchW, notchHeight: cutoutH,
                                    bottom: 12 + 10 * reveal)
                        .fill(Color.black)
                    NotchRim(notchWidth: notchW, notchHeight: cutoutH,
                             bottom: 12 + 10 * reveal, style: rim)
                    VStack(spacing: 0) {
                        faceBand(width: panelW)
                        if contentIn { rows }
                    }
                    .frame(width: panelW, height: panelH, alignment: .top)
                    .offset(y: cutoutH)
                }
                .frame(width: panelW, height: cutoutH + panelH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: open) { isOpen in isOpen ? openPanel() : collapsePanel() }
        .onAppear { if open { reveal = 1; contentIn = true } }
    }

    // MARK: - The face

    /// The critter keeps the band under the cutout in both states. It is not a
    /// row: it's the thing the rows hang off, and demoting it to one item of
    /// four would make the notch a widget with a mascot in it.
    private func faceBand(width: CGFloat) -> some View {
        ZStack {
            CritterFace(state: critter, vm: vm, showMotes: !contentIn)
                .frame(width: vm.notchSize.width, height: DashboardLayout.band)
            // Closed, one fact may sit beside the face — and only one Kweku
            // already knows without polling for it.
            if !contentIn, let status = DashboardStatus.line(agents: agents.table.count,
                                                             waiting: waitingCount) {
                HStack {
                    Spacer(minLength: 0)
                    Text(status)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(waitingCount > 0 ? NotchRim.amber : .white.opacity(0.45))
                        .lineLimit(1)
                        .padding(.trailing, 12)
                }
            }
        }
        .frame(width: width, height: DashboardLayout.band)
    }

    private var waitingCount: Int {
        agents.table.sessions.values.filter { $0.state == .waiting }.count
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(DashboardLayout.rows, id: \.self) { row in
                rowView(row)
            }
            footer
        }
        .padding(.bottom, DashboardLayout.padding)
    }

    @ViewBuilder
    private func rowView(_ row: NookMode) -> some View {
        let isEnlarged = row == enlarged
        VStack(alignment: .leading, spacing: 0) {
            if isEnlarged {
                enlargedBody(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: DashboardLayout.enlarged(row, agentCount: agents.table.count))
            } else {
                HStack(spacing: 0) {
                    line(row)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: DashboardLayout.line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // A hairline under every row but the last, so three lines read as
            // a list rather than as one paragraph of mixed numbers.
            Rectangle().fill(Color.white.opacity(isEnlarged ? 0.04 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in hover(row, inside: inside) }
    }

    @ViewBuilder
    private func line(_ row: NookMode) -> some View {
        switch row {
        case .weather:
            WeatherView(weather: weather, vm: vm, rim: .none).collapsedBand
        case .stats:
            StatsView(stats: stats, vm: vm, rim: .none).collapsedBand
        case .agents:
            agentsLine
        case .critter, .command:
            EmptyView()
        }
    }

    @ViewBuilder
    private func enlargedBody(_ row: NookMode) -> some View {
        switch row {
        case .weather:
            WeatherView(weather: weather, vm: vm, rim: .none).expandedPanel
        case .stats:
            StatsView(stats: stats, vm: vm, rim: .none).expandedPanel
        case .agents:
            AgentPanelView(agents: agents, vm: vm)
        case .critter, .command:
            EmptyView()
        }
    }

    /// The agents row has no `collapsedBand` of its own to borrow — the agents
    /// component is a list, and a list has no one-line form until you write
    /// one. This is it, and it's the same sentence the mode's own band uses.
    private var agentsLine: some View {
        HStack(spacing: 7) {
            Image(systemName: agents.anyWaiting ? "exclamationmark.circle.fill" : "cpu")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(agents.anyWaiting ? NotchRim.amber : .white.opacity(0.45))
            Text(agents.table.count == 0
                 ? "no sessions"
                 : AgentPanelFormat.summary(total: agents.table.count, waiting: waitingCount))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(agents.table.count == 0 ? 0.3 : 0.75))
                .lineLimit(1)
        }
    }

    /// Always last, never enlarges. Its enlarged form is the command panel
    /// taking the notch over, which is a different thing entirely.
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: commands.state.isBusy ? "circle.dotted" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(commands.state.isBusy ? NotchRim.amber : .white.opacity(0.4))
            Text(commands.state.progressLabel ?? "ask Kweku")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(commands.state.isBusy ? 0.8 : 0.5))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 10)
            Text("⌥Space")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.horizontal, 16)
        .frame(height: DashboardLayout.footer)
        .contentShape(Rectangle())
        // Opens on press, not release: the notch's own click handler runs off
        // an event monitor that can't see which view was hit, and claiming the
        // keyboard on the way down is what tells it to stand down.
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in })
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in onSummonCommand() }
        )
    }

    // MARK: - Hover

    private func hover(_ row: NookMode, inside: Bool) {
        hoverWork?.cancel()
        guard inside else { return }
        guard row != enlarged else { return }
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { enlarged = row }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
    }

    // MARK: - Open / close

    private func openPanel() {
        collapseWork?.cancel(); collapseWork = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { reveal = 1 }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) { contentIn = true }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func collapsePanel() {
        collapseWork?.cancel()
        hoverWork?.cancel()
        withAnimation(.easeIn(duration: 0.1)) { contentIn = false }
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.26, dampingFraction: 1)) { reveal = 0 }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
