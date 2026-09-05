import Foundation

/// Installs the agent-watch emitters:
/// - Oh My Pi: a small extension dropped into `~/.omp/agent/extensions/`
///   that streams lifecycle events to Kweku's socket from inside the omp
///   process (node:net, no subprocess per event).
/// - Claude Code: hook commands merged (never overwriting existing hooks)
///   into `~/.claude/settings.json` that forward each hook's stdin JSON to
///   the socket.
///
/// Paths are injectable so the logic is testable against temp directories.
public struct AgentWatchSetup {
    public static let socketPath = ("~/Library/Application Support/Kweku/agent.sock" as NSString)
        .expandingTildeInPath

    public var ompExtensionsDir: URL
    public var claudeSettingsFile: URL

    public init(ompExtensionsDir: URL? = nil, claudeSettingsFile: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.ompExtensionsDir = ompExtensionsDir
            ?? home.appendingPathComponent(".omp/agent/extensions", isDirectory: true)
        self.claudeSettingsFile = claudeSettingsFile
            ?? home.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - omp

    public var ompExtensionFile: URL { ompExtensionsDir.appendingPathComponent("kweku-watch.ts") }

    public var ompInstalled: Bool {
        FileManager.default.fileExists(atPath: ompExtensionFile.path)
    }

    public static let ompExtensionSource = #"""
    // kweku-watch.ts — installed by Kweku.app (agent watcher).
    // Streams omp session lifecycle to Kweku's notch creature. Fails silent:
    // it must never break a coding session.
    import * as net from "node:net";
    import * as os from "node:os";
    import * as path from "node:path";

    const SOCK = path.join(os.homedir(), "Library/Application Support/Kweku/agent.sock");

    export default function (pi: any): void {
      let sock: net.Socket | null = null;

      const send = (state: string) => {
        try {
          const line = JSON.stringify({
            v: 1,
            source: "omp",
            session_id: String(process.pid),
            cwd: process.cwd(),
            pid: process.pid,
            state,
          }) + "\n";
          if (!sock || sock.destroyed) {
            sock = net.createConnection(SOCK);
            sock.on("error", () => { try { sock?.destroy(); } catch {} sock = null; });
          }
          sock.write(line);
        } catch { /* never break the session */ }
      };

      try {
        pi.on("session_start", () => send("idle"));
        pi.on("agent_start", () => send("working"));
        pi.on("agent_end", () => send("waiting"));
        pi.on("session_shutdown", () => send("gone"));
      } catch { /* older runtimes: ignore */ }
    }
    """#

    @discardableResult
    public func installOMP() -> Bool {
        do {
            try FileManager.default.createDirectory(at: ompExtensionsDir, withIntermediateDirectories: true)
            try Self.ompExtensionSource.write(to: ompExtensionFile, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    // MARK: - Claude Code

    /// Marker embedded in our hook command for idempotent merging.
    static let claudeMarker = "kweku-agent-watch"

    /// Forwards the hook's stdin JSON verbatim (plus the parent pid) to the
    /// socket. python3 ships with macOS CLT; failures are swallowed so hooks
    /// never break Claude.
    static let claudeCommand = #"""
    python3 -c 'import sys,json,os,socket
    # kweku-agent-watch
    try:
        d=json.load(sys.stdin); d["pid"]=os.getppid()
        s=socket.socket(socket.AF_UNIX); s.settimeout(1)
        s.connect(os.path.expanduser("~/Library/Application Support/Kweku/agent.sock"))
        s.sendall((json.dumps(d)+"\n").encode()); s.close()
    except Exception: pass' 
    """#

    public static let claudeHookEvents = ["SessionStart", "Notification", "Stop", "SubagentStop", "SessionEnd"]

    public var claudeInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettingsFile),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(Self.claudeMarker)
    }

    /// Merge our hooks into settings.json, preserving everything already there.
    @discardableResult
    public func installClaude() -> Bool {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let entry: [String: Any] = [
            "hooks": [["type": "command", "command": Self.claudeCommand]]
        ]
        for event in Self.claudeHookEvents {
            var matchers = (hooks[event] as? [[String: Any]]) ?? []
            let present = matchers.contains { m in
                ((m["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(Self.claudeMarker) == true
                }
            }
            if !present { matchers.append(entry) }
            hooks[event] = matchers
        }
        root["hooks"] = hooks
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try FileManager.default.createDirectory(
                at: claudeSettingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: claudeSettingsFile, options: .atomic)
            return true
        } catch { return false }
    }

    public var allInstalled: Bool { ompInstalled && claudeInstalled }

    @discardableResult
    public func installAll() -> Bool {
        let a = installOMP(), b = installClaude()
        return a && b
    }
}
