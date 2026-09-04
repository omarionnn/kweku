import Foundation

/// One tracked coding-agent session.
public struct AgentSession: Equatable, Sendable {
    public var id: String
    public var cwd: String
    public var pid: Int32
    public var state: AgentState
    public var lastUpdated: Date
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
            state: event.state, lastUpdated: now)
        s.state = event.state
        s.lastUpdated = now
        if !event.cwd.isEmpty { s.cwd = event.cwd }
        if event.pid > 0 { s.pid = event.pid }
        sessions[event.sessionID] = s
    }

    public var anyWorking: Bool { sessions.values.contains { $0.state == .working } }
    public var anyWaiting: Bool { sessions.values.contains { $0.state == .waiting } }
    public var count: Int { sessions.count }

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
