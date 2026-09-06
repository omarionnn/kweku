import Foundation

/// Live websocket client for the OpenClaw Gateway.
///
/// Replaces the previous `openclaw agent` shell-out. What that bought us:
/// - **Streaming.** Runs report `status`/`delta`/`final`, so Kweku can react
///   while work is happening instead of blocking on one process exit.
/// - **Shared context.** Dispatches land in the real main session, so a voice
///   request and the desktop chat are one conversation.
/// - **Real events.** Background notch state comes from typed `chat` frames
///   rather than keyword-sniffing arbitrary JSON.
///
/// One socket, many runs: the gateway broadcasts `chat` events for *every*
/// session on this connection, so every handler is keyed by `runId` and
/// unrelated traffic is dropped.
public final class GatewayClient {

    public enum Status: Equatable, Sendable { case offline, connecting, ready, unauthorized }

    /// Called on the main queue whenever connection status changes.
    public var onStatus: ((Status) -> Void)?
    /// Any run's progress, including runs Kweku did not start (the desktop
    /// client, automations). Drives the notch ember/bang states.
    public var onBackgroundEvent: ((OpenClawEvent) -> Void)?

    private let url: URL
    private let sessionKey: String
    private let version: String

    private let queue = DispatchQueue(label: "com.kweku.gateway")
    private var task: URLSessionWebSocketTask?
    private var status: Status = .offline
    private var running = false
    private var nextRequestId = 0
    private var policy = ReconnectPolicy()

    /// Requests we're waiting on, by frame id.
    private var pendingRequests: [String: (GatewayPayload) -> Void] = [:]
    /// Live runs Kweku started, by runId.
    private var runs: [String: RunHandler] = [:]
    /// Dispatches queued while the socket was down, with their screenshots.
    private var backlog: [(String, Data?, RunHandler)] = []

    private struct RunHandler {
        let onProgress: (GatewayRunEvent.State) -> Void
        let onTerminal: (Result<String, GatewayError>) -> Void
        let startedAt: Date
    }

    public init(url: URL = GatewayProtocol.defaultURL,
                sessionKey: String = GatewayProtocol.defaultSessionKey,
                version: String = "0.1.0") {
        self.url = url
        self.sessionKey = sessionKey
        self.version = version
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.openSocket()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.failAllRuns(.disconnected)
            self.set(.offline)
        }
    }

    private func openSocket() {
        guard running else { return }
        guard let token = GatewayCredentials.token() else {
            retryUnauthorized()
            return
        }
        set(.connecting)
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receiveLoop()
        // The gateway opens with `connect.challenge`; the handshake continues
        // in `handle(_:)`. Stash the token for that moment only.
        pendingToken = token
    }

    private var pendingToken: String?

    private func scheduleReconnect() {
        guard running else { return }
        task = nil
        set(.offline)
        failAllRuns(.disconnected)
        retry(after: policy.next())
    }

    /// The token was missing from disk, or the gateway refused it.
    ///
    /// Deliberately *not* terminal. Kweku usually launches before the gateway,
    /// `openclaw.json` can be read mid-rewrite, and the token may be rotated
    /// while the app runs — all three are transient. This path used to just
    /// return, which left `running == true` with nothing scheduled: one bad
    /// read killed the bridge until the app was relaunched. Surface the state
    /// for the UI, then keep trying on a slower clock than a dropped socket.
    private func retryUnauthorized() {
        guard running else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        set(.unauthorized)
        failAllRuns(.unauthorized)
        retry(after: policy.next(unauthorized: true))
    }

    private func retry(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { self.openSocket() }
    }

    // MARK: - Dispatch

    /// Start an agent turn. `onProgress` fires for each status/delta;
    /// `onTerminal` fires exactly once. Both are called on the main queue.
    public func dispatch(_ message: String,
                         screenshot: Data? = nil,
                         timeout: TimeInterval = 900,
                         onProgress: @escaping (GatewayRunEvent.State) -> Void,
                         onTerminal: @escaping (Result<String, GatewayError>) -> Void) {
        let handler = RunHandler(
            onProgress: { state in DispatchQueue.main.async { onProgress(state) } },
            onTerminal: { result in DispatchQueue.main.async { onTerminal(result) } },
            startedAt: Date())

        queue.async {
            guard self.status == .ready else {
                // Queue it and make sure we're trying to connect.
                self.backlog.append((message, screenshot, handler))
                if !self.running { self.running = true; self.openSocket() }
                if self.status == .unauthorized { self.drainBacklog(failingWith: .unauthorized) }
                return
            }
            self.send(message, screenshot: screenshot, handler: handler)
            self.queue.asyncAfter(deadline: .now() + timeout) {
                guard let run = self.runs.first(where: { $0.value.startedAt == handler.startedAt })
                else { return }
                self.runs.removeValue(forKey: run.key)
                run.value.onTerminal(.failure(.timedOut))
            }
        }
    }

    private func send(_ message: String, screenshot: Data?, handler: RunHandler) {
        let runId = "kweku-\(UUID().uuidString)"
        runs[runId] = handler
        let frameId = nextId()
        pendingRequests[frameId] = { [weak self] payload in
            guard let self else { return }
            switch payload {
            case .runStarted(let actualRunId):
                // The gateway echoes our idempotency key as the runId, but
                // alias defensively in case that ever stops being true.
                if actualRunId != runId, let h = self.runs.removeValue(forKey: runId) {
                    self.runs[actualRunId] = h
                }
            case .error(let code, let message):
                if let h = self.runs.removeValue(forKey: runId) {
                    h.onTerminal(.failure(.rejected(code: code, message: message)))
                }
            default:
                break
            }
        }
        transmit(GatewayProtocol.chatSend(id: frameId, sessionKey: sessionKey,
                                          message: message, idempotencyKey: runId,
                                          screenshot: screenshot))
    }

    private func drainBacklog(failingWith error: GatewayError? = nil) {
        let queued = backlog
        backlog.removeAll()
        for (message, screenshot, handler) in queued {
            if let error {
                handler.onTerminal(.failure(error))
            } else {
                send(message, screenshot: screenshot, handler: handler)
            }
        }
    }

    // MARK: - Frame handling

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure:
                    self.scheduleReconnect()
                case .success(let message):
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: data = Data()
                    }
                    if let frame = GatewayProtocol.parse(data) { self.handle(frame) }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ frame: GatewayFrame) {
        switch frame {
        case .challenge:
            guard let token = pendingToken else { return }
            pendingToken = nil
            let id = nextId()
            pendingRequests[id] = { [weak self] payload in
                guard let self else { return }
                if case .helloOK = payload {
                    self.transmit(GatewayProtocol.subscribe(id: self.nextId(),
                                                            sessionKey: self.sessionKey))
                    self.policy.reset()
                    self.set(.ready)
                    self.drainBacklog()
                } else if case .error = payload {
                    // Answer anything already queued before tearing the socket
                    // down, so a waiting voice turn hears why it failed.
                    self.drainBacklog(failingWith: .unauthorized)
                    self.retryUnauthorized()
                }
            }
            transmit(GatewayProtocol.connect(id: id, token: token, version: version))

        case .response(let id, _, let payload):
            pendingRequests.removeValue(forKey: id)?(payload)

        case .event(_, let payload):
            guard case .run(let event) = payload else { return }
            publishBackground(event)
            guard let handler = runs[event.runId] else { return }   // another session's run
            if event.isTerminal { runs.removeValue(forKey: event.runId) }
            switch event.state {
            case .status, .delta:
                handler.onProgress(event.state)
            case .final(let text):
                handler.onTerminal(.success(text))
            case .failed(let message):
                handler.onTerminal(.failure(.runFailed(message)))
            }
        }
    }

    /// Mirror every run — ours and everyone else's — onto the notch.
    private func publishBackground(_ event: GatewayRunEvent) {
        let mapped: OpenClawEvent
        switch event.state {
        case .status(let phase): mapped = OpenClawEvent(kind: .working, summary: phase)
        case .delta: return                                    // too noisy for the notch
        case .final(let text): mapped = OpenClawEvent(kind: .attention, summary: summarize(text))
        case .failed(let message): mapped = OpenClawEvent(kind: .attention, summary: message)
        }
        DispatchQueue.main.async { self.onBackgroundEvent?(mapped) }
    }

    private func summarize(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    // MARK: - Plumbing

    private func nextId() -> String {
        nextRequestId += 1
        return "k\(nextRequestId)"
    }

    private func transmit(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async { self.scheduleReconnect() }
        }
    }

    private func set(_ next: Status) {
        guard status != next else { return }
        status = next
        DispatchQueue.main.async { self.onStatus?(next) }
    }

    private func failAllRuns(_ error: GatewayError) {
        let active = runs
        runs.removeAll()
        for (_, handler) in active { handler.onTerminal(.failure(error)) }
    }
}

/// Exponential backoff for reconnects, kept pure so the retry contract is
/// testable without a live gateway — the defect this guards against (a
/// credential failure that never retried) was invisible until relaunch.
struct ReconnectPolicy {
    static let baseDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 60
    /// Credential failures start slower: re-reading a config file every second
    /// is pointless, and hammering the gateway with a bad token is worse.
    static let unauthorizedFloor: TimeInterval = 5

    private(set) var delay: TimeInterval = baseDelay

    /// The delay to wait *now*, doubling what the next caller will get.
    mutating func next(unauthorized: Bool = false) -> TimeInterval {
        let current = unauthorized ? Swift.max(delay, Self.unauthorizedFloor) : delay
        delay = Swift.min(current * 2, Self.maxDelay)
        return current
    }

    /// Called on a successful handshake so a later blip starts fast again.
    mutating func reset() { delay = Self.baseDelay }
}

/// Failure modes worth telling the user about out loud.
public enum GatewayError: Error, Equatable, Sendable {
    case unauthorized
    case disconnected
    case timedOut
    case rejected(code: String, message: String)
    case runFailed(String)

    /// Phrasing meant to be spoken, not logged.
    public var spoken: String {
        switch self {
        case .unauthorized:
            return "I can't reach your OpenClaw engine — the gateway token is missing or rejected."
        case .disconnected:
            return "I lost the connection to OpenClaw before that finished."
        case .timedOut:
            return "That task ran long and I stopped waiting on it."
        case .rejected(_, let message):
            return "OpenClaw refused that: \(message)"
        case .runFailed(let message):
            return "That task failed: \(message)"
        }
    }
}
