import AppKit
import Combine

/// Orchestrates a Kweku Live session: websocket + mic/speaker + screen
/// stream + omp tool dispatch. Owned by `NotchContentRoot`; started/stopped
/// from the right-click menu (all permission prompts are lazy — they fire on
/// the user's first Start).
@MainActor
public final class LiveSessionController: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var status = ""

    /// What Kweku is currently saying — drives the caption ticker. Accumulates
    /// through a turn and clears when the turn ends or the user barges in.
    @Published public private(set) var caption = ""
    /// What Kweku currently hears Omari saying. Interim fragments are
    /// replaced wholesale by the final transcript for the same utterance.
    @Published public private(set) var heard = ""

    /// Interim transcripts are a running best guess, so they replace rather
    /// than append; finals are fragments of one utterance, so they accumulate.
    private var heardIsInterim = false

    /// Set across `interruptPlayback()` so the speaking-stopped callback can
    /// tell a barge-in from a natural drain.
    private var interrupting = false

    public let audio = AudioEngineManager()
    private let screen = ScreenCaptureManager()
    private let client = GeminiLiveClient()

    /// Supplied by the content root: cwd of the most relevant agent session.
    public var ompCwdProvider: () -> String? = { nil }
    /// Feed voice-dispatched work into the agent table (ember/bang states).
    public var externalActivity: ((String, AgentState) -> Void)?

    public init() {}

    // MARK: - API key / model (env overrides defaults)

    public static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty { return env }
        let stored = UserDefaults.standard.string(forKey: "geminiApiKey")
        return (stored?.isEmpty == false) ? stored : nil
    }

    public static func storeAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "geminiApiKey")
    }

    static var model: String {
        UserDefaults.standard.string(forKey: "geminiLiveModel") ?? GeminiLiveProtocol.defaultModel
    }

    // MARK: - Lifecycle

    /// Returns false when no API key is configured.
    @discardableResult
    public func start() -> Bool {
        guard !running else { return true }
        guard let key = Self.apiKey else { status = "no API key"; return false }

        client.onEvent = { [weak self] event in self?.handle(event) }
        client.onClose = { [weak self] reason in
            MainActor.assumeIsolated {
                self?.status = "closed: \(reason)"
                self?.stop()
            }
        }
        client.connect(apiKey: key, model: Self.model)
        // Handshake the gateway now so the first dispatch isn't paying for a
        // cold connect mid-sentence.
        OpenClawBridgeManager.shared.warmUp()

        audio.onMicChunk = { [weak self] chunk in self?.client.sendAudioChunk(chunk) }
        audio.onSpeakingChanged = { [weak self] speaking in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A natural drain means the sentence was fully said, so the
                // transcripts can go. A barge-in is handled by `.interrupted`,
                // which must not wipe `heard` out from under a live utterance.
                if !speaking && !self.interrupting { self.clearTranscripts() }
            }
        }
        do { try audio.start() } catch {
            status = "audio failed: \(error.localizedDescription)"
            client.disconnect()
            return false
        }
        screen.onIssue = { [weak self] issue in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.status = issue }
            }
        }
        screen.startStreaming { [weak self] jpeg in self?.client.sendVideoFrame(jpeg) }

        running = true
        status = "connecting"
        return true
    }

    public func stop() {
        guard running else { return }
        screen.stop()
        audio.stop()
        client.disconnect()
        running = false
        clearTranscripts()
    }

    // MARK: - Event routing

    private func handle(_ event: GeminiServerEvent) {
        switch event {
        case .setupComplete:
            status = "live"
        case .audio(let pcm):
            audio.enqueuePlayback(pcm)
        case .interrupted:
            // Flagged across the call so the speaking-stopped callback can
            // tell this from a natural finish; `interruptPlayback` drops the
            // queue synchronously, so the flag is only held for that instant.
            interrupting = true
            audio.interruptPlayback()
            interrupting = false

            screen.noteUserTurn()        // user barged in: refresh their view
            // Only the caption: barge-in means Omari is mid-sentence, so
            // `heard` is actively filling and must not be wiped under him.
            caption = ""

        case .heardTranscript(let text, let interim):
            if interim {
                heard = text
                heardIsInterim = true
            } else {
                heard = heardIsInterim ? text : heard + text
                heardIsInterim = false
            }

        case .spokenTranscript(let text):
            caption += text
        case .toolCall(let id, let name, let args):
            let cwd = ompCwdProvider()
            Task { [weak self] in
                let output: String
                switch name {
                case "execute_omp_command":
                    // omp reactions ride the kweku-watch extension events.
                    output = await OMPBridgeManager.dispatchCommand(args["prompt"] ?? "", cwd: cwd)
                case "dispatch_openclaw_action":
                    output = await self?.dispatchToOpenClaw(args) ?? "Kweku went away mid-task."
                default:
                    output = "unknown tool \(name)"
                }
                self?.client.sendToolResponse(id: id, name: name, output: output)
            }
        case .goAway:
            status = "server ending session"
        case .turnComplete:
            audio.flushPlayback()        // play out the sub-block tail
            screen.noteUserTurn()        // user's turn: next frame is fresh
            // Deliberately *not* clearing the caption here. `turnComplete`
            // means the model finished generating, not that Omari finished
            // hearing it — the speaker is usually still playing the tail.
            // `onSpeakingChanged`'s falling edge clears it at the real end.
            // The fallback covers turns that produced no audio at all (a
            // tool-call-only turn, or audio that never started).
            if !audio.isSpeaking { clearTranscripts() }
        }
    }

    /// Wipe both transcript strings. Called when playback genuinely drains,
    /// and on teardown.
    private func clearTranscripts() {
        caption = ""
        heard = ""
        heardIsInterim = false
    }

    // MARK: - OpenClaw dispatch

    /// Hand a task to the OpenClaw engine over the shared gateway socket.
    ///
    /// Fast tasks answer inline. Slow ones return an acknowledgement so the
    /// conversation isn't held hostage by a long build, and the real result is
    /// injected later as its own turn for Kweku to speak.
    private func dispatchToOpenClaw(_ args: [String: String]) async -> String {
        externalActivity?("openclaw", .working)

        let outcome = await OpenClawBridgeManager.shared.dispatch(
            instruction: args["instruction"] ?? "",
            screenContext: args["screen_context"],
            // Gemini's `screen_context` is prose about the screen; this is the
            // screen. Nil when capture isn't permitted, which degrades to the
            // old description-only behaviour rather than failing.
            screenshot: screen.latestFrame(),
            onLateResult: { [weak self] result in
                guard let self else { return }
                self.externalActivity?("openclaw", .waiting)
                switch result {
                case .success(let text):
                    self.client.sendClientText(
                        "The OpenClaw task you dispatched just finished. Tell Omari the outcome "
                        + "in one or two spoken sentences.\n\nResult:\n\(text)")
                case .failure(let error):
                    self.client.sendClientText(
                        "The OpenClaw task you dispatched failed. Tell Omari briefly.\n\n\(error.spoken)")
                }
            })

        if case .running = outcome {
            // Still in flight: leave the ember lit until the late result lands.
            return outcome.toolResponse
        }
        externalActivity?("openclaw", .waiting)
        return outcome.toolResponse
    }
}
