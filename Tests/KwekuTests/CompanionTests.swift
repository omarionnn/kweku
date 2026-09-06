import Foundation
@testable import KwekuKit

/// Tests for the four companion features: redaction, screen recall, the agent
/// pit crew, and unsolicited triage. All four are mostly restraint logic —
/// what *not* to send, what *not* to say — so that is what these pin down.
enum CompanionTests {
    static func all() {
        redaction()
        timeline()
        attention()
        report()
        triage()
    }

    // MARK: - 3b. What the finished agent actually did

    static func report() {
        Check.run("shortstat is read clause by clause, not by position") {
            let full = AgentReport.parseShortstat(
                " 13 files changed, 506 insertions(+), 105 deletions(-)")
            Check.ok(full == (13, 506, 105), "full line")
            // A pure-insertion diff omits the deletions clause entirely; a
            // positional parse reads 0 files or crashes on it.
            let adds = AgentReport.parseShortstat(" 2 files changed, 40 insertions(+)")
            Check.ok(adds == (2, 40, 0), "no deletions clause")
            let dels = AgentReport.parseShortstat(" 1 file changed, 9 deletions(-)")
            Check.ok(dels == (1, 0, 9), "singular 'file', no insertions clause")
            Check.ok(AgentReport.parseShortstat("") == (0, 0, 0), "empty diff")
        }

        Check.run("a report states evidence, never a verdict") {
            let uncommitted = AgentReport.Work(files: 13, insertions: 506, deletions: 105,
                                               branch: "main")
            let text = AgentReport.summary(uncommitted) ?? ""
            Check.ok(text.contains("13 files"), "counts the files")
            Check.ok(text.contains("+506/−105"), "carries the line counts")
            Check.ok(text.contains("not yet committed"), "says the work is unlanded")
            Check.ok(text.contains("on branch main"), "names the branch")

            let committed = AgentReport.Work(commits: ["Fix the blind notch", "Add stats panel"])
            let two = AgentReport.summary(committed) ?? ""
            Check.ok(two.contains("committed 2 changes"), "counts commits")
            Check.ok(two.contains("Fix the blind notch"), "quotes the subjects")

            let many = AgentReport.Work(commits: ["a", "b", "c", "d", "e"])
            Check.ok((AgentReport.summary(many) ?? "").contains("and 2 more"),
                     "long commit lists are elided, not recited")

            Check.ok(AgentReport.summary(AgentReport.Work()) == nil,
                     "nothing changed -> nothing to report")
            Check.ok(AgentReport.summary(AgentReport.Work(untracked: 3))?
                        .contains("3 new files") == true, "untracked files count as work")
        }

        Check.run("the announcement addresses Omari and forbids embellishment") {
            let now = Date(timeIntervalSince1970: 6_000_000)
            let session = AgentSession(id: "a", cwd: "/Users/o/sk-triage", pid: 1,
                                       state: .waiting, lastUpdated: now,
                                       stateSince: now.addingTimeInterval(-120),
                                       source: "claude")
            let work = AgentReport.Work(files: 14, insertions: 420, deletions: 96,
                                        commits: ["Fix reply mismatch"], branch: "main")
            let prompt = AgentReport.prompt(for: [(session, work)], now: now)

            Check.ok(AgentReport.openers.contains { prompt.contains($0) },
                     "opens with one of the openers")
            Check.ok(prompt.contains("Omari"), "addresses him by name")
            Check.ok(prompt.contains("must not read like the same sentence"),
                     "tells the model not to recite a form letter")
            Check.ok(prompt.contains("sk-triage"), "names the project")
            Check.ok(prompt.contains("claude"), "names the harness")
            Check.ok(prompt.contains("14 files"), "carries the evidence")
            Check.ok(prompt.contains("Fix reply mismatch"), "carries the commit subject")
            Check.ok(prompt.contains("not from Omari"), "marked as a system notice")
            // The whole risk: a finished agent usually did succeed, so the
            // model will happily say so on no evidence at all.
            Check.ok(prompt.contains("do not claim it") && prompt.contains("succeeded"),
                     "forbids claiming success")
            Check.ok(prompt.contains("reporting a diff, not a verdict"), "states the limit")

            // No repo, or nothing found: still announces, without inventing.
            let bare = AgentReport.prompt(for: [(session, nil)], now: now)
            Check.ok(bare.contains("no file changes it could find"),
                     "says it found nothing rather than implying nothing happened")
        }

        Check.run("consecutive reports don't open with the same sentence") {
            // The complaint that started this: every announcement was the same
            // words with the numbers swapped. One prescribed opener guarantees
            // that, and the model can't vary it by itself — it has no memory of
            // the previous report to differ from.
            let base = Date(timeIntervalSince1970: 6_000_000)
            let session = AgentSession(id: "a", cwd: "/Users/o/notch", pid: 1,
                                       state: .waiting, lastUpdated: base,
                                       stateSince: base.addingTimeInterval(-120),
                                       source: "claude")
            let openers = (0..<40).map { step -> String in
                let now = base.addingTimeInterval(Double(step) * 37)
                let work = AgentReport.Work(files: step, insertions: step * 3, branch: "main")
                let prompt = AgentReport.prompt(for: [(session, work)], now: now)
                return AgentReport.openers.first { prompt.contains($0) } ?? "none"
            }
            Check.ok(!openers.contains("none"), "every prompt carries a known opener")
            Check.ok(Set(openers).count >= 3, "the opener actually rotates")

            // Same facts at the same instant must still read the same way, or
            // a regenerated report would contradict itself.
            let work = AgentReport.Work(files: 2, branch: "main")
            Check.ok(AgentReport.prompt(for: [(session, work)], now: base)
                     == AgentReport.prompt(for: [(session, work)], now: base),
                     "the rotation is deterministic, not random")
        }

        Check.run("only files born during the session count as new") {
            guard let repo = TempRepo(commit: false) else {
                return Check.ok(false, "could not create a temp repo")
            }
            defer { repo.remove() }

            // Pre-existing, never-committed clutter — the 68-file case. Old
            // enough that no session should be credited with it.
            repo.write("AGENTS.md", born: repo.start.addingTimeInterval(-86_400))
            repo.write("SOUL.md", born: repo.start.addingTimeInterval(-86_400))

            var work = AgentReport.read(cwd: repo.path, since: repo.start)
            Check.ok(work != nil, "an unborn-HEAD repo is still a repo")
            Check.ok(work?.untracked == 0, "long-standing untracked files aren't new work")
            Check.ok(AgentReport.summary(work ?? .init()) == nil,
                     "so there is nothing to report, rather than a stale constant")

            repo.write("Fix.swift", born: repo.start.addingTimeInterval(30))
            work = AgentReport.read(cwd: repo.path, since: repo.start)
            Check.ok(work?.untracked == 1, "a file created after the session started counts")
            Check.ok(AgentReport.summary(work ?? .init())?.contains("1 new file") == true,
                     "and it is reported singular")
        }

        Check.run("a repo with no commits reads without failing") {
            // `git diff HEAD` and `git log` both error on an unborn HEAD, which
            // zeroed every dynamic field and left the report with one clause.
            guard let repo = TempRepo(commit: false) else {
                return Check.ok(false, "could not create a temp repo")
            }
            defer { repo.remove() }
            repo.write("Staged.swift", born: repo.start.addingTimeInterval(10),
                       contents: "let a = 1\nlet b = 2\n")
            repo.git(["add", "Staged.swift"])

            let work = AgentReport.read(cwd: repo.path, since: repo.start)
            Check.ok(work?.files == 1, "staged work is measured against the empty tree")
            Check.ok(work?.insertions == 2, "and carries real line counts")
            Check.ok(work?.commits.isEmpty == true, "no commits to quote, and no crash")
            Check.ok(work?.branch != nil, "the branch of an unborn HEAD is still readable")
        }
    }

    /// A throwaway git repo, so the git-reading paths are tested against git
    /// rather than against a hand-built `Work`.
    struct TempRepo {
        let path: String
        let start: Date

        init?(commit: Bool) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("kweku-report-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)) != nil else { return nil }
            path = url.path
            // Static, not the instance helper: `start` isn't initialized yet.
            _ = AgentReport.git(["init", "-q", "-b", "main"], cwd: url.path)
            _ = AgentReport.git(["config", "user.email", "t@t"], cwd: url.path)
            _ = AgentReport.git(["config", "user.name", "t"], cwd: url.path)
            if commit {
                _ = AgentReport.git(["commit", "-q", "--allow-empty", "-m", "root"], cwd: url.path)
            }
            start = Date()
        }

        func write(_ name: String, born: Date, contents: String = "x\n") {
            let file = URL(fileURLWithPath: path).appendingPathComponent(name)
            try? contents.write(to: file, atomically: true, encoding: .utf8)
            // Both keys, because `untrackedFiles` prefers creation date and
            // falls back to modification date.
            try? FileManager.default.setAttributes(
                [.creationDate: born, .modificationDate: born], ofItemAtPath: file.path)
        }

        @discardableResult
        func git(_ arguments: [String]) -> String? {
            AgentReport.git(arguments, cwd: path)
        }

        func remove() { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: - 1. Redaction

    static func redaction() {
        Check.run("secret windows never leave the machine") {
            func v(_ app: String, _ title: String,
                   extra: [String] = []) -> ScreenRedaction.Verdict {
                ScreenRedaction.verdict(for: .init(app: app, title: title),
                                        extraTerms: extra, enabled: true)
            }
            Check.ok(v("1Password", "Personal Vault").isRedacted, "password manager by app")
            Check.ok(v("Keychain Access", "login").isRedacted, "keychain by app")
            Check.ok(v("Code", "~/proj/.env").isRedacted, "dotenv by title")
            Check.ok(v("Safari", "Private Browsing").isRedacted, "private browsing")
            Check.ok(v("Terminal", "cat id_ed25519").isRedacted, "private key by title")
            Check.ok(v("Chrome", "Reset your password").isRedacted, "password in title")

            Check.ok(!v("Code", "ScreenCaptureManager.swift").isRedacted, "ordinary editor allowed")
            Check.ok(!v("Safari", "Gemini Live API docs").isRedacted, "ordinary browsing allowed")
            Check.ok(!v("Spotify", "Discover Weekly").isRedacted, "music allowed")

            // Escape hatch without a rebuild.
            Check.ok(v("Safari", "acme payroll q3", extra: ["payroll"]).isRedacted,
                     "user term redacts")
            Check.ok(!v("Safari", "acme payroll q3").isRedacted, "…and only when configured")

            // Off switch honoured, but off is never the default.
            Check.ok(!ScreenRedaction.verdict(for: .init(app: "1Password", title: ""),
                                              enabled: false).isRedacted,
                     "disabling redaction is possible")
            Check.ok(v("1Password", "").reason != nil, "a redaction always explains itself")
        }
    }

    // MARK: - 2. Screen recall

    static func timeline() {
        Check.run("timeline records changes, samples stillness, and forgets") {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let m = ScreenMoment(at: t0, app: "Safari", title: "docs")
            Check.ok(ScreenTimeline.shouldRecord(previous: nil, app: "Safari", title: "docs",
                                                 now: t0), "first moment always recorded")
            Check.ok(ScreenTimeline.shouldRecord(previous: m, app: "Code", title: "docs",
                                                 now: t0.addingTimeInterval(1)),
                     "window change recorded immediately")
            Check.ok(!ScreenTimeline.shouldRecord(previous: m, app: "Safari", title: "docs",
                                                  now: t0.addingTimeInterval(5)),
                     "same window is not re-recorded every frame")
            Check.ok(ScreenTimeline.shouldRecord(previous: m, app: "Safari", title: "docs",
                                                 now: t0.addingTimeInterval(31)),
                     "…but is sampled eventually")

            let old = ScreenMoment(at: t0.addingTimeInterval(-7 * 3600), app: "Old", title: "x")
            let kept = ScreenTimeline.prune([old, m], now: t0)
            Check.ok(kept == [m], "stale moments are dropped")
            Check.ok(ScreenTimeline.prune((0..<50).map {
                ScreenMoment(at: t0.addingTimeInterval(Double(-$0)), app: "a", title: "b")
            }, now: t0, maxCount: 10).count == 10, "count is capped")
        }

        Check.run("recall finds the moment from the words people actually use") {
            let now = Date(timeIntervalSince1970: 2_000_000)
            func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
            let moments = [
                ScreenMoment(at: ago(90), app: "Safari", title: "Gemini Live API docs"),
                ScreenMoment(at: ago(40), app: "Terminal", title: "make test — build failed"),
                ScreenMoment(at: ago(5), app: "Spotify", title: "Discover Weekly"),
            ]
            Check.ok(ScreenTimeline.search(moments, query: "docs", now: now).first?.app == "Safari",
                     "matches on title word")
            Check.ok(ScreenTimeline.search(moments, query: "safari gemini", now: now).count == 1,
                     "all words must match")
            Check.ok(ScreenTimeline.search(moments, query: "nonsense", now: now).isEmpty,
                     "no false hit")
            Check.ok(ScreenTimeline.search(moments, query: "", within: 10, now: now).count == 1,
                     "empty query is a pure time slice")
            Check.ok(ScreenTimeline.search(moments, query: "", now: now).first?.app == "Spotify",
                     "newest first")

            let text = ScreenTimeline.describe(moments, now: now)
            Check.ok(text.contains("build failed"), "description carries the title")
            Check.ok(text.contains("ago"), "description is relative, not clock time")
            Check.ok(ScreenTimeline.describe([], now: now).contains("Nothing"),
                     "an empty recall says so rather than inventing")
        }

        Check.run("a window held open collapses to one line") {
            let now = Date(timeIntervalSince1970: 3_000_000)
            let held = (0..<10).map {
                ScreenMoment(at: now.addingTimeInterval(Double($0) * -60),
                             app: "Code", title: "main.swift")
            }
            let condensed = ScreenTimeline.condense(held)
            Check.ok(condensed.count == 1, "ten samples of one window are one entry")
            Check.ok(ScreenTimeline.describe(held, now: now).contains("held for"),
                     "and it reports how long it was up")
        }

        Check.run("redacted windows are remembered as nothing") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("kweku-timeline-test-\(UUID().uuidString)")
            let store = ScreenTimelineStore(directory: dir, frameInterval: 0)
            defer { try? FileManager.default.removeItem(at: dir) }

            store.record(app: "1Password", title: "Personal Vault",
                         jpeg: Data([1, 2, 3]), redacted: true)
            let saved = store.search(query: "", within: nil)
            Check.ok(saved.count == 1, "the moment still exists")
            Check.ok(saved[0].app == ScreenMoment.privateLabel, "but the app is not named")
            Check.ok(saved[0].title.isEmpty, "and the title is gone")
            Check.ok(saved[0].frame == nil, "and no pixels were written")
            Check.ok(store.search(query: "1password", within: nil).isEmpty,
                     "a redacted window is not findable by name")
        }
    }

    // MARK: - 3. Agent pit crew

    static func attention() {
        Check.run("only long, unannounced waits are worth interrupting for") {
            let now = Date(timeIntervalSince1970: 4_000_000)
            func session(_ id: String, _ state: AgentState, waitingFor: TimeInterval,
                         cwd: String = "/Users/o/sk-triage") -> AgentSession {
                AgentSession(id: id, cwd: cwd, pid: 1, state: state,
                             lastUpdated: now, stateSince: now.addingTimeInterval(-waitingFor),
                             source: "claude")
            }
            var ledger = AgentAttention.Ledger()

            // Fresh finish: they can see it, so say nothing.
            var out = AgentAttention.alerts(sessions: [session("a", .waiting, waitingFor: 5)],
                                            ledger: ledger, now: now)
            Check.ok(out.alerts.isEmpty, "a just-finished session is not announced")

            // Working forever is not a problem.
            out = AgentAttention.alerts(sessions: [session("a", .working, waitingFor: 9999)],
                                        ledger: ledger, now: now)
            Check.ok(out.alerts.isEmpty, "a busy session is never announced")

            // Stuck long enough: announce once.
            let stuck = session("a", .waiting, waitingFor: 300)
            out = AgentAttention.alerts(sessions: [stuck], ledger: ledger, now: now)
            Check.ok(out.alerts.count == 1, "a long wait is announced")
            Check.ok(out.alerts[0].fact.contains("sk-triage"), "names the project")
            Check.ok(out.alerts[0].fact.contains("claude"), "names the harness")
            ledger = out.ledger

            out = AgentAttention.alerts(sessions: [stuck], ledger: ledger, now: now)
            Check.ok(out.alerts.isEmpty, "the same wait is never announced twice")

            // Back to work, then stuck again: that's a new wait.
            ledger = AgentAttention.alerts(sessions: [session("a", .working, waitingFor: 1)],
                                           ledger: ledger, now: now).ledger
            out = AgentAttention.alerts(
                sessions: [session("a", .waiting, waitingFor: 300)], ledger: ledger, now: now)
            Check.ok(out.alerts.count == 1, "a new wait is announced again")

            // Never dump the whole table into one sentence.
            let many = (0..<6).map { session("s\($0)", .waiting, waitingFor: 300) }
            Check.ok(AgentAttention.alerts(sessions: many, ledger: .init(), now: now)
                        .alerts.count == 2, "at most two sessions per interruption")

            // Dead sessions must not accumulate in the ledger forever.
            var kept = AgentAttention.alerts(sessions: many, ledger: .init(), now: now).ledger
            kept = AgentAttention.alerts(sessions: [], ledger: kept, now: now).ledger
            Check.ok(kept == AgentAttention.Ledger(), "ledger forgets vanished sessions")
        }
    }

    // MARK: - 4. Unsolicited triage

    static func triage() {
        Check.run("triage speaks up for real failures, and rarely") {
            let now = Date(timeIntervalSince1970: 5_000_000)
            func go(_ app: String, _ title: String, state: TriageTrigger.State,
                    at when: Date = now, live: Bool = true,
                    busy: Bool = false) -> (Bool, TriageTrigger.State) {
                TriageTrigger.evaluate(app: app, title: title, state: state, now: when,
                                       sessionLive: live, busy: busy)
            }
            let fresh = TriageTrigger.State()

            Check.ok(go("Terminal", "make test — build failed", state: fresh).0,
                     "a failing build is worth mentioning")
            Check.ok(go("Terminal", "Traceback (most recent call last)", state: fresh).0,
                     "a traceback is worth mentioning")
            Check.ok(!go("Code", "ScreenCaptureManager.swift", state: fresh).0,
                     "ordinary work is left alone")

            // Reading *about* an error is not having one.
            Check.ok(!go("Safari", "swift - build failed on CI - Stack Overflow", state: fresh).0,
                     "researching an error does not trigger help")
            Check.ok(!go("Safari", "Build failed · Pull request #12 · GitHub", state: fresh).0,
                     "a PR page does not trigger help")

            // Never talk over Kweku, and never without a session.
            Check.ok(!go("Terminal", "build failed", state: fresh, live: false).0,
                     "silent with no Live session")
            Check.ok(!go("Terminal", "build failed", state: fresh, busy: true).0,
                     "never interrupts Kweku mid-sentence")

            // Restraint: same failure once, and a real gap between any two.
            let after = go("Terminal", "build failed", state: fresh).1
            Check.ok(!go("Terminal", "build failed", state: after,
                         at: now.addingTimeInterval(600)).0,
                     "the same failure is not raised twice")
            Check.ok(!go("Terminal", "tests failed", state: after,
                         at: now.addingTimeInterval(30)).0,
                     "a different failure still waits for the cooldown")
            Check.ok(go("Terminal", "tests failed", state: after,
                        at: now.addingTimeInterval(600)).0,
                     "…and is raised once the cooldown passes")

            // The notice carries what was *read* off the screen, never the
            // window title — a title alone is enough for the model to invent a
            // matching error over a completely unrelated frame.
            let evidence = "error: cannot find 'ScreenMomnt' in scope"
            let prompt = TriageTrigger.prompt(app: "Terminal", evidence: evidence)
            Check.ok(prompt.contains(evidence), "the notice carries the quoted error")
            Check.ok(prompt.contains("read directly off it"), "and says where it came from")
            Check.ok(prompt.contains("not from Omari"), "the notice is marked as system")
            Check.ok(prompt.contains("Do not invent"), "and forbids embellishment")
        }

        Check.run("a glance only speaks when it read something") {
            Check.ok(ScreenGlance.clean("NONE") == nil, "NONE means silence")
            Check.ok(ScreenGlance.clean(" none.\n") == nil, "…however it is punctuated")
            Check.ok(ScreenGlance.clean("   ") == nil, "empty means silence")
            Check.ok(ScreenGlance.clean("error: cannot find 'X' in scope")
                        == "error: cannot find 'X' in scope", "a real reading survives")

            let body = Data("""
                {"candidates":[{"content":{"parts":[{"text":"error: boom"}]}}]}
                """.utf8)
            Check.ok(ScreenGlance.text(from: body) == "error: boom", "parses a reading")
            Check.ok(ScreenGlance.text(from: Data("{}".utf8)) == nil, "survives a junk response")
        }
    }
}
