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

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.table.prune(isAlive: { pid in kill(pid, 0) == 0 || errno != ESRCH })
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
        case .gateway:
            return NSWorkspace.shared.open(GatewayProtocol.dashboardURL)
        case .unreachable:
            return false
        }
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

    /// Install the omp extension + Claude hooks (explicit user action).
    public func runSetup() {
        setup.installAll()
        setupDone = setup.allInstalled
    }
}
