import Foundation

/// State of one coding-agent session.
public enum AgentState: String, Codable, Sendable {
    case working   // agent is executing
    case waiting   // agent finished / needs the user
    case idle      // session open, nothing happening
}

/// One event received on the agent socket. Two wire formats are accepted:
///
/// Kweku's native line (emitted by the omp extension):
///   `{"v":1,"source":"omp","session_id":"123","cwd":"/x","pid":123,"state":"working"}`
///
/// Claude Code's hook payload (forwarded verbatim + `pid` added by the hook
/// command): `{"session_id":"...","cwd":"/x","hook_event_name":"Stop","pid":n}`
public struct AgentEvent: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String
    public var pid: Int32
    public var state: AgentState
    public var gone: Bool          // session ended; remove from the table

    public init(sessionID: String, cwd: String, pid: Int32, state: AgentState, gone: Bool = false) {
        self.sessionID = sessionID; self.cwd = cwd; self.pid = pid
        self.state = state; self.gone = gone
    }

    /// Parse one JSON line in either wire format. Returns nil on garbage.
    public static func parse(_ line: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let cwd = (obj["cwd"] as? String) ?? ""
        let pid = Int32((obj["pid"] as? Int) ?? Int((obj["pid"] as? String) ?? "") ?? 0)

        // Kweku native format.
        if let raw = obj["state"] as? String {
            guard let id = obj["session_id"] as? String else { return nil }
            if raw == "gone" {
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .idle, gone: true)
            }
            guard let state = AgentState(rawValue: raw) else { return nil }
            return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: state)
        }

        // Claude Code hook format.
        if let hook = obj["hook_event_name"] as? String {
            let id = (obj["session_id"] as? String) ?? String(pid)
            switch hook {
            case "SessionStart":  return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .idle)
            case "SubagentStop":  return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .working)
            case "Stop", "Notification":
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .waiting)
            case "SessionEnd":
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .idle, gone: true)
            default: return nil
            }
        }
        return nil
    }
}
