import Foundation

/// Events Kweku receives over the Live websocket.
public enum GeminiServerEvent: Equatable, Sendable {
    case setupComplete
    case audio(Data)                                  // 24kHz 16-bit PCM mono
    case toolCall(id: String, name: String, args: [String: String])
    case interrupted                                  // user barge-in: flush playback
    case turnComplete
    case goAway
    /// What Omari said. `interim` marks a low-latency partial that a later
    /// final transcript supersedes.
    case heardTranscript(text: String, interim: Bool)
    /// What Kweku is saying, for the caption ticker.
    case spokenTranscript(text: String)
    /// Fresh session-resumption handle; store the latest and reconnect with it.
    case resumptionHandle(String)
}

/// Pure wire-format builders + parser for the Gemini Live (BidiGenerateContent)
/// protocol. No I/O here — fully unit-tested.
public enum GeminiLiveProtocol {

    public static let defaultModel = "models/gemini-2.5-flash-native-audio-preview-12-2025"

    /// Kweku's speaking voice. Without an explicit `speechConfig` the server
    /// picks a default per session, so the voice changes from one connect to
    /// the next — pinning it is what keeps him sounding like one person.
    /// Override without a rebuild:
    /// `defaults write com.omari.Kweku liveVoice Puck`.
    public static var voiceName: String {
        UserDefaults.standard.string(forKey: "liveVoice") ?? "Charon"
    }
    public static let endpointBase =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private static let persona = """
        You are Kweku, an elite personal developer companion living inside \
        Omari's MacBook notch. You are sharp, developer-native, concise, and \
        highly action-oriented. You listen and talk verbally, execute terminal \
        tasks in oh-my-pi, and run complex browser/OS automations through your \
        OpenClaw runtime engine. Address Omari naturally as his companion.
        """

    /// The persona, told the truth about whether it can currently see.
    ///
    /// A blind session cannot be patched up mid-conversation. Told "you can
    /// see Omari's screen in real time" and then handed no frames, the model
    /// reaches for the most screen-shaped things in its context — oh-my-pi, a
    /// terminal, an editor — and narrates one with total confidence. Measured
    /// against the live API: a later "your vision is unavailable" notice does
    /// *not* stop it, and neither does a standing "never guess" rule. Only
    /// withdrawing the claim of sight does.
    ///
    /// So sight is decided before the socket opens and stated once, plainly.
    public static func systemInstruction(visionAvailable: Bool = true,
                                         visionIssue: String? = nil) -> String {
        guard visionAvailable else {
            let reason = visionIssue ?? "Screen Recording permission is not granted to Kweku"
            return persona + """


                IMPORTANT — you are currently blind. Your screen vision is off \
                for this session (\(reason)), so you are receiving no screen \
                frames at all and have no idea what is on his display. Do not \
                describe, name, or guess any app, window, file, or content on \
                his screen. If he asks what he is looking at, tell him you \
                cannot see his screen right now, give that reason, and point \
                him at System Settings › Privacy & Security › Screen Recording \
                to enable Kweku and restart you. Never invent a screen.
                """
        }
        return persona + """


            You can also see Omari's screen in real time. Describe only what is \
            actually in a screen frame you have received — never infer his \
            screen from this prompt, from the tools you have, or from earlier \
            conversation. If you have not received a frame, say so rather than \
            guessing; naming the wrong app is worse than admitting you missed it.

            Some windows are deliberately withheld — password managers, files \
            with secrets, private browsing. Those arrive as a "Screen hidden" \
            card. When you see one, just tell him that window is private and \
            you can't see it; never speculate about what it contained.

            You also remember what has been on his screen. When he asks what he \
            was doing, what an earlier error or page said, or to find something \
            he saw before, call `recall_screen` instead of guessing — your \
            memory of his screen is real and searchable, so use it.
            """
    }

    /// Default sighted persona, for callers that don't decide sight themselves.
    public static var systemInstruction: String { systemInstruction() }

    /// Best-effort notice when vision dies *mid*-session, where the system
    /// instruction is already fixed. Weaker than starting blind — proven not
    /// to fully suppress confabulation on its own — so it backs up the status
    /// line rather than being the guarantee.
    public static func visionUnavailableNote(_ reason: String) -> String {
        "System notice, not from Omari: your live screen vision just became "
            + "unavailable (\(reason)). You are no longer receiving screen frames. "
            + "Do not describe or guess what is on his screen. If he asks what he "
            + "is looking at, tell him you cannot see it right now and give this reason."
    }

    // MARK: - Client → server frames

    /// Session setup: model, AUDIO responses, system instruction, tools
    /// (OpenClaw dispatcher + omp executor + Google Search).
    public static func setup(model: String, system: String = systemInstruction,
                             resumeHandle: String? = nil) -> Data {
        var resumption: [String: Any] = [:]
        if let resumeHandle { resumption["handle"] = resumeHandle }
        let frame: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]],
                    ],
                ],
                "systemInstruction": ["parts": [["text": system]]],
                // Ask for periodic resumption handles so a dropped/limited
                // connection can continue the same conversation.
                "sessionResumption": resumption,
                // Empty config = automatic language detection. Enables the
                // caption ticker: without these the server sends audio only.
                "inputAudioTranscription": [String: String](),
                "outputAudioTranscription": [String: String](),
                "tools": [
                    [
                        "functionDeclarations": [
                            [
                                "name": "dispatch_openclaw_action",
                                "description": "Dispatches a high-level OS, browser, file, or automation task to Omari's local OpenClaw engine.",
                                "parameters": [
                                    "type": "OBJECT",
                                    "properties": [
                                        "instruction": [
                                            "type": "STRING",
                                            "description": "The explicit task description for OpenClaw to perform.",
                                        ],
                                        "screen_context": [
                                            "type": "STRING",
                                            "description": "Optional error text, URL, or code visible on screen needed for execution.",
                                        ],
                                    ],
                                    "required": ["instruction"],
                                ],
                            ],
                            [
                                "name": "recall_screen",
                                "description": "Searches Kweku's local screen timeline — a record of what has been on Omari's screen. Use it whenever he asks what he was doing, what an earlier window/error/page said, or to find something he saw before. Prefer this over guessing.",
                                "parameters": [
                                    "type": "OBJECT",
                                    "properties": [
                                        "query": [
                                            "type": "STRING",
                                            "description": "Words to match against app names and window titles, e.g. 'safari docs' or 'build'. Leave empty to list recent activity.",
                                        ],
                                        "minutes_ago": [
                                            "type": "STRING",
                                            "description": "Only search the last N minutes, as a number. Omit to search the whole timeline.",
                                        ],
                                    ],
                                    "required": [String](),
                                ],
                            ],
                            [
                                "name": "execute_omp_command",
                                "description": "Executes a coding task directly in Omari's active oh-my-pi terminal session.",
                                "parameters": [
                                    "type": "OBJECT",
                                    "properties": [
                                        "prompt": [
                                            "type": "STRING",
                                            "description": "The exact prompt/command for oh-my-pi.",
                                        ],
                                    ],
                                    "required": ["prompt"],
                                ],
                            ],
                        ],
                    ],
                    ["googleSearch": [String: String]()],
                ],
            ],
        ]
        return encode(frame)
    }

    /// One realtime media blob, on the stream that matches its modality.
    ///
    /// `realtimeInput` carries audio, video and text as *concurrent* streams,
    /// each with its own field. The older `mediaChunks` array is a single
    /// inlined-media slot — "multiple mediaChunks are not supported, all but
    /// the first will be ignored" — and is deprecated in favour of these.
    ///
    /// Sending both modalities through `mediaChunks` is why "what am I looking
    /// at?" answered from the system prompt instead of the screen: mic PCM
    /// arrives ~50×/second and screen frames 1×/second, so audio owned the
    /// one slot and the frames were dropped before the model ever saw them.
    /// Capture was never the problem — delivery was.
    public static func realtimeBlob(_ stream: String, mimeType: String, base64: String) -> Data {
        encode(["realtimeInput": [stream: ["mimeType": mimeType, "data": base64]]])
    }

    public static func audioChunk(_ pcm16k: Data) -> Data {
        realtimeBlob("audio", mimeType: "audio/pcm;rate=16000",
                     base64: pcm16k.base64EncodedString())
    }

    public static func videoFrame(_ jpeg: Data) -> Data {
        realtimeBlob("video", mimeType: "image/jpeg", base64: jpeg.base64EncodedString())
    }

    /// Inject a text turn into the live conversation. Used to deliver an
    /// OpenClaw result that outlived its tool call: the model receives it as a
    /// new user turn and speaks it in its own voice.
    public static func clientText(_ text: String) -> Data {
        encode(["clientContent": [
            "turns": [["role": "user", "parts": [["text": text]]]],
            "turnComplete": true,
        ]])
    }

    public static func toolResponse(id: String, name: String, output: String) -> Data {
        encode(["toolResponse": ["functionResponses": [[
            "id": id, "name": name, "response": ["output": output],
        ]]]])
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    // MARK: - Server → client parsing

    /// Parse one websocket message (text or binary JSON) into events.
    public static func parse(_ data: Data) -> [GeminiServerEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var events: [GeminiServerEvent] = []

        if obj["setupComplete"] != nil { events.append(.setupComplete) }
        if obj["goAway"] != nil { events.append(.goAway) }
        if let update = obj["sessionResumptionUpdate"] as? [String: Any],
           (update["resumable"] as? Bool) == true,
           let handle = update["newHandle"] as? String, !handle.isEmpty {
            events.append(.resumptionHandle(handle))
        }

        if let content = obj["serverContent"] as? [String: Any] {
            if (content["interrupted"] as? Bool) == true { events.append(.interrupted) }

            // Transcripts are independent of the model turn — they carry no
            // ordering guarantee against it, and arrive as fragments to
            // append rather than cumulative snapshots to replace.
            if let text = transcriptText(content["interimInputTranscription"]) {
                events.append(.heardTranscript(text: text, interim: true))
            }
            if let text = transcriptText(content["inputTranscription"]) {
                events.append(.heardTranscript(text: text, interim: false))
            }
            if let text = transcriptText(content["outputTranscription"]) {
                events.append(.spokenTranscript(text: text))
            }

            if let turn = content["modelTurn"] as? [String: Any],
               let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                       let b64 = inline["data"] as? String,
                       let pcm = Data(base64Encoded: b64) {
                        events.append(.audio(pcm))
                    }
                }
            }
            if (content["turnComplete"] as? Bool) == true { events.append(.turnComplete) }
        }

        if let call = obj["toolCall"] as? [String: Any],
           let fns = call["functionCalls"] as? [[String: Any]] {
            for fn in fns {
                guard let id = fn["id"] as? String, let name = fn["name"] as? String else { continue }
                let raw = (fn["args"] as? [String: Any]) ?? [:]
                let args = raw.compactMapValues { $0 as? String }
                events.append(.toolCall(id: id, name: name, args: args))
            }
        }
        return events
    }

    /// A `Transcription` object carries an optional `text`. Empty fragments
    /// are dropped so they can't churn the caption view.
    static func transcriptText(_ raw: Any?) -> String? {
        guard let object = raw as? [String: Any],
              let text = object["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }
}
