import AppKit
import Combine

/// Orchestrates a Kweku Live session: websocket + mic/speaker + screen
/// stream + omp tool dispatch. Owned by `NotchContentRoot`; started/stopped
/// from the right-click menu (all permission prompts are lazy — they fire on
/// the user's first Start).
@MainActor
public final class LiveSessionController: ObservableObject {
    @Published public private(set) var running = false

    /// Where the socket is in its lifecycle. See `LivePhase` for why this is no
    /// longer the same field as the screen-capture health.
    @Published public private(set) var phase: LivePhase = .idle

    /// What Kweku can see right now — the window being streamed, whether it's
    /// being blanked, or why there's nothing at all.
    @Published public private(set) var vision: LiveVision = .pending

    /// When the current session started, for the panel's clock.
    @Published public private(set) var startedAt: Date?

    /// One short line for the right-click menu. Derived, so it can't disagree
    /// with what the notch is showing.
    public var status: String { phase.label }

    /// What Kweku is currently saying — drives the caption ticker. Accumulates
    /// through a turn and clears when the turn ends or the user barges in.
    @Published public private(set) var caption = ""
    /// What Kweku currently hears Omari saying. Interim fragments are
    /// replaced wholesale by the final transcript for the same utterance.
    @Published public private(set) var heard = ""

    /// True while audio is actually draining to the speaker. Published so the
    /// rim can tell "Kweku is talking" from "a Live session happens to be
    /// open" — two states the old single `running` flag couldn't separate.
    @Published public private(set) var speaking = false

    /// True from the moment Omari stops talking until Kweku starts. It is the
    /// one beat of a voice conversation with nothing to see or hear, and it's
    /// where the whole "is this thing working?" doubt lives — so the notch
    /// spends it wearing the thinking rim instead of the idle Live glow.
    @Published public private(set) var composing = false

    /// Backstop for `composing`: every path that ends a turn clears it, but a
    /// silently dropped turn must not leave the aurora burning indefinitely.
    private var composeWatchdog: DispatchWorkItem?
    private let composeCeiling: TimeInterval = 45

    /// Interim transcripts are a running best guess, so they replace rather
    /// than append; finals are fragments of one utterance, so they accumulate.
    private var heardIsInterim = false

    /// Set across `interruptPlayback()` so the speaking-stopped callback can
    /// tell a barge-in from a natural drain.
    private var interrupting = false

    public let audio = AudioEngineManager()
    private let screen = ScreenCaptureManager()
    private let client = GeminiLiveClient()

    /// Local, on-disk record of what has been on screen. Survives the session
    /// so "what was that error before lunch?" outlives the conversation it
    /// wasn't asked in.
    public let timeline = ScreenTimelineStore()

    /// Cooldown state for unsolicited triage.
    private var triage = TriageTrigger.State()

    /// Cooldown state for unsolicited offers to fill in a form, and the timer
    /// that goes looking for one. Separate from triage's state on purpose: a
    /// build that just broke and a signup page he just opened are not competing
    /// for the same silence, and sharing a cooldown would let one mute the other.
    private var formWatch = FormWatch.State()
    private var formTimer: Timer?

    /// Omari's own details, read from disk at launch. Only the field *names*
    /// ever reach the model; `fillField` resolves values locally.
    private let profile = PersonalProfile()

    // A+B memory: rolling local transcript + session-resumption handle.
    private var memory = ConversationMemory()
    private var resumeHandle: String?
    private var reconnectAttempts = 0

    /// A vision failure that landed before the socket was live. The permission
    /// check runs during `start()`, well ahead of `setupComplete`, so the note
    /// waits here rather than being dropped by the not-yet-live send guard —
    /// the one session where it matters most is the one that never saw a frame.
    private var pendingVisionNote: String?

    /// Whether this socket was opened believing it could see. A session that
    /// started blind already says so in its system instruction, and must not
    /// also be handed a notice — `clientText` completes a turn, so it would
    /// make Kweku announce the bad news unprompted the moment it connects.
    private var connectedWithVision = false

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
        // `connectSocket` reads the key itself; this is only the early exit.
        guard Self.apiKey != nil else { phase = .failed(reason: "no API key"); return false }

        client.onEvent = { [weak self] event in self?.handle(event) }
        client.onClose = { [weak self] reason in
            MainActor.assumeIsolated { self?.connectionClosed(reason) }
        }
        connectSocket(fresh: true)
        // Handshake the gateway now so the first dispatch isn't paying for a
        // cold connect mid-sentence.
        OpenClawBridgeManager.shared.warmUp()

        audio.onMicChunk = { [weak self] chunk in self?.client.sendAudioChunk(chunk) }
        audio.onSpeakingChanged = { [weak self] speaking in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.speaking = speaking
                // Sound coming out is the definitive end of the thinking beat,
                // whatever the transcript events did or didn't say.
                if speaking { self.setComposing(false) }
                // A natural drain means the sentence was fully said, so the
                // transcripts can go. A barge-in is handled by `.interrupted`,
                // which must not wipe `heard` out from under a live utterance.
                if !speaking && !self.interrupting { self.clearTranscripts() }
            }
        }
        do { try audio.start() } catch {
            phase = .failed(reason: "audio failed: \(error.localizedDescription)")
            client.disconnect()
            return false
        }
        screen.onIssue = { [weak self] issue in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Vision has its own axis now: a capture failure no longer
                    // wipes out the line saying the session itself is healthy.
                    self.vision = .unavailable(reason: issue)
                    // A status line is easy to miss, and a blind Kweku that
                    // doesn't know it's blind narrates the screen from its
                    // prompt instead. Tell the model directly so the failure
                    // is spoken aloud rather than papered over.
                    self.noteVisionUnavailable(issue)
                }
            }
        }
        // Everything that goes out is also offered to the timeline; the store
        // throttles, so this stays a cheap call on the frame path.
        screen.onMoment = { [weak self] app, title, jpeg, redacted in
            self?.timeline.record(app: app, title: title, jpeg: jpeg, redacted: redacted)
        }
        // Switching to a window that looks broken is the moment to offer help
        // unprompted — see `TriageTrigger` for why this is so heavily muzzled.
        screen.onAim = { [weak self] app, title, redacted in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Publish what's being streamed before anything else decides
                // whether to act on it: the user is entitled to see which
                // window is leaving the machine, redacted or not.
                self.vision = .watching(app: app, title: title, redacted: redacted)
                guard !redacted else { return }
                let (fire, next) = TriageTrigger.evaluate(
                    app: app, title: title, state: self.triage, now: Date(),
                    sessionLive: self.running, busy: self.speaking || self.composing)
                self.triage = next
                guard fire else { return }
                self.triageCurrentScreen(app: app)
            }
        }
        screen.startStreaming { [weak self] jpeg in self?.client.sendVideoFrame(jpeg) }
        startWatchingForForms()

        running = true
        startedAt = Date()
        phase = .connecting
        // A session that opens without Screen Recording is blind from the
        // start, and says so before the first frame would have arrived.
        vision = ScreenCaptureManager.hasScreenAccess
            ? .pending
            : .unavailable(reason: ScreenCaptureManager.permissionIssue)
        return true
    }

    /// Stop by hand: the session ended because you said so, so it leaves no
    /// error behind.
    public func stop() { stop(keepingReason: false) }

    /// `keepingReason` holds on to the `closed:`/`failed:` phase the caller
    /// just set, so a session that died on its own can still say why — while a
    /// session you stopped yourself doesn't leave a stale error in the menu.
    private func stop(keepingReason: Bool) {
        guard running else { return }
        pendingVisionNote = nil
        formTimer?.invalidate()
        formTimer = nil
        screen.stop()
        audio.stop()
        client.disconnect()
        running = false
        startedAt = nil
        speaking = false
        if !keepingReason { phase = .idle }
        vision = .pending
        setComposing(false)
        clearTranscripts()
        memory.save()
    }

    // MARK: - Notch controls

    /// Cut Kweku off mid-sentence from the notch, without having to talk over
    /// it. Mirrors a spoken barge-in: playback is dropped and the caption goes,
    /// but `heard` is left alone because the user is about to fill it.
    @discardableResult
    public func hush() -> Bool {
        guard running, speaking else { return false }
        interrupting = true
        audio.interruptPlayback()
        interrupting = false
        setComposing(false)
        screen.noteUserTurn()
        caption = ""
        return true
    }

    /// Switch the microphone off and on. The session stays up — this is the
    /// "hold on a second" button, not the stop button.
    public func toggleMute() {
        guard running else { return }
        audio.setMuted(!audio.micMuted)
    }

    /// Enter or leave the thinking beat, arming the watchdog on the way in so
    /// a turn that dies without a terminal event still releases the rim.
    private func setComposing(_ on: Bool) {
        composeWatchdog?.cancel(); composeWatchdog = nil
        if composing != on { composing = on }
        // Re-arm on every entry, not just the transition: each fresh fragment
        // is proof the turn is still alive, so the ceiling measures silence
        // since the last sign of life rather than since the turn began.
        guard on else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setComposing(false) }
        }
        composeWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + composeCeiling, execute: work)
    }

    /// Wipe Kweku's long-term conversational memory (menu action).
    public func forgetConversations() {
        memory.clear()
    }

    /// Wipe the screen timeline (menu action). Separate from conversations:
    /// a record of every window you've had open deserves its own off switch.
    public func forgetScreenHistory() {
        timeline.clear()
    }

    /// Say something Omari didn't ask for — a waiting agent, a broken build.
    ///
    /// Refused while Kweku already has the floor: `clientText` completes a
    /// turn, so interrupting its own sentence is the one way to make a helpful
    /// notice feel like a malfunction.
    @discardableResult
    public func interject(_ prompt: String) -> Bool {
        guard running, !speaking, !composing else { return false }
        client.sendClientText(prompt)
        return true
    }

    /// Read the current screen for a real failure, and only then speak.
    ///
    /// The window title decided it was worth looking; this decides whether
    /// there is anything to say. A glance that comes back empty ends here in
    /// silence, which is the common case and the point.
    private func triageCurrentScreen(app: String) {
        guard let key = Self.apiKey, let frame = screen.latestFrame() else { return }
        Task { [weak self] in
            guard let finding = await ScreenGlance.inspect(
                jpeg: frame, prompt: ScreenGlance.triagePrompt, apiKey: key) else { return }
            await MainActor.run {
                _ = self?.interject(TriageTrigger.prompt(app: app, evidence: finding))
            }
        }
    }

    /// Start looking for a form he could be handed.
    ///
    /// Nothing here needs the camera: the offer is decided from the
    /// Accessibility tree, so it still works in a session that opened blind,
    /// and it costs no frames and no tokens until there is something to say.
    private func startWatchingForForms() {
        formTimer?.invalidate()
        guard FormWatch.enabled, !profile.isEmpty else { return }
        let timer = Timer(timeInterval: FormScan.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForForm() }
        }
        // `.common`, so the search doesn't stall while a menu is open — the
        // right-click menu is one of the ways he gets here in the first place.
        RunLoop.main.add(timer, forMode: .common)
        formTimer = timer
    }

    /// One pass: read the window in front of him, decide, and maybe speak.
    ///
    /// The cheap guards are checked here rather than inside the scan so that a
    /// session where Kweku is mid-sentence costs nothing at all — the common
    /// case for this timer is having no work to do.
    private func lookForForm() {
        guard running, !speaking, !composing else { return }
        let holding = Set(profile.knownKeys)
        guard !holding.isEmpty else { return }
        // Accessibility reads block, and a window can hold a few hundred of
        // them. Off the main thread, where they can't judder the notch; only
        // the verdict comes back, so nothing thread-hostile crosses over.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let form = FormScan.frontmost(holding: holding) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.offerToFill(form) }
            }
        }
    }

    @MainActor
    private func offerToFill(_ form: FormScan.Form) {
        let (fire, next) = FormWatch.evaluate(
            form: form, state: formWatch, now: Date(),
            sessionLive: running, busy: speaking || composing)
        formWatch = next
        guard fire else { return }
        _ = interject(FormWatch.prompt(form: form))
    }

    /// Answer a `recall_screen` tool call from the local timeline.
    ///
    /// Window titles answer "what was I doing"; they cannot answer "what did
    /// that error say". For the latter the saved frame has to actually be
    /// read — and pushing it onto the video feed does not work, because the
    /// tool response resumes a turn that cannot see that feed. So the frame is
    /// read here and the reading is returned as text.
    private func recallScreen(_ args: [String: String]) async -> String {
        let query = args["query"] ?? ""
        let minutes = args["minutes_ago"].flatMap(Double.init)
        let now = Date()
        let hits = timeline.search(query: query, within: minutes, now: now)
        let text = ScreenTimeline.describe(hits, now: now)
        guard let best = hits.first,
              let frame = timeline.frameData(for: best),
              let key = Self.apiKey,
              let seen = await ScreenGlance.inspect(
                  jpeg: frame, prompt: ScreenGlance.recallPrompt, apiKey: key)
        else { return text }

        return text + "\n\nWhat the saved frame from "
            + "\(ScreenTimeline.relative(from: best.at, to: now)) actually showed:\n\(seen)"
    }

    /// Answer a `fill_field` tool call by typing a saved detail into the field
    /// Omari has focused.
    ///
    /// The value is read here and typed here; what goes back to the model is
    /// only whether it landed. Echoing the filled text into the tool response
    /// would put his email in the transcript and hand it to the very model the
    /// profile is kept away from — so a success says which field, not what.
    @MainActor
    private func fillField(_ args: [String: String]) -> String {
        guard let field = args["field"], !field.isEmpty else {
            return "No field was named, so nothing was typed."
        }
        let replacing = (args["replace_existing"] ?? "").lowercased() == "true"
        switch FieldFill.fill(label: field, from: profile, replacing: replacing) {
        case .filled(let key):
            return "Typed his \(key.replacingOccurrences(of: "_", with: " ")) into the focused "
                + "field. Confirm it landed and move on; do not read the value back."
        case .refused(let refusal):
            return "Not typed. Tell him: \(refusal.spoken)"
        }
    }

    /// Connect (or reconnect) the Gemini socket. `fresh` starts a new
    /// conversation seeded with the memory recap; a reconnect passes the
    /// resumption handle so the server restores the same session.
    private func connectSocket(fresh: Bool) {
        guard let key = Self.apiKey else { return }
        // Decided here, before the socket opens: a session that cannot see
        // must not be told that it can, or it will invent a screen rather than
        // admit the permission is missing.
        let canSee = ScreenCaptureManager.hasScreenAccess
        connectedWithVision = canSee
        let system = GeminiLiveProtocol.systemInstruction(
            visionAvailable: canSee,
            visionIssue: canSee ? nil : ScreenCaptureManager.permissionIssue,
            profileFields: profile.knownKeys)
            + (memory.recap() ?? "")
        client.connect(apiKey: key, model: Self.model,
                       system: system,
                       resumeHandle: fresh ? nil : resumeHandle)
    }

    /// Dropped socket: resume in place when we hold a handle (10-min server
    /// caps, network blips). Gives up after 3 consecutive failures.
    private func connectionClosed(_ reason: String) {
        guard running else { return }
        if resumeHandle != nil, reconnectAttempts < 3 {
            reconnectAttempts += 1
            phase = .resuming(attempt: reconnectAttempts)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.connectSocket(fresh: false)
                }
            }
        } else {
            phase = .closed(reason: reason)
            stop(keepingReason: true)
        }
    }
    private func handle(_ event: GeminiServerEvent) {
        switch event {
        case .setupComplete:
            phase = .live
            reconnectAttempts = 0
            // Also replayed after a resume: the new socket knows nothing about
            // a capture failure raised on the old one.
            if let note = pendingVisionNote { client.sendClientText(note) }
        case .resumptionHandle(let handle):
            resumeHandle = handle
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
            setComposing(false)          // Omari has the floor back
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
                memory.append(role: "Omari", fragment: text)
                // A finalised fragment means Omari's utterance has landed and
                // the turn is Kweku's now. Interim guesses don't count — they
                // arrive while he's still mid-word.
                setComposing(true)
            }

        case .spokenTranscript(let text):
            setComposing(false)          // words are forming; the beat is over
            caption += text
            memory.append(role: "Kweku", fragment: text)
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
                case "recall_screen":
                    output = await self?.recallScreen(args) ?? "The screen timeline is unavailable."
                case "fill_field":
                    output = await self?.fillField(args) ?? "Kweku went away mid-task."
                default:
                    output = "unknown tool \(name)"
                }
                self?.client.sendToolResponse(id: id, name: name, output: output)
            }
        case .goAway:
            phase = .closed(reason: "server ending session")
        case .turnComplete:
            setComposing(false)          // nothing more is coming for this turn
            audio.flushPlayback()        // play out the sub-block tail
            screen.noteUserTurn()        // user's turn: next frame is fresh
            memory.save()                // cheap; keeps memory crash-safe
            // Deliberately *not* clearing the caption here. `turnComplete`
            // means the model finished generating, not that Omari finished
            // hearing it — the speaker is usually still playing the tail.
            // `onSpeakingChanged`'s falling edge clears it at the real end.
            // The fallback covers turns that produced no audio at all (a
            // tool-call-only turn, or audio that never started).
            if !audio.isSpeaking { clearTranscripts() }
        }
    }

    /// Record a mid-session vision failure and tell the model, now or at
    /// `setupComplete`. A session that opened blind is already covered by its
    /// system instruction, which is the only thing that reliably holds.
    private func noteVisionUnavailable(_ reason: String) {
        guard connectedWithVision else { return }
        let note = GeminiLiveProtocol.visionUnavailableNote(reason)
        pendingVisionNote = note
        client.sendClientText(note)   // no-op until the socket is live
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
