import Foundation

/// Where a session actually lives, and so what "take me there" has to do.
/// Not every waiting session is a terminal window: the synthetic entries fed
/// in by `AgentWatchHub.noteExternal` are gateway conversations with no
/// process behind them, and walking a process tree from their `pid` of 0 can
/// only ever fail.
public enum AgentDestination: Equatable, Sendable {
    /// A live process whose owning terminal window can be raised.
    case terminal(pid: Int32)
    /// An OpenClaw gateway session — open the Control UI instead.
    case gateway
    /// Nothing to open: the process is gone and it isn't a gateway session.
    case unreachable
}

/// One tracked coding-agent session.
public struct AgentSession: Equatable, Sendable {
    public var id: String
    public var cwd: String
    public var pid: Int32
    public var state: AgentState
    /// Time of the last event of any kind — drives display order.
    public var lastUpdated: Date
    /// Time this session entered its current `state`. Separate from
    /// `lastUpdated` so the panel's "how long has it been busy" reading isn't
    /// reset every time a tool starts within the same working turn.
    public var stateSince: Date
    /// What this session is spending its turn on; nil unless it's working.
    public var activity: AgentActivity?
    /// Tool in flight, when `activity == .tooling`.
    public var tool: String?

    /// The row label for the session's current phase, e.g. "Bash", "thinking".
    public var activityLabel: String? {
        switch activity {
        case .tooling:    return tool ?? "running a tool"
        case .thinking:   return "thinking"
        case .responding: return "answering"
        case nil:         return nil
        }
    }

    /// Identifier the hub uses for the synthetic OpenClaw session.
    public static let gatewayID = "openclaw"

    /// What a click on this session should do. Pure, so the routing is
    /// testable without a process table or a browser.
    public var destination: AgentDestination {
        if pid > 0 { return .terminal(pid: pid) }
        if id == Self.gatewayID { return .gateway }
        return .unreachable
    }

    /// Label for the agent panel: the repo/folder the session runs in. The
    /// synthetic sessions fed in by `AgentWatchHub.noteExternal` carry no cwd,
    /// so they fall back to a titled form of their id.
    public var displayName: String {
        if !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        if id == Self.gatewayID { return "OpenClaw" }
        return String(id.prefix(8))
    }
}

/// Pure session bookkeeping (unit-tested): apply events, expose the aggregate
/// signals the creature reacts to, choose the click-to-focus target, prune
/// dead sessions.
public struct AgentSessionTable: Equatable {
    public private(set) var sessions: [String: AgentSession] = [:]

    public init() {}

    public mutating func apply(_ event: AgentEvent, at now: Date = Date()) {
        if event.gone {
            sessions[event.sessionID] = nil
            return
        }
        var s = sessions[event.sessionID] ?? AgentSession(
            id: event.sessionID, cwd: event.cwd, pid: event.pid,
            state: event.state, lastUpdated: now, stateSince: now)
        if s.state != event.state { s.stateSince = now }
        s.state = event.state
        s.lastUpdated = now
        // Emitters that report coarse state only (the omp extension) send
        // `working` with no activity; read that as thinking rather than as
        // "unknown", so the rim always has something calm to show.
        s.activity = event.activity ?? (event.state == .working ? .thinking : nil)
        s.tool = event.tool
        if !event.cwd.isEmpty { s.cwd = event.cwd }
        if event.pid > 0 { s.pid = event.pid }
        sessions[event.sessionID] = s
    }

    public var anyWorking: Bool { sessions.values.contains { $0.state == .working } }
    public var anyWaiting: Bool { sessions.values.contains { $0.state == .waiting } }
    public var count: Int { sessions.count }

    /// The activity the notch should wear: what the most salient working
    /// session is doing. Ranked rather than newest-first so that two agents
    /// trading events can't make the rim flicker between phases.
    public var activity: AgentActivity? {
        sessions.values
            .filter { $0.state == .working }
            .compactMap(\.activity)
            .min { $0.rank < $1.rank }
    }

    /// Name of the tool behind a `.tooling` rim, for the panel's row label.
    public var activeTool: String? {
        guard activity == .tooling else { return nil }
        return sessions.values
            .filter { $0.state == .working && $0.activity == .tooling }
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .first?.tool
    }

    /// Display order for the agent panel: the sessions that want the user
    /// first, then the busy ones, then the rest — each group newest-first.
    /// `focusTarget()` is always this list's head.
    public var ordered: [AgentSession] {
        func rank(_ s: AgentSession) -> Int {
            switch s.state {
            case .waiting: return 0
            case .working: return 1
            case .idle: return 2
            }
        }
        return sessions.values.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.lastUpdated > $1.lastUpdated
        }
    }

    /// The session a click should focus: the most recently updated *waiting*
    /// session (it needs the user), else the most recent working one, else
    /// the most recent of any.
    public func focusTarget() -> AgentSession? {
        let all = sessions.values
        let byRecency: (AgentSession, AgentSession) -> Bool = { $0.lastUpdated > $1.lastUpdated }
        return all.filter { $0.state == .waiting }.sorted(by: byRecency).first
            ?? all.filter { $0.state == .working }.sorted(by: byRecency).first
            ?? all.sorted(by: byRecency).first
    }

    /// Remove sessions whose process died or that went silent for too long.
    public mutating func prune(isAlive: (Int32) -> Bool,
                               now: Date = Date(),
                               maxAge: TimeInterval = 3600) {
        sessions = sessions.filter { _, s in
            guard now.timeIntervalSince(s.lastUpdated) < maxAge else { return false }
            return s.pid <= 0 || isAlive(s.pid)
        }
    }
}
