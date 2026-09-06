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

    /// Openers to rotate between, so a run of reports doesn't read as one
    /// sentence with the numbers swapped out.
    ///
    /// A single prescribed opener made every announcement start with the same
    /// eight words, which is what a form letter sounds like. All of these still
    /// address him by name — that part he asked for — but the model needs more
    /// than one shape to reach for, and it has no memory of the last report to
    /// vary against on its own, so the variation has to come from here.
    static let openers = [
        "Omari, I'd like to report that…",
        "Omari, quick report:",
        "Omari — that agent just went quiet.",
        "Omari, here's where that session landed:",
        "Omari, an update from the pit crew:",
    ]

    /// A stable index into `openers`.
    ///
    /// Deliberately not `Hasher`, whose seed changes every process: the same
    /// report should read the same way if it is regenerated, and a test should
    /// be able to pin one.
    static func openerIndex(_ seed: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Int(hash % UInt64(count))
    }

    /// The announcement handed to the Live conversation.
    ///
    /// Omari asked to be addressed and reported to, so the form is steered
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

        let opener = openers[openerIndex(lines + "\(Int(now.timeIntervalSince1970))",
                                         count: openers.count)]

        return """
            System notice, not from Omari — he did not say anything. One of his \
            background agents has finished and is waiting on him.

            \(lines)

            Address him by name and report it in one or two short spoken \
            sentences: which project, and what the agent actually changed. \
            Open with something like "\(opener)" — but vary the wording and \
            lead with the change itself, not with a preamble. These arrive \
            several times a day and must not read like the same sentence \
            every time. Use only the facts above — do not invent files, \
            commits, test results, or whether the work was any good, and do \
            not claim it succeeded or fixed anything. You are reporting a \
            diff, not a verdict. Do not offer to do anything further unless \
            he asks.
            """
    }

    // MARK: - Reading the working copy

    /// git's hash for the empty tree — the only sane diff base in a repo that
    /// has no commits yet.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// New files this session actually created: `git ls-files --others`
    /// narrowed to files that came into existence after `since`.
    ///
    /// The unfiltered list is every never-committed file in the tree, which is
    /// not the same thing as new work at all. In a folder that was never
    /// committed it is a large constant — `~/.openclaw/workspace` sits at 68,
    /// none of them new — so every report for every session there said "added
    /// 68 new files", verbatim, forever.
    static func untrackedFiles(cwd: String, since: Date) -> Int {
        guard let raw = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: cwd)
        else { return 0 }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        return raw.split(separator: "\0").reduce(into: 0) { count, path in
            let url = root.appendingPathComponent(String(path))
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey,
                                                                 .contentModificationDateKey]),
                  let born = values.creationDate ?? values.contentModificationDate
            else { return }
            if born >= since { count += 1 }
        }
    }

    /// Read what happened in `cwd` since `since`. Nil when it isn't a git
    /// working tree — plenty of agent sessions run somewhere that isn't a repo,
    /// and that is a reason to stay quiet, not to guess.
    public static func read(cwd: String, since: Date) -> Work? {
        guard !cwd.isEmpty,
              git(["rev-parse", "--is-inside-work-tree"], cwd: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return nil }

        // A repo can have no commits at all. `git diff HEAD` and `git log`
        // both *fail* there rather than returning nothing, so every dynamic
        // field silently came back zero and the report collapsed onto the one
        // field that still parsed. Diff against the empty tree instead, and
        // don't ask for a log that cannot exist.
        let hasCommits = git(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: cwd) != nil
        let stat = parseShortstat(
            git(["diff", "--shortstat", hasCommits ? "HEAD" : emptyTree], cwd: cwd) ?? "")
        let untracked = untrackedFiles(cwd: cwd, since: since)
        let formatter = ISO8601DateFormatter()
        let commits = !hasCommits ? [] :
            (git(["log", "--since=\(formatter.string(from: since))",
                  "--pretty=format:%s", "-n", "5"], cwd: cwd) ?? "")
                .split(separator: "\n").map(String.init)
        // `--show-current` reports the branch of an unborn HEAD; `--abbrev-ref
        // HEAD` fails outright on one.
        let branch = git(["branch", "--show-current"], cwd: cwd)?
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
