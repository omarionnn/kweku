import Foundation
import KwekuKit

enum GitSyncTests {
    static func all() {
        directions()
        notGit()
        compound()
        throughTheHook()
    }

    // MARK: Which way the bytes go

    static func directions() {
        Check.run("push is outbound, fetch and clone and pull are inbound") {
            Check.ok(GitSync.direction(forCommand: "git push") == .push, "the plain case")
            Check.ok(GitSync.direction(forCommand: "git pull") == .pull, "pull")
            Check.ok(GitSync.direction(forCommand: "git fetch origin") == .pull, "fetch")
            Check.ok(GitSync.direction(forCommand: "git clone git@github.com:o/k.git") == .pull,
                     "a clone is a fetch you don't have a repo for yet")
        }
        Check.run("global options are stepped over to reach the subcommand") {
            // Every worktree command in this project is shaped like this, so
            // missing it would mean the feature never fired where it matters.
            Check.ok(GitSync.direction(forCommand: "git -C ~/Desktop/notch-yt push") == .push,
                     "-C takes a value, and the value is not the subcommand")
            Check.ok(GitSync.direction(forCommand: "git -c user.name=x fetch") == .pull,
                     "-c likewise")
            Check.ok(GitSync.direction(forCommand: "git --no-pager push origin main") == .push,
                     "a valueless flag is just skipped")
            Check.ok(GitSync.direction(forCommand: "git --git-dir=/tmp/x.git fetch") == .pull,
                     "--opt=value carries its own value")
        }
        Check.run("an absolute path to git still reads as git") {
            Check.ok(GitSync.direction(forCommand: "/usr/bin/git push") == .push,
                     "compared on the last path component")
            Check.ok(GitSync.direction(forCommand: "GIT_SSH_COMMAND=ssh git push") == .push,
                     "an environment override in front is stripped")
            Check.ok(GitSync.direction(forCommand: "env GIT_TRACE=1 git fetch") == .pull,
                     "and so is a literal env")
        }
    }

    // MARK: What must not light the rim

    static func notGit() {
        Check.run("local git commands are not transfers") {
            // These are the overwhelming majority of git calls, and colouring
            // them as network traffic would make the signal meaningless.
            for command in ["git status", "git add -A", "git commit -m x",
                            "git log --oneline", "git diff", "git merge main",
                            "git worktree list", "git rev-parse HEAD"] {
                Check.ok(GitSync.direction(forCommand: command) == nil,
                         "\(command) never leaves the machine")
            }
        }
        Check.run("something that merely contains the word is not a push") {
            Check.ok(GitSync.direction(forCommand: "make test") == nil, "no git at all")
            Check.ok(GitSync.direction(forCommand: "grep push Makefile") == nil,
                     "the word is not the command")
            Check.ok(GitSync.direction(forCommand: "") == nil, "nothing is nothing")
            Check.ok(GitSync.direction(forCommand: "gitk") == nil,
                     "a different executable that starts with git")
        }
    }

    // MARK: Compound lines

    static func compound() {
        Check.run("a push is found after any separator") {
            Check.ok(GitSync.direction(forCommand: "make test && git push") == .push, "&&")
            Check.ok(GitSync.direction(forCommand: "git add -A; git commit -m x; git push") == .push,
                     "; and it is the last of three git calls")
            Check.ok(GitSync.direction(forCommand: "cd /tmp || git fetch") == .pull, "||")
            Check.ok(GitSync.direction(forCommand: "echo hi\ngit push") == .push, "a newline")
        }
        Check.run("a piped-into git is still seen") {
            Check.ok(GitSync.direction(forCommand: "cat list | git push --stdin") == .push,
                     "the pipe starts a new command")
        }
        Check.run("the first remote command wins") {
            Check.ok(GitSync.direction(forCommand: "git fetch && git push") == .pull,
                     "one rim, one direction — and the fetch happens first")
        }
        Check.run("lines taken verbatim from a real session read correctly") {
            // Lifted out of this project's own Claude Code transcript, which is
            // where these commands actually come from — the shapes a synthetic
            // test tends not to think of.
            Check.ok(GitSync.direction(
                forCommand: "cd /tmp && rm -rf mra && git clone --depth 1 -q https://github.com/u/r.git mra")
                == .pull, "flags between the subcommand and the URL")
            Check.ok(GitSync.direction(
                forCommand: "cd ~/Desktop/notch && git branch -a 2>&1 | head && echo done")
                == nil, "branch is local, and the pipe must not confuse the scan")
            Check.ok(GitSync.direction(
                forCommand: "cd ~/Desktop/notch && echo \"=== STATUS ===\" && git status --short | head -30")
                == nil, "status is local, quoted banner and all")
        }
    }

    // MARK: End to end, through the wire format

    static func throughTheHook() {
        func event(command: String) -> AgentEvent? {
            let payload: [String: Any] = [
                "hook_event_name": "PreToolUse",
                "session_id": "s1",
                "cwd": "/repo",
                "pid": 42,
                "tool_name": "Bash",
                "tool_input": ["command": command],
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return AgentEvent.parse(String(data: data, encoding: .utf8)!)
        }

        Check.run("a Bash push arrives as a pushing activity") {
            Check.ok(event(command: "git push origin main")?.activity == .pushing,
                     "read off tool_input.command, which the hook already forwards")
        }
        Check.run("a Bash fetch arrives as pulling") {
            Check.ok(event(command: "git -C /x fetch origin")?.activity == .pulling, "inbound")
        }
        Check.run("any other command is still the generic tool call") {
            let e = event(command: "swift build")
            Check.ok(e?.activity == .tooling, "unchanged behaviour for everything else")
            Check.ok(e?.tool == "Bash", "and it keeps the tool name")
        }
        Check.run("a payload with no tool_input degrades quietly") {
            // Older Claude Code builds, and every non-Bash tool.
            let payload: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": "s",
                                          "cwd": "/x", "pid": 1, "tool_name": "Read"]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            let e = AgentEvent.parse(String(data: data, encoding: .utf8)!)
            Check.ok(e?.activity == .tooling, "falls back rather than failing the parse")
        }
        Check.run("network phases outrank a plain tool call") {
            Check.ok(AgentActivity.pushing.rank < AgentActivity.tooling.rank,
                     "with several sessions running, the transfer is the one to show")
            Check.ok(AgentActivity.tooling.rank < AgentActivity.responding.rank,
                     "and the original order is undisturbed")
            Check.ok(AgentActivity.responding.rank < AgentActivity.thinking.rank, "likewise")
        }
    }
}
