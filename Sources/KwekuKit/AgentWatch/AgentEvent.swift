import Foundation

/// State of one coding-agent session.
public enum AgentState: String, Codable, Sendable {
    case working   // agent is executing
    case waiting   // agent finished / needs the user
    case idle      // session open, nothing happening
}

/// How a *working* session is spending its turn. `state` says the agent has
/// the floor; `activity` says what it's doing with it — and the notch draws
/// each one differently, because "reasoning about your code" and "running
/// your build" have no business looking alike.
public enum AgentActivity: String, Codable, Sendable, CaseIterable {
    case thinking     // model is reasoning; nothing else in flight
    case tooling      // a tool call is executing
    case responding   // streaming an answer back

    /// Which activity wins when several sessions are working at once. The
    /// concrete, finite thing outranks the open-ended one: a tool call has a
    /// beginning and an end worth watching; thinking just continues.
    public var rank: Int {
        switch self {
        case .tooling:    return 0
        case .responding: return 1
        case .thinking:   return 2
        }
    }

    /// Best guess at an activity from an OpenClaw gateway status phase. The
    /// gateway's vocabulary isn't fixed, so this matches on substrings and
    /// falls back to `.thinking` — the phase that costs nothing to be wrong
    /// about, since it's the calmest thing the rim can show.
    public static func fromPhase(_ phase: String) -> AgentActivity {
        let p = phase.lowercased()
        if p.contains("tool") || p.contains("exec") || p.contains("command") { return .tooling }
        if p.contains("stream") || p.contains("respond") || p.contains("writ") { return .responding }
        return .thinking
    }
}

/// One event received on the agent socket. Two wire formats are accepted:
///
/// Kweku's native line (emitted by the omp extension), where `activity` and
/// `tool` are optional refinements of `state`:
///   `{"v":1,"source":"omp","session_id":"123","cwd":"/x","pid":123,
///     "state":"working","activity":"tooling","tool":"Bash"}`
///
/// Claude Code's hook payload (forwarded verbatim + `pid` added by the hook
/// command): `{"session_id":"...","cwd":"/x","hook_event_name":"Stop","pid":n}`
public struct AgentEvent: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String
    public var pid: Int32
    public var state: AgentState
    public var gone: Bool          // session ended; remove from the table
    /// What the turn is being spent on. Only meaningful while `working`;
    /// nil from emitters that report coarse state only.
    public var activity: AgentActivity?
    /// Name of the tool in flight, when `activity == .tooling`.
    public var tool: String?
    /// Which harness emitted this: "omp", "claude", "openclaw"… nil when the
    /// emitter predates the field.
    public var source: String?

    public init(sessionID: String, cwd: String, pid: Int32, state: AgentState,
                gone: Bool = false, activity: AgentActivity? = nil, tool: String? = nil,
                source: String? = nil) {
        self.sessionID = sessionID; self.cwd = cwd; self.pid = pid
        self.state = state; self.gone = gone
        // An activity only means something while the agent has the floor.
        self.activity = state == .working ? activity : nil
        self.tool = self.activity == .tooling ? tool : nil
        self.source = source
    }

    /// Parse one JSON line in either wire format. Returns nil on garbage.
    public static func parse(_ line: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let cwd = (obj["cwd"] as? String) ?? ""
        let pid = Int32((obj["pid"] as? Int) ?? Int((obj["pid"] as? String) ?? "") ?? 0)
        let tool = obj["tool_name"] as? String ?? obj["tool"] as? String

        // Kweku native format.
        if let raw = obj["state"] as? String {
            guard let id = obj["session_id"] as? String else { return nil }
            let source = obj["source"] as? String
            if raw == "gone" {
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .idle, gone: true,
                                  source: source)
            }
            guard let state = AgentState(rawValue: raw) else { return nil }
            let activity = (obj["activity"] as? String).flatMap(AgentActivity.init(rawValue:))
            return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: state,
                              activity: activity, tool: tool, source: source)
        }

        // Claude Code hook format. The tool hooks are what give the notch a
        // real *thinking → running a tool → thinking* rhythm; without them a
        // whole turn is one undifferentiated "working".
        if let hook = obj["hook_event_name"] as? String {
            let id = (obj["session_id"] as? String) ?? String(pid)
            func working(_ activity: AgentActivity, tool: String? = nil) -> AgentEvent {
                AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .working,
                           activity: activity, tool: tool, source: "claude")
            }
            switch hook {
            case "SessionStart":
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .idle, source: "claude")
            case "UserPromptSubmit": return working(.thinking)
            case "PreToolUse":       return working(.tooling, tool: tool)
            // The tool has returned and the model is reading its output —
            // back to reasoning until the next tool or the Stop.
            case "PostToolUse":      return working(.thinking)
            case "SubagentStop":     return working(.thinking)
            case "Stop", "Notification":
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .waiting, source: "claude")
            case "SessionEnd":
                return AgentEvent(sessionID: id, cwd: cwd, pid: pid, state: .idle, gone: true,
                                  source: "claude")
            default: return nil
            }
        }
        return nil
    }
}
