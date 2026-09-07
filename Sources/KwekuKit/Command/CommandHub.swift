import AppKit
import Combine

/// The notch's command line.
///
/// Everything Kweku can do on this machine already existed — `OpenClawBridgeManager`
/// reaches the whole gateway toolbox, `OMPBridgeManager` runs a coding agent in
/// any repo, `ScreenGlance` reads a frame — and all of it was reachable only by
/// starting a voice session and saying it out loud. This is the same capability
/// with a text box in front of it, so it works in a meeting, and so you can
/// paste an error instead of reading one aloud.
@MainActor
public final class CommandHub: ObservableObject {
    @Published public var input = ""
    @Published public private(set) var state: CommandState = .idle
    @Published public private(set) var history: [String] = []
    /// Where the last dispatch went, so the panel can say so.
    @Published public private(set) var lastTarget: CommandTarget?
    /// The prompt behind the current result, kept so it can be run again or
    /// handed on. `input` is cleared on send, so without this a finished
    /// command has nothing left to re-run.
    @Published public private(set) var lastPrompt = ""

    /// cwd of the session a "fix this" should land in. Supplied by the content
    /// root from the agent table, the same way the Live session gets it.
    public var agentCwdProvider: () -> String? = { nil }

    /// Feed typed work into the agent table, exactly as the voice session does.
    ///
    /// A command typed at the notch is the same kind of thing as one spoken at
    /// it or started in a terminal: it should light the ember, appear in the
    /// session list and be clickable, rather than being a private event inside
    /// one panel.
    public var externalActivity: ((String, AgentState) -> Void)?

    /// The app that was frontmost when the field took focus.
    ///
    /// Held because taking the keyboard changes what "the front window" means.
    /// Even a non-activating panel makes this ambiguous, and "fix the error on
    /// screen" must mean the screen you were looking at when you asked.
    @Published public private(set) var contextApp: String?
    /// The window that was in front at the same moment, pinned by id.
    ///
    /// Named rather than re-resolved, because ⌥Space activates Kweku to get
    /// the keystrokes and from then on the frontmost window is Kweku's own
    /// panel. Reading the screen has to mean the screen you were looking at
    /// when you asked, not the box you asked in.
    @Published public private(set) var contextWindowID: UInt32?

    private var runToken = 0

    public init() {}

    // MARK: - Focus

    /// Called as the field takes focus: remember what the user was looking at.
    public func captureContext() {
        let front = NSWorkspace.shared.frontmostApplication
        // Never record ourselves. Summoning activates Kweku, so a second
        // ⌥Space while the panel is already up would otherwise name Kweku as
        // the app you were looking at and pin its own panel as the screen to
        // read. When we're already in front, the context captured on the way
        // in is still the true one.
        guard front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        contextApp = front?.localizedName
        contextWindowID = ScreenSnapshot.frontmostWindowID()
    }

    public func clear() {
        state = .idle
        input = ""
    }

    /// Put the panel back to a fresh prompt without touching the draft.
    public func dismissResult() {
        if case .result = state { state = .idle }
    }

    /// The finished text on screen, if there is one.
    public var resultText: String? {
        if case .result(let text, _) = state { return text }
        return nil
    }

    // MARK: - Ask

    /// Send the typed instruction to OpenClaw.
    ///
    /// `withScreen` attaches the focused window, which is what makes "what does
    /// this error mean" work at all — the gateway is told to trust the image
    /// over any text description.
    public func send(withScreen: Bool) {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !state.isBusy else { return }
        input = ""
        dispatch(prompt: prompt, withScreen: withScreen)
    }

    /// Run the finished command again, unchanged. The common case after a
    /// flaky tool or a gateway that was busy the first time.
    public func rerun() {
        guard !state.isBusy, !lastPrompt.isEmpty else { return }
        dispatch(prompt: lastPrompt, withScreen: false)
    }

    private func dispatch(prompt: String, withScreen: Bool) {
        history = CommandFormat.remember(prompt, in: history)
        lastPrompt = prompt
        lastTarget = .openClaw
        externalActivity?(AgentSession.gatewayID, .working)

        let token = nextToken()
        Task { [weak self] in
            guard let self else { return }
            var shot: ScreenSnapshot.Shot?
            if withScreen {
                self.set(.reading, token: token)
                switch await ScreenSnapshot.capture(pinned: self.contextWindowID) {
                case .success(let s): shot = s
                case .failure(let failure):
                    // A refused screen doesn't cancel the command — the
                    // instruction may not have needed the picture. Say what
                    // happened and carry on without it.
                    self.set(.running(phase: failure.message), token: token)
                }
            }
            self.set(.running(phase: "dispatching"), token: token)

            let outcome = await OpenClawBridgeManager.shared.dispatch(
                instruction: prompt,
                screenContext: shot.map { "Frontmost window: \($0.app) — \($0.title)" },
                screenshot: shot?.jpeg,
                onProgress: { [weak self] phase in
                    Task { @MainActor in self?.set(.running(phase: phase), token: token) }
                },
                onLateResult: { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success(let text):
                            self?.set(.result(text: CommandFormat.condense(text), ok: true),
                                      token: token)
                        case .failure(let error):
                            self?.set(.result(text: error.spoken, ok: false), token: token)
                        }
                    }
                })

            switch outcome {
            case .completed(let text):
                self.set(.result(text: CommandFormat.condense(text), ok: true), token: token)
            case .running(let ack):
                // Deliberately not a result: `onLateResult` is still coming,
                // and showing this as finished would be a lie the panel then
                // has to take back.
                self.set(.running(phase: CommandFormat.condense(ack, limit: 90)), token: token)
            case .failed(let reason):
                self.set(.result(text: reason, ok: false), token: token)
            }
        }
    }

    // MARK: - Fix what's on screen

    /// Read the failure on screen and hand it to a coding agent in the repo.
    ///
    /// Three things that already existed, wired end to end: a one-shot capture,
    /// a vision read, and a headless agent in a working directory. The chain
    /// stops at the first honest "nothing here" rather than inventing work.
    public func fixWhatsOnScreen() {
        guard !state.isBusy else { return }
        guard let key = LiveSessionController.apiKey else {
            state = .result(text: "Reading the screen needs a Gemini API key — "
                            + "set one from the notch menu.", ok: false)
            return
        }
        let cwd = agentCwdProvider()
        lastTarget = .agent(cwd: cwd)

        let token = nextToken()
        Task { [weak self] in
            guard let self else { return }
            self.set(.reading, token: token)

            let shot: ScreenSnapshot.Shot
            switch await ScreenSnapshot.capture(pinned: self.contextWindowID) {
            case .success(let s): shot = s
            case .failure(let failure):
                self.set(.result(text: failure.message, ok: false), token: token)
                return
            }

            guard let error = await ScreenGlance.inspect(
                jpeg: shot.jpeg, prompt: ScreenGlance.fixPrompt, apiKey: key) else {
                self.set(.result(text: "No failure I can read on \(shot.app).", ok: false),
                         token: token)
                return
            }

            self.set(.running(phase: "handed to \(CommandTarget.agent(cwd: cwd).label)"),
                     token: token)
            let instruction = CommandFormat.fixInstruction(error: error, app: shot.app)
            history = CommandFormat.remember("fix: \(error)", in: history)
            self.lastPrompt = instruction

            // The agent's own progress shows up on the notch anyway — the
            // headless run loads the watch extension, so the ember and the
            // agent panel light up for it like any other session.
            let output = await OMPBridgeManager.dispatchCommand(instruction, cwd: cwd)
            self.set(.result(text: CommandFormat.condense(output), ok: true), token: token)
        }
    }

    // MARK: - Verbs on a finished command

    /// Hand the finished command, and what came back, to a coding agent.
    ///
    /// The escalation people actually want: OpenClaw could reach the machine
    /// but couldn't change the repo, so the answer is a description of a
    /// problem rather than a fix. This carries both across in one move.
    public func escalateToAgent() {
        guard !state.isBusy, !lastPrompt.isEmpty else { return }
        let cwd = agentCwdProvider()
        let instruction = CommandFormat.escalation(prompt: lastPrompt,
                                                   result: resultText ?? "")
        lastTarget = .agent(cwd: cwd)

        let token = nextToken()
        Task { [weak self] in
            guard let self else { return }
            self.set(.running(phase: "handed to \(CommandTarget.agent(cwd: cwd).label)"),
                     token: token)
            let output = await OMPBridgeManager.dispatchCommand(instruction, cwd: cwd)
            self.set(.result(text: CommandFormat.condense(output), ok: true), token: token)
        }
    }

    /// The answer, on the pasteboard. The panel truncates and the notch is
    /// small; a result you can't get out of it is half an answer.
    public func copyResult() {
        guard let text = resultText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Run bookkeeping

    /// Each dispatch takes a token; late callbacks from an abandoned run are
    /// dropped rather than overwriting the current one. Without this a slow
    /// gateway result would land on top of whatever you asked next.
    private func nextToken() -> Int {
        runToken += 1
        return runToken
    }

    private func set(_ next: CommandState, token: Int) {
        guard token == runToken else { return }
        state = next
        // A finished gateway command is a session that now wants reading —
        // same signal the voice path sends, so the notch behaves identically
        // whether the work was typed or spoken. Agent runs report themselves
        // through the watch extension and must not be double-counted here.
        if case .result = next, lastTarget == .openClaw {
            externalActivity?(AgentSession.gatewayID, .waiting)
        }
    }
}
