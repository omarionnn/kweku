import Foundation

/// A background event surfaced by the OpenClaw gateway.
public struct OpenClawEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case working, attention, info }
    public var kind: Kind
    public var summary: String
}

/// How a dispatched task resolved from the voice session's point of view.
public enum DispatchOutcome: Equatable, Sendable {
    /// Finished inside the grace window — speak this now.
    case completed(String)
    /// Still going. Speak the ack; the real answer arrives via `onLateResult`.
    case running(String)
    /// Never started.
    case failed(String)

    /// What goes back to Gemini as the tool response.
    public var toolResponse: String {
        switch self {
        case .completed(let text): return text
        case .running(let ack): return ack
        case .failed(let reason): return reason
        }
    }
}

/// Bridge to Omari's local OpenClaw engine.
///
/// One shared gateway websocket serves both consumers: `AgentWatchHub` (notch
/// reactions for *any* agent activity) and `LiveSessionController` (voice
/// dispatch). Sharing the socket means one handshake, one reconnect policy,
/// and one place where run state lives.
///
/// Dispatch is deliberately not blocking. A quick task answers inside the
/// grace window and Kweku just says the answer; a long one returns an
/// acknowledgement immediately so the conversation keeps moving, and the
/// result is spoken later as its own turn.
public final class OpenClawBridgeManager {

    public static let shared = OpenClawBridgeManager()

    private let client: GatewayClient
    private var backgroundHandler: ((OpenClawEvent) -> Void)?

    init(client: GatewayClient = GatewayClient()) {
        self.client = client
        self.client.onBackgroundEvent = { [weak self] event in self?.backgroundHandler?(event) }
    }

    // MARK: - Background events

    /// Start the shared connection and mirror gateway activity onto the notch.
    /// Silent and self-healing when the gateway isn't running.
    public func listenForBackgroundEvents(onEvent: @escaping (OpenClawEvent) -> Void) {
        backgroundHandler = onEvent
        client.start()
    }

    public func stopListening() {
        backgroundHandler = nil
        client.stop()
    }

    /// Bring the socket up without subscribing to notch events — used by the
    /// voice session so the first dispatch isn't paying for a cold handshake.
    public func warmUp() { client.start() }

    // MARK: - Dispatch

    /// Run one OpenClaw task.
    ///
    /// - Parameters:
    ///   - grace: how long to hold the voice turn hoping for a fast answer.
    ///     Past this, Kweku acknowledges and reports back later.
    ///   - onProgress: streaming status/partial text, for notch state.
    ///   - onLateResult: fires only when the run outlived the grace window.
    public func dispatch(instruction: String,
                         screenContext: String?,
                         screenshot: Data? = nil,
                         grace: TimeInterval = 6,
                         onProgress: @escaping (String) -> Void = { _ in },
                         onLateResult: @escaping (Result<String, GatewayError>) -> Void = { _ in })
        async -> DispatchOutcome
    {
        var message = instruction
        if let context = screenContext, !context.isEmpty {
            message += "\n\nOn-screen context:\n\(context)"
        }
        // The frame is the ground truth; the text above is Gemini's reading of
        // it. Say so, so the agent trusts its own eyes on any disagreement.
        let frame = (screenshot?.count ?? 0) <= GatewayProtocol.maxImageBytes ? screenshot : nil
        if frame != nil {
            message += "\n\nOmari's screen at the moment he asked is attached. "
                + "Trust the image over any description above it."
        }

        let state = DispatchState()

        return await withCheckedContinuation { continuation in
            client.dispatch(
                message,
                screenshot: frame,
                onProgress: { progress in
                    switch progress {
                    case .status(let phase): onProgress(phase)
                    case .delta(let text): onProgress(text)
                    case .final, .failed: break
                    }
                },
                onTerminal: { result in
                    // Landed in time: answer inline. Landed late: speak it later.
                    if state.claimInline() {
                        switch result {
                        case .success(let text):
                            continuation.resume(returning: .completed(Self.trim(text)))
                        case .failure(let error):
                            continuation.resume(returning: .failed(error.spoken))
                        }
                    } else {
                        onLateResult(result.map { Self.trim($0) })
                    }
                })

            DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
                guard state.claimDeferred() else { return }
                continuation.resume(returning: .running(
                    "Started — this one's going to take a moment. I'll tell you the moment it lands."))
            }
        }
    }

    /// Bounded so a long transcript can't blow up the voice turn.
    static func trim(_ text: String, limit: Int = 4000) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "(no output)" }
        return clean.count > limit ? String(clean.suffix(limit)) : clean
    }
}

/// Guards the one-shot continuation: whichever of the terminal event or the
/// grace timer arrives first wins, and the loser becomes the late path.
private final class DispatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// The run finished first.
    func claimInline() -> Bool { claim() }
    /// The grace window expired first.
    func claimDeferred() -> Bool { claim() }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
