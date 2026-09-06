import Foundation

/// What a finished agent session actually did, read from its working copy.
///
/// The pit crew can already say *that* a session stopped. That is a
/// notification, and a notification about an agent is nearly useless: the
/// interesting part is never that it finished, it's what it left behind. This
/// reads that from git — the one account of the work that the agent cannot
/// misreport, because it isn't the agent talking.
///
/// Everything here is evidence, not narration. If the directory isn't a repo,
/// or nothing changed, the report is nil and Kweku falls back to the plain
/// "it's waiting on you" line rather than inventing an accomplishment.
public enum AgentReport {

    /// The state of a working copy, as far as it can be read.
    public struct Work: Equatable, Sendable {
        public var files: Int
        public var insertions: Int
        public var deletions: Int
        public var untracked: Int
        /// Commit subjects made since the session was first seen, newest first.
        public var commits: [String]
        public var branch: String?

        public init(files: Int = 0, insertions: Int = 0, deletions: Int = 0,
                    untracked: Int = 0, commits: [String] = [], branch: String? = nil) {
            self.files = files; self.insertions = insertions; self.deletions = deletions
            self.untracked = untracked; self.commits = commits; self.branch = branch
        }

        public var isEmpty: Bool { files == 0 && untracked == 0 && commits.isEmpty }
    }

    // MARK: - Pure formatting

    /// Parse `git diff --shortstat`:
    /// ` 13 files changed, 506 insertions(+), 105 deletions(-)`
    ///
    /// Any of the three clauses can be absent — a pure-insertion diff has no
    /// deletions clause at all — so each is read independently rather than by
    /// position.
    public static func parseShortstat(_ raw: String) -> (files: Int, insertions: Int, deletions: Int) {
        func number(before word: String) -> Int {
            // " 13 files changed, 506 insertions(+)" -> the token before `word`.
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            for (index, token) in parts.enumerated() where token.hasPrefix(word) {
                guard index > 0 else { continue }
                return Int(parts[index - 1]) ?? 0
            }
            return 0
        }
        return (number(before: "file"), number(before: "insertion"), number(before: "deletion"))
    }

    /// One clause of plain fact, or nil when there is nothing to report.
    ///
    /// Reads as evidence rather than praise: counts and commit subjects only.
    /// "Finished successfully" is not something a diff can tell you.
    public static func summary(_ work: Work) -> String? {
        guard !work.isEmpty else { return nil }
        var parts: [String] = []

        if !work.commits.isEmpty {
            let subjects = work.commits.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            let more = work.commits.count > 3 ? " and \(work.commits.count - 3) more" : ""
            parts.append("committed \(work.commits.count) change"
                         + "\(work.commits.count == 1 ? "" : "s") — \(subjects)\(more)")
        }
        if work.files > 0 {
            parts.append("left \(work.files) file\(work.files == 1 ? "" : "s") modified "
                         + "(+\(work.insertions)/−\(work.deletions)) not yet committed")
        }
        if work.untracked > 0 {
            parts.append("added \(work.untracked) new file\(work.untracked == 1 ? "" : "s")")
        }
        let branch = work.branch.map { " on branch \($0)" } ?? ""
        return parts.joined(separator: ", ") + branch
    }

    /// The announcement handed to the Live conversation.
    ///
    /// Omari asked to be addressed and reported to, so the form is prescribed
    /// here rather than left to the model. The hard rule is the last line: a
    /// git summary is a narrow, checkable set of facts, and the failure mode
    /// for any of this is Kweku deciding the agent "successfully fixed the
    /// bug" because that is what a finished agent usually does.
    public static func prompt(for entries: [(session: AgentSession, work: Work?)],
                              now: Date = Date()) -> String {
        let lines = entries.map { entry -> String in
            let waited = Int(now.timeIntervalSince(entry.session.stateSince) / 60)
            let howLong = waited < 1 ? "just now" : "\(waited) minute\(waited == 1 ? "" : "s") ago"
            let place = entry.session.displayName
            let did = summary(entry.work ?? Work())
                ?? "no file changes it could find in that folder"
            return "- The \(entry.session.sourceLabel) session in \(place) stopped \(howLong) "
                + "and is waiting on him. What it did, read from git: \(did)."
        }.joined(separator: "\n")

        return """
            System notice, not from Omari — he did not say anything. One of his \
            background agents has finished and is waiting on him.

            \(lines)

            Address him by name and report it, opening with something like \
            "Omari, I'd like to report that…". Give it in one or two short \
            spoken sentences: which project, and what the agent actually \
            changed. Use only the facts above — do not invent files, commits, \
            test results, or whether the work was any good, and do not claim it \
            succeeded or fixed anything. You are reporting a diff, not a \
            verdict. Do not offer to do anything further unless he asks.
            """
    }

    // MARK: - Reading the working copy

    /// Read what happened in `cwd` since `since`. Nil when it isn't a git
    /// working tree — plenty of agent sessions run somewhere that isn't a repo,
    /// and that is a reason to stay quiet, not to guess.
    public static func read(cwd: String, since: Date) -> Work? {
        guard !cwd.isEmpty,
              git(["rev-parse", "--is-inside-work-tree"], cwd: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return nil }

        let stat = parseShortstat(git(["diff", "--shortstat", "HEAD"], cwd: cwd) ?? "")
        let untracked = (git(["ls-files", "--others", "--exclude-standard"], cwd: cwd) ?? "")
            .split(separator: "\n").count
        let formatter = ISO8601DateFormatter()
        let commits = (git(["log", "--since=\(formatter.string(from: since))",
                            "--pretty=format:%s", "-n", "5"], cwd: cwd) ?? "")
            .split(separator: "\n").map(String.init)
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Work(files: stat.files, insertions: stat.insertions, deletions: stat.deletions,
                    untracked: untracked, commits: commits,
                    branch: (branch?.isEmpty == false) ? branch : nil)
    }

    /// Run one git command, or nil if it fails for any reason.
    ///
    /// Read-only commands exclusively. Kweku reports on the repo; it does not
    /// touch it — an assistant that stages or stashes to find out what happened
    /// would be a far worse bug than saying nothing.
    static func git(_ arguments: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_PAGER"] = "cat"       // no pager waiting on a tty
        environment["GIT_OPTIONAL_LOCKS"] = "0" // never take index.lock to read
        environment["LC_ALL"] = "C"            // stable shortstat wording
        process.environment = environment

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
