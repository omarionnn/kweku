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
    }

    deinit {
        pruneTimer?.invalidate()
        server.stop()
    }

    public var anyWorking: Bool { table.anyWorking }
    public var anyWaiting: Bool { table.anyWaiting }

    /// Click-to-focus the most relevant session's terminal window.
    public func focusCurrent() {
        guard let target = table.focusTarget() else { return }
        TerminalFocus.focus(session: target)
    }

    /// Install the omp extension + Claude hooks (explicit user action).
    public func runSetup() {
        setup.installAll()
        setupDone = setup.allInstalled
    }
}
