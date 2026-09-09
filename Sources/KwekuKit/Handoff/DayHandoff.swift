import Foundation

/// The end-of-day handoff: what today was, written down while it's still true.
///
/// The daily note in `memory/` is the thing that survives a session restart,
/// and it's kept by hand — which means it's kept on the days that were quiet
/// enough to remember to keep it. Kweku has better raw material than memory
/// does: it watched every session start, it knows which repos they ran in, and
/// git can say what actually landed in each one.
///
/// It drafts, it does not decide. The note goes to OpenClaw, which owns the
/// workspace and its conventions, with an instruction to append rather than
/// rewrite — a memory file is the one place where a confident overwrite costs
/// something that can't be rebuilt.
public enum DayHandoff {

    /// When the day gets written up. Late enough to have been a day.
    public static let defaultHour = 18

    /// User override, so changing the hour doesn't need a rebuild.
    public static var hour: Int {
        let stored = UserDefaults.standard.integer(forKey: "handoffHour")
        return (1...23).contains(stored) ? stored : defaultHour
    }

    // MARK: - Schedule

    /// Whether today's handoff is due: past the hour, and not already written
    /// today. Pure, so "does it fire twice" is a test rather than a wait.
    public static func due(now: Date, lastRun: Date?, hour: Int = DayHandoff.hour,
                           calendar: Calendar = .current) -> Bool {
        guard let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now),
              now >= fire else { return false }
        guard let lastRun else { return true }
        return lastRun < fire
    }

    // MARK: - The draft

    /// What one repo did today, as read from its working copy.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var cwd: String
        public var work: AgentReport.Work?

        public init(name: String, cwd: String, work: AgentReport.Work?) {
            self.name = name; self.cwd = cwd; self.work = work
        }
    }

    /// File the note belongs in, in the workspace's own convention.
    public static func fileName(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "memory/\(formatter.string(from: day)).md"
    }

    /// The instruction handed to OpenClaw.
    ///
    /// Everything factual is in the prompt already — the gateway is being asked
    /// to write it down, not to go and find out. The two hard rules are the
    /// ones a summary of a day gets wrong: don't append an entry that says
    /// nothing, and never rewrite what's already in the file, which may be
    /// this morning's notes written by hand.
    public static func prompt(day: Date, entries: [Entry], sessions: Int) -> String {
        let facts = entries.map { entry -> String in
            let did = AgentReport.summary(entry.work ?? AgentReport.Work())
                ?? "no committed or uncommitted change git can see"
            return "- \(entry.name) (\(entry.cwd)): \(did)"
        }.joined(separator: "\n")

        let counted = sessions == 1 ? "1 agent session" : "\(sessions) agent sessions"

        return """
            System notice, not from Omari — he did not ask for this. It is the \
            end-of-day handoff, and it is your job to write it.

            Today Kweku watched \(counted) across these working copies. Read \
            from git, not from any agent's account of itself:

            \(facts)

            Append a short entry to \(fileName(for: day)) in the workspace, \
            following the conventions in AGENTS.md. Rules:

            - Read the file first. Other notes from today may already be in it. \
            Append; never rewrite, reorder or delete an existing line.
            - Use the facts above plus anything you can verify yourself \
            (git log, the repos, your own session history). Do not invent \
            outcomes, test results or verdicts — a diff is not a judgement, and \
            "finished" is not the same as "worked".
            - If a repo did nothing worth recording, leave it out rather than \
            writing a line that says nothing happened.
            - If there is nothing worth recording at all, write nothing and say \
            so instead.
            - Keep it to what a future session would need to pick the day back \
            up: decisions, what changed, what's still open.

            Reply with one short line saying what you wrote, or that you wrote \
            nothing.
            """
    }
}

/// Keeps the day's working directories and fires the handoff once, on time.
///
/// Owned by `AgentWatchHub` because that is what already sees every session
/// appear and already has a timer ticking — a second clock for one event a day
/// would be its own small liability.
@MainActor
final class DayHandoffRunner {

    /// Repos an agent ran in today, and when the day started.
    private struct Day: Codable {
        var start: Date
        var cwds: [String]
        var lastRun: Date?
    }

    private var day: Day
    private let fileURL: URL
    private let calendar: Calendar

    /// Fired with the gateway's one-line answer, so the notch can react.
    var onFinished: ((String) -> Void)?

    init(fileURL: URL? = nil, calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kweku/handoff.json")
        let start = calendar.startOfDay(for: now)
        if let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode(Day.self, from: data),
           stored.start == start {
            day = stored
        } else {
            // A new day, or no record: yesterday's repos are not today's work.
            day = Day(start: start, cwds: [], lastRun: nil)
        }
    }

    /// Remember a repo an agent worked in. Called for every session the hub
    /// sees, so the list survives sessions that end before six o'clock.
    func note(cwd: String) {
        guard !cwd.isEmpty, !day.cwds.contains(cwd) else { return }
        day.cwds.append(cwd)
        save()
    }

    /// Roll over at midnight and fire when due. Safe to call on any tick.
    func tick(now: Date = Date()) {
        let start = calendar.startOfDay(for: now)
        if day.start != start {
            day = Day(start: start, cwds: [], lastRun: nil)
            save()
        }
        guard DayHandoff.due(now: now, lastRun: day.lastRun, calendar: calendar) else { return }
        run(now: now)
    }

    /// Write the day up now — the menu's "Write Today's Handoff".
    ///
    /// ponytail: one attempt per day, marked before dispatch, so a gateway
    /// that's down doesn't retry every thirty seconds until midnight. The
    /// manual path is the retry.
    func run(now: Date = Date(), sessions: [AgentSession] = []) {
        day.lastRun = now
        for session in sessions { note(cwd: session.cwd) }
        save()

        let cwds = day.cwds
        let counted = max(cwds.count, sessions.count)
        let dayStart = day.start
        Task.detached(priority: .utility) { [weak self] in
            // git on a handful of repos: never on the main thread.
            let entries = cwds.map { cwd in
                DayHandoff.Entry(name: (cwd as NSString).lastPathComponent, cwd: cwd,
                                 work: AgentReport.read(cwd: cwd, since: dayStart))
            }
            // A day where nothing touched a repo is not worth a dispatch.
            guard entries.contains(where: { $0.work?.isEmpty == false }) else { return }

            let outcome = await OpenClawBridgeManager.shared.dispatch(
                instruction: DayHandoff.prompt(day: dayStart, entries: entries, sessions: counted),
                screenContext: nil,
                onLateResult: { result in
                    Task { @MainActor in
                        if case .success(let text) = result { self?.finish(text) }
                    }
                })
            if case .completed(let text) = outcome {
                await self?.finish(text)
            }
        }
    }

    private func finish(_ text: String) { onFinished?(text) }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(day).write(to: fileURL, options: .atomic)
    }
}
