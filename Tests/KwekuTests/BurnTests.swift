import Foundation
import KwekuKit

/// The three pieces of the day's-work features that are pure enough to pin:
/// pricing a turn off a transcript line, deciding when the handoff is due, and
/// flattening a reply into something safe to type at a terminal.
enum BurnTests {
    static func all() {
        parsing()
        pricing()
        labels()
        handoffSchedule()
        replySanitising()
        liveScan()
    }

    /// Opt-in read of the real transcripts, same as `GatewayLiveCheck`:
    ///
    ///     KWEKU_LIVE_BURN=1 swift run KwekuTests
    ///
    /// Off by default so `make test` stays offline and deterministic. The
    /// parsing above is pinned against fixed lines; this is the only thing
    /// that says the scanner finds the files at all.
    static func liveScan() {
        guard ProcessInfo.processInfo.environment["KWEKU_LIVE_BURN"] != nil else {
            print("- live burn scan: skipped (set KWEKU_LIVE_BURN=1 to run)")
            return
        }
        let meter = BurnMeter()
        let first = meter.refresh()
        print("- today: \(BurnTotals.money(first.dollars)) · "
              + "\(BurnTotals.tokens(first.tokens)) tok · \(first.breakdown(limit: 6))")
        // Offsets are the whole point of holding the meter: a second pass
        // seconds later must not double what the first one counted.
        let second = meter.refresh()
        Check.eq(second.dollars, first.dollars, accuracy: 0.05,
                 "re-reading must not re-count what it already read")
    }

    // MARK: Reading the transcripts

    /// Both lines are the real shapes, trimmed: Claude Code writes the
    /// Anthropic usage block verbatim, omp writes its own costed one.
    static let claudeLine = """
        {"type":"assistant","timestamp":"2026-09-07T21:29:43.340Z",\
        "cwd":"/Users/omarinyarko/Desktop/sidekick","sessionId":"abc",\
        "message":{"role":"assistant","model":"claude-opus-5","usage":{\
        "input_tokens":2,"output_tokens":580,"cache_read_input_tokens":47179,\
        "cache_creation_input_tokens":17846,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":17846}}}}
        """

    static let ompLine = """
        {"type":"message","timestamp":"2026-09-01T13:55:06.753Z","message":{\
        "role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{\
        "input":2,"output":1246,"cacheRead":0,"cacheWrite":31975,"totalTokens":33223,\
        "cost":{"input":0.00001,"output":0.03115,"cacheRead":0,"cacheWrite":0.199843,\
        "total":0.231003},"cttl":{"ephemeral5m":31975}}}}
        """

    static func parsing() {
        Check.run("a Claude turn is read with its cache split by TTL") {
            guard let entry = BurnMeter.parse(line: claudeLine) else {
                return Check.ok(false, "the line should parse")
            }
            Check.ok(entry.project == "sidekick", "project comes from the cwd, not the folder name")
            Check.ok(entry.model == "claude-opus-5", "model carried through for pricing")
            Check.ok(entry.usage.cacheWrite1h == 17846, "the hour-TTL write is the expensive one")
            Check.ok(entry.usage.cacheWrite5m == 0, "and it must not be counted twice")
            Check.ok(entry.usage.tokens == 2 + 580 + 47179 + 17846, "every token counts")
        }

        Check.run("omp's own costing is preferred over the price table") {
            guard let entry = BurnMeter.parse(line: ompLine) else {
                return Check.ok(false, "the line should parse")
            }
            // It knows what it was billed; this file only knows list prices.
            Check.eq(entry.dollars, 0.231003, accuracy: 0.000001, "reported cost wins")
            Check.ok(entry.project.isEmpty, "omp lines carry no cwd — the folder supplies it")
        }

        Check.run("everything that isn't a billed turn is skipped") {
            Check.ok(BurnMeter.parse(line: "{\"type\":\"user\",\"message\":{}}") == nil,
                     "a user turn costs nothing to receive")
            Check.ok(BurnMeter.parse(line: "not json at all") == nil, "garbage is not a turn")
            Check.ok(BurnMeter.parse(line:
                "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":5}}}") == nil,
                     "no timestamp means it can't be placed in a day")
        }

        Check.run("a transcript folder names its project") {
            Check.ok(BurnMeter.projectName(fromDirectory: "-Users-omarinyarko-Desktop-sidekick")
                        == "sidekick", "the tail is the part anyone reads")
            // Two dashes in a row: the encoded path had a dot-directory in it.
            Check.ok(BurnMeter.projectName(fromDirectory: "-Users-omarinyarko--openclaw-workspace")
                        == "workspace", "empty segments don't win")
        }
    }

    // MARK: Pricing

    static func pricing() {
        Check.run("cache traffic is priced off input, at its own rates") {
            // 1M of each against Opus 5's $5 input: read a tenth, 5m write
            // 1.25×, 1h write double.
            let usage = BurnUsage(input: 1_000_000, output: 0, cacheWrite5m: 1_000_000,
                                  cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
            Check.eq(ModelPrice.dollars(usage, model: "claude-opus-5"),
                     5 + 6.25 + 10 + 0.5, accuracy: 0.001, "5 + 1.25× + 2× + 0.1×")
        }

        Check.run("output is priced apart from input") {
            let usage = BurnUsage(input: 0, output: 1_000_000)
            Check.eq(ModelPrice.dollars(usage, model: "claude-sonnet-5"), 10, accuracy: 0.001,
                     "sonnet 5 output")
            Check.eq(ModelPrice.dollars(usage, model: "claude-haiku-4-5"), 5, accuracy: 0.001,
                     "haiku output")
        }

        Check.run("an unknown model still counts tokens but claims no dollars") {
            let usage = BurnUsage(input: 1_000, output: 1_000)
            Check.eq(ModelPrice.dollars(usage, model: "<synthetic>"), 0, accuracy: 0.0001,
                     "silence beats a made-up number")
            Check.ok(usage.tokens == 2_000, "the tokens are still real")
        }
    }

    // MARK: Labels

    static func labels() {
        Check.run("money reads at a glance and drops cents when they stop mattering") {
            Check.ok(BurnTotals.money(0) == "$0", "nothing spent")
            Check.ok(BurnTotals.money(0.4237) == "$0.42", "small numbers keep their cents")
            Check.ok(BurnTotals.money(12.4) == "$12.40", "and so do the everyday ones")
            Check.ok(BurnTotals.money(341.7) == "$342", "past a hundred, cents are noise")
        }

        Check.run("token counts stay short enough for the row") {
            Check.ok(BurnTotals.tokens(820) == "820", "small counts are exact")
            Check.ok(BurnTotals.tokens(12_400) == "12k", "thousands")
            Check.ok(BurnTotals.tokens(3_200_000) == "3.2M", "millions keep one decimal")
            Check.ok(BurnTotals.tokens(24_000_000) == "24M", "until they don't need it")
        }

        Check.run("the breakdown names the expensive repos first") {
            let totals = BurnTotals(dollars: 11, tokens: 100, byProject: [
                .init(name: "sidekick", dollars: 7.1, tokens: 60),
                .init(name: "notch", dollars: 3.9, tokens: 40),
            ])
            Check.ok(totals.breakdown() == "sidekick $7.10 · notch $3.90",
                     "which agent is eating the day, got \(totals.breakdown())")
            Check.ok(totals.breakdown(limit: 1) == "sidekick $7.10", "and it truncates")
        }
    }

    // MARK: The handoff clock

    static func handoffSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day,
                                               hour: hour, minute: minute))!
        }

        Check.run("nothing is written before the hour") {
            Check.ok(!DayHandoff.due(now: at(17, 59), lastRun: nil, hour: 18, calendar: calendar),
                     "a day isn't over at 17:59")
        }
        Check.run("it fires once past the hour") {
            Check.ok(DayHandoff.due(now: at(18, 1), lastRun: nil, hour: 18, calendar: calendar),
                     "due")
        }
        Check.run("and not again for the rest of the evening") {
            Check.ok(!DayHandoff.due(now: at(22), lastRun: at(18, 1), hour: 18, calendar: calendar),
                     "one handoff a day, not one every thirty seconds")
        }
        Check.run("yesterday's run doesn't satisfy today") {
            Check.ok(DayHandoff.due(now: at(18, 5), lastRun: at(18, 30, day: 6),
                                    hour: 18, calendar: calendar),
                     "each day gets its own note")
        }

        Check.run("the note goes to the day's own memory file") {
            Check.ok(DayHandoff.fileName(for: at(18)) == "memory/2026-09-07.md",
                     "the workspace convention, got \(DayHandoff.fileName(for: at(18)))")
        }

        Check.run("the draft carries git's account and forbids a rewrite") {
            let work = AgentReport.Work(files: 2, insertions: 30, deletions: 4,
                                        commits: ["Add the burn meter"], branch: "main")
            let prompt = DayHandoff.prompt(
                day: at(18),
                entries: [.init(name: "notch", cwd: "/Users/x/Desktop/notch", work: work)],
                sessions: 3)
            Check.ok(prompt.contains("Add the burn meter"), "the commit subject is the evidence")
            Check.ok(prompt.contains("memory/2026-09-07.md"), "and it names the file")
            Check.ok(prompt.contains("never rewrite"), "a memory file is appended to, never redone")
            Check.ok(prompt.contains("3 agent sessions"), "how much of a day it was")
        }
    }

    // MARK: Answering an agent

    static func replySanitising() {
        Check.run("a reply becomes one typeable line") {
            Check.ok(AgentReply.sanitize("  yes, go ahead  ") == "yes, go ahead", "trimmed")
            // A newline mid-reply would submit the first half and leave the
            // rest for the TUI to interpret as commands.
            Check.ok(AgentReply.sanitize("use the worktree\nnot master")
                        == "use the worktree not master", "newlines fold into spaces")
            Check.ok(AgentReply.sanitize("stop\u{0003}now") == "stop now",
                     "^C is not something a reply gets to say")
        }
        Check.run("an empty reply is not a reply") {
            Check.ok(AgentReply.sanitize("   \n\t ") == nil, "nothing to send")
            Check.ok(AgentReply.sanitize("") == nil, "still nothing")
        }

        var table = AgentSessionTable()
        func session(id: String, pid: Int32, state: AgentState) -> AgentSession {
            table.apply(AgentEvent(sessionID: id, cwd: "/tmp/repo", pid: pid, state: state))
            return table.sessions[id]!
        }

        Check.run("any session in a real window can be answered") {
            Check.ok(AgentReply.canReply(to: session(id: "a", pid: 4321, state: .waiting)),
                     "the case the feature exists for")
            // A working agent still reads stdin: the line queues and is taken
            // at the next prompt, which is the whole point of saying it early.
            Check.ok(AgentReply.canReply(to: session(id: "b", pid: 4321, state: .working)),
                     "and the one worth catching before it finishes")
            Check.ok(AgentReply.canReply(to: session(id: "c", pid: 4321, state: .idle)),
                     "idle is still a live prompt")
            Check.ok(!AgentReply.canReply(to: session(id: "openclaw", pid: 0, state: .waiting)),
                     "the gateway session has no window to type into")
        }
    }
}
