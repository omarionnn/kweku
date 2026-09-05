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
        }
    }
}
