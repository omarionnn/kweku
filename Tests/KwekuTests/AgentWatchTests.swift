import Foundation
import KwekuKit

enum AgentWatchTests {
    static func all() {
        parse()
        table()
        walk()
        installers()
    }

    // MARK: Event parsing (both wire formats)

    static func parse() {
        Check.run("parses kweku-native omp line") {
            let e = AgentEvent.parse(
                #"{"v":1,"source":"omp","session_id":"411","cwd":"/x/repo","pid":411,"state":"working"}"#)
            Check.ok(e?.sessionID == "411" && e?.state == .working, "working event")
            Check.ok(e?.cwd == "/x/repo" && e?.pid == 411, "cwd + pid")
        }
        Check.run("kweku 'gone' removes") {
            let e = AgentEvent.parse(#"{"session_id":"411","cwd":"","pid":411,"state":"gone"}"#)
            Check.ok(e?.gone == true, "gone flag")
        }
        Check.run("maps claude hook events") {
            let stop = AgentEvent.parse(#"{"session_id":"abc","cwd":"/y","hook_event_name":"Stop","pid":9}"#)
            Check.ok(stop?.state == .waiting, "Stop -> waiting")
            let note = AgentEvent.parse(#"{"session_id":"abc","cwd":"/y","hook_event_name":"Notification","pid":9}"#)
            Check.ok(note?.state == .waiting, "Notification -> waiting")
            let start = AgentEvent.parse(#"{"session_id":"abc","cwd":"/y","hook_event_name":"SessionStart","pid":9}"#)
            Check.ok(start?.state == .idle, "SessionStart -> idle")
            let sub = AgentEvent.parse(#"{"session_id":"abc","cwd":"/y","hook_event_name":"SubagentStop","pid":9}"#)
            Check.ok(sub?.state == .working, "SubagentStop -> parent still working")
        }
        Check.run("claude tool hooks carry the turn's phase") {
            let ask = AgentEvent.parse(
                #"{"session_id":"a","cwd":"/y","hook_event_name":"UserPromptSubmit","pid":9}"#)
            Check.ok(ask?.state == .working && ask?.activity == .thinking, "prompt -> thinking")
            let pre = AgentEvent.parse(
                #"{"session_id":"a","cwd":"/y","hook_event_name":"PreToolUse","tool_name":"Bash","pid":9}"#)
            Check.ok(pre?.activity == .tooling && pre?.tool == "Bash", "PreToolUse -> tooling(Bash)")
            let post = AgentEvent.parse(
                #"{"session_id":"a","cwd":"/y","hook_event_name":"PostToolUse","tool_name":"Bash","pid":9}"#)
            Check.ok(post?.activity == .thinking && post?.tool == nil,
                     "PostToolUse -> back to thinking, tool cleared")
            let stop = AgentEvent.parse(
                #"{"session_id":"a","cwd":"/y","hook_event_name":"Stop","pid":9}"#)
            Check.ok(stop?.activity == nil, "an activity means nothing once it's waiting")
        }
        Check.run("native line carries activity + tool") {
            let e = AgentEvent.parse(
                #"{"session_id":"7","cwd":"/x","pid":7,"state":"working","activity":"tooling","tool":"grep"}"#)
            Check.ok(e?.activity == .tooling && e?.tool == "grep", "parsed")
            let bad = AgentEvent.parse(
                #"{"session_id":"7","cwd":"/x","pid":7,"state":"working","activity":"nonsense"}"#)
            Check.ok(bad?.state == .working && bad?.activity == nil, "unknown activity ignored, not fatal")
        }
        Check.run("maps gateway phases onto activities") {
            Check.ok(AgentActivity.fromPhase("running_tool") == .tooling, "tool")
            Check.ok(AgentActivity.fromPhase("exec_command") == .tooling, "exec")
            Check.ok(AgentActivity.fromPhase("streaming") == .responding, "stream")
            Check.ok(AgentActivity.fromPhase("starting_model") == .thinking, "unknown -> calm default")
        }
        Check.run("rejects garbage") {
            Check.ok(AgentEvent.parse("not json") == nil, "non-json")
            Check.ok(AgentEvent.parse(#"{"foo":1}"#) == nil, "unknown shape")
        }
    }

    // MARK: Session table

    static func table() {
        let t0 = Date(timeIntervalSince1970: 1000)

        Check.run("tracks state transitions per session") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working), at: t0)
            t.apply(AgentEvent(sessionID: "b", cwd: "/b", pid: 2, state: .idle), at: t0)
            Check.ok(t.count == 2 && t.anyWorking && !t.anyWaiting, "two sessions, one working")
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .waiting), at: t0 + 1)
            Check.ok(!t.anyWorking && t.anyWaiting, "a flipped to waiting")
        }
        Check.run("gone removes the session") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working), at: t0)
            t.apply(AgentEvent(sessionID: "a", cwd: "", pid: 1, state: .idle, gone: true), at: t0 + 1)
            Check.ok(t.count == 0, "removed")
        }
        Check.run("focus prefers waiting, then working, then latest") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "w1", cwd: "/1", pid: 1, state: .working), at: t0)
            t.apply(AgentEvent(sessionID: "i1", cwd: "/2", pid: 2, state: .idle), at: t0 + 5)
            Check.ok(t.focusTarget()?.id == "w1", "working beats newer idle")
            t.apply(AgentEvent(sessionID: "n1", cwd: "/3", pid: 3, state: .waiting), at: t0 + 1)
            Check.ok(t.focusTarget()?.id == "n1", "waiting beats working")
        }
        Check.run("table shows the most salient activity") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working,
                               activity: .thinking), at: t0)
            Check.ok(t.activity == .thinking, "one thinker")
            t.apply(AgentEvent(sessionID: "b", cwd: "/b", pid: 2, state: .working,
                               activity: .tooling, tool: "Bash"), at: t0 + 1)
            Check.ok(t.activity == .tooling && t.activeTool == "Bash",
                     "a running tool outranks thinking")
            // Order of arrival must not matter — ranking, not recency.
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working,
                               activity: .thinking), at: t0 + 2)
            Check.ok(t.activity == .tooling, "still the tool")
            t.apply(AgentEvent(sessionID: "b", cwd: "/b", pid: 2, state: .waiting), at: t0 + 3)
            Check.ok(t.activity == .thinking && t.activeTool == nil, "tool finished")
        }
        Check.run("coarse 'working' reads as thinking") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "omp", cwd: "/a", pid: 1, state: .working), at: t0)
            Check.ok(t.activity == .thinking, "no activity reported -> the calm default")
        }
        Check.run("stateSince ignores same-state churn") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working,
                               activity: .thinking), at: t0)
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working,
                               activity: .tooling, tool: "Read"), at: t0 + 30)
            Check.ok(t.sessions["a"]?.stateSince == t0, "still busy since t0")
            Check.ok(t.sessions["a"]?.lastUpdated == t0 + 30, "but heard from just now")
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .waiting), at: t0 + 60)
            Check.ok(t.sessions["a"]?.stateSince == t0 + 60, "resets on a real state change")
        }
        Check.run("labels the phase for the panel") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working,
                               activity: .tooling, tool: "Bash"), at: t0)
            Check.ok(t.sessions["a"]?.activityLabel == "Bash", "named tool")
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .working,
                               activity: .tooling), at: t0)
            Check.ok(t.sessions["a"]?.activityLabel == "running a tool", "unnamed tool")
            t.apply(AgentEvent(sessionID: "a", cwd: "/a", pid: 1, state: .waiting), at: t0)
            Check.ok(t.sessions["a"]?.activityLabel == nil, "nothing to say while waiting")
        }
        Check.run("prune drops dead and stale sessions") {
            var t = AgentSessionTable()
            t.apply(AgentEvent(sessionID: "live", cwd: "/a", pid: 10, state: .working), at: t0)
            t.apply(AgentEvent(sessionID: "dead", cwd: "/b", pid: 20, state: .working), at: t0)
            t.apply(AgentEvent(sessionID: "old", cwd: "/c", pid: 10, state: .idle), at: t0 - 7200)
            t.prune(isAlive: { $0 == 10 }, now: t0 + 1)
            Check.ok(t.sessions["live"] != nil, "alive kept")
            Check.ok(t.sessions["dead"] == nil, "dead pid dropped")
            Check.ok(t.sessions["old"] == nil, "stale dropped")
        }
    }

    // MARK: Process-tree walk

    static func walk() {
        Check.run("walks up to the GUI ancestor") {
            // omp(500) <- zsh(400) <- login(300) <- Terminal(200, GUI)
            let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 200, 200: 1]
            let found = TerminalFocus.owningApp(from: 500,
                                                parent: { parents[$0] },
                                                isApp: { $0 == 200 })
            Check.ok(found == 200, "found Terminal")
        }
        Check.run("pid that is itself an app wins immediately") {
            let found = TerminalFocus.owningApp(from: 42, parent: { _ in nil }, isApp: { $0 == 42 })
            Check.ok(found == 42, "self")
        }
        Check.run("gives up at init/launchd or cycles") {
            Check.ok(TerminalFocus.owningApp(from: 5, parent: { _ in 1 }, isApp: { _ in false }) == nil,
                     "stops at pid 1")
            Check.ok(TerminalFocus.owningApp(from: 5, parent: { $0 }, isApp: { _ in false }) == nil,
                     "self-cycle bounded")
        }
    }

    // MARK: Installers (temp dirs)

    static func installers() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kweku-watch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        Check.run("omp extension installs and is detected") {
            let setup = AgentWatchSetup(
                ompExtensionsDir: tmp.appendingPathComponent("omp-ext"),
                claudeSettingsFile: tmp.appendingPathComponent("claude/settings.json"))
            Check.ok(!setup.ompInstalled, "not installed yet")
            Check.ok(setup.installOMP(), "install succeeds")
            Check.ok(setup.ompInstalled, "detected")
            let src = try? String(contentsOf: setup.ompExtensionFile, encoding: .utf8)
            Check.ok(src?.contains("agent_start") == true && src?.contains("agent.sock") == true,
                     "extension subscribes and targets the socket")
        }

        Check.run("claude merge preserves existing settings") {
            let file = tmp.appendingPathComponent("claude/settings.json")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            let setup = AgentWatchSetup(
                ompExtensionsDir: tmp.appendingPathComponent("omp-ext2"),
                claudeSettingsFile: file)
            Check.ok(setup.installClaude(), "merge succeeds")
            let out = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            Check.ok(out.contains(#""model" : "opus"#) || out.contains(#""model":"opus"#), "kept model")
            Check.ok(out.contains("echo hi"), "kept existing Stop hook")
            Check.ok(out.contains("kweku-agent-watch"), "added ours")
            Check.ok(setup.claudeInstalled, "detected")
            // Idempotent: run again, still exactly one marker per event.
            Check.ok(setup.installClaude(), "second merge succeeds")
            let again = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let markers = again.components(separatedBy: "kweku-agent-watch").count - 1
            Check.ok(markers == AgentWatchSetup.claudeHookEvents.count,
                     "one entry per event after re-run (got \(markers))")
            Check.ok(out.contains("PreToolUse") && out.contains("PostToolUse"),
                     "tool hooks installed — without them there's no phase to show")
        }

        Check.run("a partial install from an older build isn't reported as done") {
            let file = tmp.appendingPathComponent("claude-partial/settings.json")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // Only the lifecycle hooks, as an earlier Kweku would have left it.
            var old: [String: Any] = [:]
            for event in AgentWatchSetup.claudeLifecycleEvents {
                old[event] = [["hooks": [["type": "command",
                                          "command": "python3 -c pass  # kweku-agent-watch"]]]]
            }
            let data = try? JSONSerialization.data(withJSONObject: ["hooks": old])
            try? data?.write(to: file)
            let setup = AgentWatchSetup(
                ompExtensionsDir: tmp.appendingPathComponent("omp-ext3"),
                claudeSettingsFile: file)
            Check.ok(!setup.claudeInstalled, "missing tool hooks -> not installed")
            Check.ok(setup.installClaude(), "top-up merge succeeds")
            Check.ok(setup.claudeInstalled, "complete now")
            let out = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let markers = out.components(separatedBy: "kweku-agent-watch").count - 1
            Check.ok(markers == AgentWatchSetup.claudeHookEvents.count,
                     "topped up without duplicating (got \(markers))")
        }
    }
}
