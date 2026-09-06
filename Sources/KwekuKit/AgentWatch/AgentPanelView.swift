import SwiftUI

/// Pure labels and sizing for the agent panel (unit-tested).
public enum AgentPanelFormat {
    /// Rows shown before the list collapses into a "+N more" line.
    public static let maxRows = 4
    public static let rowHeight: CGFloat = 30

    /// Height the panel needs for `count` sessions, including padding.
    public static func bodyHeight(for count: Int) -> CGFloat {
        let rows = min(count, maxRows) + (count > maxRows ? 1 : 0)
        return CGFloat(rows) * rowHeight + 14
    }

    /// Compact "time in this state" label.
    public static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// The row's identity line: which harness, and the terminal app it lives
    /// in when there is one — "omp · Terminal", "claude · iTerm2", "openclaw".
    public static func identity(source: String, app: String?) -> String {
        guard let app, !app.isEmpty else { return source }
        return "\(source) · \(app)"
    }

    /// The collapsed band's summary, e.g. "3 agents · 1 waiting".
    public static func summary(total: Int, waiting: Int) -> String {
        let head = total == 1 ? "1 agent" : "\(total) agents"
        return waiting > 0 ? "\(head) · \(waiting) waiting" : head
    }
}

/// Agents mode: the nook is given over to the session list.
///
/// Collapsed it's a one-line summary in the band below the cutout; hovering
/// expands it into the full list. Same shape-owns-its-own-background pattern as
/// `WeatherView`.
struct AgentModeView: View {
    @ObservedObject var agents: AgentWatchHub
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle

    static let peek: CGFloat = 30
    static let expandedWidth = AgentPanelView.expandedWidth

    static func expandedBody(for count: Int) -> CGFloat {
        max(AgentPanelFormat.bodyHeight(for: count), 44)
    }

    private var expanded: Bool { vm.isHovering || vm.expanded }

    var body: some View {
        let cutoutH = vm.notchSize.height
        let bodyH = expanded ? Self.expandedBody(for: agents.table.count) : Self.peek

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
                    Group {
                        if expanded {
                            AnyView(AgentPanelView(agents: agents))
                        } else {
                            AnyView(AgentBandView(agents: agents))
                        }
                    }
                    .frame(width: w, height: bodyH)
                    .offset(y: cutoutH)
                }
                .frame(width: w, height: cutoutH + bodyH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The agent session list — one row per tracked coding-agent session, with a
/// state dot, the repo it's running in, how long it's been in that state, and
/// click-to-focus on its terminal.
///
/// The elapsed labels tick from a `TimelineView` rather than a stored timer, so
/// nothing runs while the panel is off-screen.
struct AgentPanelView: View {
    @ObservedObject var agents: AgentWatchHub

    static let expandedWidth: CGFloat = 300

    var body: some View {
        let sessions = agents.table.ordered
        let shown = Array(sessions.prefix(AgentPanelFormat.maxRows))
        let hidden = sessions.count - shown.count

        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown, id: \.id) { session in
                    row(session, now: context.date)
                }
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(height: AgentPanelFormat.rowHeight, alignment: .leading)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ session: AgentSession, now: Date) -> some View {
        Button { agents.focus(session) } label: {
            HStack(spacing: 8) {
                dot(for: session)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1).truncationMode(.middle)
                        // What it's doing right now, in the phase's own colour
                        // — the detail the rim can only gesture at.
                        if let label = session.activityLabel {
                            Text(label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(AgentPanelView.tint(session).opacity(0.85))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    // Who this is and where it lives — the line that tells
                    // three concurrent harnesses apart at a glance.
                    Text(AgentPanelFormat.identity(source: session.sourceLabel,
                                                   app: TerminalFocus.owningAppName(of: session.pid)))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(AgentPanelFormat.elapsed(since: session.stateSince, now: now))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .frame(height: AgentPanelFormat.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func dot(for session: AgentSession) -> some View {
        switch session.state {
        case .working:
            // Breathing in the phase's colour while the agent has the floor.
            PulsingDot(color: Self.tint(session))
        case .waiting:
            Circle().fill(Self.ready).frame(width: 6, height: 6)
        case .idle:
            Circle().fill(Color.white.opacity(0.22)).frame(width: 6, height: 6)
        }
    }

    /// The colour standing for a session's phase — the same palette the rim
    /// wears, so panel and outline never disagree about what's going on.
    static func tint(_ session: AgentSession) -> Color {
        switch session.state {
        case .waiting: return ready
        case .idle:    return .white.opacity(0.22)
        case .working:
            switch session.activity {
            case .tooling:       return NotchRim.amber
            case .responding:    return NotchRim.teal
            case .thinking, nil: return NotchRim.violet
            }
        }
    }

    /// Finished, and the ball is in your court.
    static let ready = Color(red: 0.42, green: 0.83, blue: 0.55)

    /// Compact "time in this state" label (pure — unit-tested).
    public static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

/// A dot that breathes. Split out so the animation state belongs to the dot and
/// not to the row that rebuilds every second.
private struct PulsingDot: View {
    var color: Color
    @State private var big = false

    var body: some View {
        Circle().fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(big ? 1.35 : 0.8)
            .opacity(big ? 1 : 0.5)
            .onAppear {
                big = false
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    big = true
                }
            }
    }
}

/// The collapsed one-line summary shown in the band below the cutout while
/// agents mode is *not* hover-expanded.
struct AgentBandView: View {
    @ObservedObject var agents: AgentWatchHub

    var body: some View {
        let sessions = agents.table.ordered
        HStack(spacing: 7) {
            if sessions.isEmpty {
                Image(systemName: "terminal")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                Text("no agents")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(sessions.prefix(4), id: \.id) { session in
                    Circle().fill(AgentPanelView.tint(session)).frame(width: 5, height: 5)
                }
                Text(summary(sessions))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }

    private func summary(_ sessions: [AgentSession]) -> String {
        AgentPanelFormat.summary(total: sessions.count,
                                 waiting: sessions.filter { $0.state == .waiting }.count)
    }
}
