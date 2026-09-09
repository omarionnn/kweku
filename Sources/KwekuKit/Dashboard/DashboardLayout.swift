import CoreGraphics

/// Sizing for the nook dashboard: every component on at once, one enlarged.
///
/// The old nook showed one component at a time and you scrolled between them,
/// which meant three of the four things Kweku knows were always a gesture away
/// and therefore usually unread. Now they're all on — as one line each — and
/// whichever you point at unfolds into the panel it always had.
///
/// `NookMode` is unchanged and still does the choosing; it just chooses which
/// row is *enlarged* rather than which component exists. `.critter` means none
/// of them is — the resting state, four lines and a face. Scrolling, the menu
/// and the persisted preference all keep working because none of them had to
/// learn a new idea.
public enum DashboardLayout {
    /// Wide enough for the enlarged forms, which run to 320pt on their own,
    /// and matched to the command panel so the notch has one open width.
    public static let width: CGFloat = 420
    /// The face band directly under the cutout. Same height it has always had.
    public static let band: CGFloat = 30
    /// One collapsed row.
    public static let line: CGFloat = 26
    /// The `ask Kweku` line at the bottom. Always last, never enlarges — it's
    /// an action, and its enlarged form is the command panel taking the notch
    /// over entirely.
    public static let footer: CGFloat = 26
    /// Breathing room at the bottom of the open panel.
    public static let padding: CGFloat = 8

    /// The enlargeable rows, in display order: coldest to most personal.
    /// Weather is the thing you glance at, agents the thing you act on, and
    /// system the thing you check when something feels wrong.
    public static let rows: [NookMode] = [.weather, .agents, .stats]

    /// Height of a row when it is the enlarged one.
    ///
    /// These are the components' own `expandedBody` numbers, so an enlarged
    /// row is exactly the panel that component has always drawn — not a
    /// reduced version of it.
    public static func enlarged(_ row: NookMode, agentCount: Int) -> CGFloat {
        switch row {
        case .weather: return WeatherView.expandedBody
        case .stats:   return StatsView.expandedBody
        case .agents:  return max(AgentPanelFormat.bodyHeight(for: agentCount), line)
        case .critter, .command: return line
        }
    }

    /// Body height with the notch open. `enlarged` is `.critter` when nothing
    /// is pointed at, which is four plain lines.
    public static func openBody(enlarged: NookMode, agentCount: Int) -> CGFloat {
        let stack = rows.reduce(CGFloat(0)) { total, row in
            total + (row == enlarged ? self.enlarged(row, agentCount: agentCount) : line)
        }
        return band + stack + footer + padding
    }

    /// Body height with the notch closed: the face band, and nothing else.
    public static let closedBody: CGFloat = band
}

/// The one fact the closed notch is allowed to carry beside the face.
///
/// Deliberately thin. There is room for the critter and about seventy points
/// beside it, and a band that always says something is a band you stop
/// reading. It also only reports things Kweku knows *for free*: agent state
/// arrives by socket, where weather and system have to be polled, and polling
/// while nobody is looking is the battery bug the hubs were written to avoid.
public enum DashboardStatus {
    public static func line(agents: Int, waiting: Int) -> String? {
        guard agents > 0 else { return nil }
        if waiting > 0 { return "\(waiting) waiting" }
        return agents == 1 ? "1 agent" : "\(agents) agents"
    }
}
