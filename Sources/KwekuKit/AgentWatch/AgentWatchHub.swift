import AppKit
import Combine

/// Owns the socket server + session table and publishes the aggregate signals
/// the creature reacts to. Also drives click-to-focus and setup state.
@MainActor
public final class AgentWatchHub: ObservableObject {
    @Published public private(set) var table = AgentSessionTable()
    @Published public private(set) var setupDone: Bool

    private let server = AgentSocketServer()
    private let setup = AgentWatchSetup()
    private var pruneTimer: Timer?
    private let openClaw = OpenClawBridgeManager.shared
    private var externalCleanup: [String: DispatchWorkItem] = [:]
    private var attention = AgentAttention.Ledger()
    /// When each session was first observed, so a report can say what changed
    /// since — pruned with the table so it can't grow forever.
    private var firstSeen: [String: Date] = [:]

    /// Raised when a background session has sat waiting long enough to be
    /// worth saying out loud. The payload is a ready-made instruction for the
    /// Live conversation; leave it nil and the notch stays silent as before.
    public var onAttention: ((String) -> Void)?

    /// The same event, structured, for anything that wants the facts rather
    /// than a paragraph to speak. The notch's own drops read this: a spoken
    /// report and a line under the cutout are the same news in two registers,
    /// and both should come off one read of the working copy rather than two.
    public var onReports: (([(session: AgentSession, work: AgentReport.Work?)]) -> Void)?

    public init() {
        setupDone = setup.allInstalled

        // Socket dir is guaranteed by ShelfStore's support-dir bootstrap, but
        // be independent of ordering:
        let sockPath = AgentWatchSetup.socketPath
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: sockPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        server.start(path: sockPath) { [weak self] line in
            MainActor.assumeIsolated {
                guard let self, let event = AgentEvent.parse(line) else { return }
                self.table.apply(event)
            }
        }

        // Pruning and the attention sweep share a tick: both only ever act on
        // sessions that have been sitting still, so a 30s granularity is
        // exactly the resolution either one deserves.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.table.prune(isAlive: { pid in kill(pid, 0) == 0 || errno != ESRCH })
                self.sweepAttention()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer

        // OpenClaw gateway background events -> notch states (silent when the
        // gateway isn't installed/running; reconnects on its own).
        openClaw.listenForBackgroundEvents { [weak self] event in
            MainActor.assumeIsolated {
                switch event.kind {
                case .working:
                    // A working event's summary *is* the gateway's status
                    // phase, so it can pick the notch's phase too.
                    self?.noteExternal(id: "openclaw", state: .working,
                                       activity: .fromPhase(event.summary))
                case .attention: self?.noteExternal(id: "openclaw", state: .waiting)
                case .info: break
                }
            }
        }
    }

    deinit {
        pruneTimer?.invalidate()
        server.stop()
        openClaw.stopListening()
    }

    public var anyWorking: Bool { table.anyWorking }
    public var anyWaiting: Bool { table.anyWaiting }

    /// Click-to-focus the most relevant session — the one the exclamation eyes
    /// are about, since `focusTarget` ranks waiting sessions first.
    /// Returns false when there was nothing to open, so the caller can say so
    /// rather than letting the click land on silence.
    @discardableResult
    public func focusCurrent() -> Bool {
        guard let target = table.focusTarget() else { return false }
        return focus(target)
    }

    /// Go to one specific session — the agent panel's row action.
    ///
    /// Routes on where the session actually lives. A gateway session has no
    /// process and no window; sending it through `TerminalFocus` walks a
    /// parent-pid chain from 0 and always fails, which is why clicking a
    /// waiting OpenClaw session used to do nothing at all.
    @discardableResult
    public func focus(_ session: AgentSession) -> Bool {
        switch session.destination {
        case .terminal:
            return TerminalFocus.focus(session: session)
        case .gateway, .unreachable:
            // Nowhere to go. Gateway sessions are headless children of the
            // OpenClaw LaunchAgent — no terminal, no window, no app. Sending
            // the click to the Control UI only lands on its auth wall, which
            // is a worse answer than admitting there's nothing to open.
            return false
        }
    }

    /// Open the session's working directory in Finder — the row action for
    /// "which repo is this, actually". Silently does nothing for gateway and
    /// synthetic sessions, which have no directory of their own.
    @discardableResult
    public func reveal(_ session: AgentSession) -> Bool {
        guard !session.cwd.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
        return true
    }

    /// Interrupt a running session — exactly what Ctrl-C in its terminal does.
    ///
    /// Deliberately `SIGINT` and not `SIGKILL`: agents catch it, unwind, and
    /// leave their transcript intact, so a mis-click on a 14-point button costs
    /// a turn rather than an hour of work. Only sessions with a real process
    /// can be interrupted; gateway sessions have no pid to signal.
    @discardableResult
    public func interrupt(_ session: AgentSession) -> Bool {
        guard session.pid > 0, case .terminal = session.destination else { return false }
        return kill(session.pid, SIGINT) == 0
    }

    /// Whether the interrupt action applies — used to hide the button rather
    /// than offer one that can't work.
    public func canInterrupt(_ session: AgentSession) -> Bool {
        guard session.pid > 0, case .terminal = session.destination else { return false }
        return session.state == .working
    }

    /// Feed a synthetic session (OpenClaw / voice dispatches) into the same
    /// table so ember/bang reactions and priority apply uniformly. `waiting`
    /// entries self-clean after 2 minutes.
    public func noteExternal(id: String, state: AgentState,
                             activity: AgentActivity? = nil) {
        table.apply(AgentEvent(sessionID: id, cwd: "", pid: 0, state: state,
                               activity: activity))
        externalCleanup[id]?.cancel()
        guard state == .waiting else { externalCleanup[id] = nil; return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.table.apply(AgentEvent(sessionID: id, cwd: "", pid: 0, state: .idle, gone: true))
                self?.externalCleanup[id] = nil
            }
        }
        externalCleanup[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    /// Look for sessions that have been waiting long enough to mention.
    ///
    /// The ledger is what keeps this from becoming a nag: each stretch of
    /// waiting is announced at most once, and a session that goes back to work
    /// clears its own record.
    private func sweepAttention() {
        let now = Date()
        // Baseline for "what did it do": commits are counted from when this
        // session first appeared. Recorded before the early return so the
        // clock starts when Kweku noticed the session, not when it first had
        // something to say about it.
        for id in table.sessions.keys where firstSeen[id] == nil { firstSeen[id] = now }
        firstSeen = firstSeen.filter { table.sessions[$0.key] != nil }

        guard onAttention != nil || onReports != nil else { return }
        let (alerts, ledger) = AgentAttention.alerts(
            sessions: Array(table.sessions.values), ledger: attention, now: now)
        attention = ledger
        guard !alerts.isEmpty else { return }

        // git is disk I/O on someone else's repo — never on the main thread,
        // and never blocking the notch's run loop.
        let entries = alerts.compactMap { alert -> (AgentSession, Date)? in
            guard let session = table.sessions[alert.sessionID] else { return nil }
            return (session, firstSeen[alert.sessionID] ?? session.stateSince)
        }
        Task.detached(priority: .utility) { [weak self] in
            let read = entries.map { ($0.0, AgentReport.read(cwd: $0.0.cwd, since: $0.1)) }
            await MainActor.run {
                self?.onReports?(read)
                self?.onAttention?(AgentReport.prompt(for: read, now: now))
            }
        }
    }

    /// Install the omp extension + Claude hooks (explicit user action).
    public func runSetup() {
        setup.installAll()
        setupDone = setup.allInstalled
    }
}
