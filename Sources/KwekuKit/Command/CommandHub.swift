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

    /// cwd of the session a "fix this" should land in. Supplied by the content
    /// root from the agent table, the same way the Live session gets it.
    public var agentCwdProvider: () -> String? = { nil }

    /// The app that was frontmost when the field took focus.
    ///
    /// Held because taking the keyboard changes what "the front window" means.
    /// Even a non-activating panel makes this ambiguous, and "fix the error on
    /// screen" must mean the screen you were looking at when you asked.
    @Published public private(set) var contextApp: String?

    private var runToken = 0

    public init() {}

    // MARK: - Focus

    /// Called as the field takes focus: remember what the user was looking at.
    public func captureContext() {
        contextApp = NSWorkspace.shared.frontmostApplication?.localizedName
    }

    public func clear() {
        state = .idle
        input = ""
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
        history = CommandFormat.remember(prompt, in: history)
        input = ""
        lastTarget = .openClaw

        let token = nextToken()
        Task { [weak self] in
            guard let self else { return }
            var shot: ScreenSnapshot.Shot?
            if withScreen {
                self.set(.reading, token: token)
                switch await ScreenSnapshot.capture() {
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
            switch await ScreenSnapshot.capture() {
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

            // The agent's own progress shows up on the notch anyway — the
            // headless run loads the watch extension, so the ember and the
            // agent panel light up for it like any other session.
            let output = await OMPBridgeManager.dispatchCommand(instruction, cwd: cwd)
            self.set(.result(text: CommandFormat.condense(output), ok: true), token: token)
        }
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
    }
}
