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
        triage()
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
