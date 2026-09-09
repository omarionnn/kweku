import Foundation
@testable import KwekuKit

enum GeminiLiveTests {
    static func all() {
        setupFrame()
        visionPersona()
        mediaFrames()
        parser()
        audioMath()
        screenTargeting()
        shellQuote()
    }

    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func setupFrame() {
        Check.run("setup frame carries model, audio modality, tools") {
            let frame = json(GeminiLiveProtocol.setup(model: "models/test-live"))
            let setup = frame["setup"] as? [String: Any]
            Check.ok(setup?["model"] as? String == "models/test-live", "model")
            let gen = setup?["generationConfig"] as? [String: Any]
            Check.ok((gen?["responseModalities"] as? [String]) == ["AUDIO"], "AUDIO modality")
            // Unpinned, the server hands out a different voice per session.
            let speech = gen?["speechConfig"] as? [String: Any]
            let prebuilt = (speech?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
            Check.ok(prebuilt?["voiceName"] as? String == GeminiLiveProtocol.voiceName, "voice pinned")
            let tools = (setup?["tools"] as? [[String: Any]]) ?? []
            Check.ok(tools.count == 2, "two tool groups")
            let fns = (tools.first?["functionDeclarations"] as? [[String: Any]]) ?? []
            Check.ok(fns.count == 3, "three function declarations")
            let names = fns.compactMap { $0["name"] as? String }
            Check.ok(names.contains("recall_screen"), "screen recall tool declared")
            let recall = fns.first { $0["name"] as? String == "recall_screen" }
            let recallProps = (recall?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
            Check.ok(recallProps?["query"] != nil && recallProps?["minutes_ago"] != nil,
                     "recall takes a query and a time window")
            // Args arrive as strings, so a numeric window has to be declared
            // as one or it is dropped on the way in.
            let minutes = recallProps?["minutes_ago"] as? [String: Any]
            Check.ok(minutes?["type"] as? String == "STRING", "minutes_ago survives arg parsing")
            Check.ok(fns.first?["name"] as? String == "dispatch_openclaw_action", "openclaw tool declared")
            let ocParams = fns.first?["parameters"] as? [String: Any]
            Check.ok((ocParams?["required"] as? [String]) == ["instruction"], "instruction required")
            let ocProps = ocParams?["properties"] as? [String: Any]
            Check.ok(ocProps?["screen_context"] != nil, "screen_context optional param")
            Check.ok(fns.last?["name"] as? String == "execute_omp_command", "omp tool declared")
            let ompParams = fns.last?["parameters"] as? [String: Any]
            Check.ok((ompParams?["required"] as? [String]) == ["prompt"], "prompt required")
            Check.ok(tools.last?["googleSearch"] != nil, "google search enabled")
            let system = setup?["systemInstruction"] as? [String: Any]
            let text = ((system?["parts"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            Check.ok(text.contains("Kweku") && text.contains("Omari") && text.contains("OpenClaw"),
                     "Kweku persona")
        }
    }

    static func visionPersona() {
        Check.run("a blind session is never told it can see") {
            let sighted = GeminiLiveProtocol.systemInstruction(visionAvailable: true)
            Check.ok(sighted.contains("see Omari's screen in real time"), "sighted claims sight")
            Check.ok(!sighted.lowercased().contains("you are currently blind"),
                     "sighted is not told it is blind")

            let blind = GeminiLiveProtocol.systemInstruction(
                visionAvailable: false, visionIssue: "Screen Recording not granted")
            // The claim has to be withdrawn, not merely contradicted later:
            // leaving it in and appending a denial still produced a confident
            // wrong answer against the live API.
            Check.ok(!blind.contains("see Omari's screen in real time"),
                     "blind persona withdraws the claim of sight")
            Check.ok(blind.lowercased().contains("currently blind"), "blind says so")
            Check.ok(blind.contains("Screen Recording not granted"), "carries the real reason")
            Check.ok(blind.contains("Screen Recording"), "points at the setting to fix it")

            for text in [sighted, blind] {
                Check.ok(text.contains("Kweku") && text.contains("Omari")
                         && text.contains("OpenClaw"), "persona survives either way")
            }
        }
    }

    static func mediaFrames() {
        Check.run("audio + video ride their own realtimeInput streams") {
            // Each modality has its own field. The deprecated `mediaChunks`
            // array holds one blob only, so sharing it between mic and screen
            // silently dropped every frame — assert the split, not just mimes.
            let audio = json(GeminiLiveProtocol.audioChunk(Data([1, 2, 3])))
            let aInput = audio["realtimeInput"] as? [String: Any]
            let aBlob = aInput?["audio"] as? [String: Any]
            Check.ok(aBlob?["mimeType"] as? String == "audio/pcm;rate=16000", "pcm 16k mime")
            Check.ok(aBlob?["data"] as? String == Data([1, 2, 3]).base64EncodedString(), "b64 payload")
            Check.ok(aInput?["mediaChunks"] == nil, "audio avoids deprecated mediaChunks")
            Check.ok(aInput?["video"] == nil, "audio frame carries no video")

            let video = json(GeminiLiveProtocol.videoFrame(Data([9])))
            let vInput = video["realtimeInput"] as? [String: Any]
            let vBlob = vInput?["video"] as? [String: Any]
            Check.ok(vBlob?["mimeType"] as? String == "image/jpeg", "jpeg mime")
            Check.ok(vBlob?["data"] as? String == Data([9]).base64EncodedString(), "b64 payload")
            Check.ok(vInput?["mediaChunks"] == nil, "video avoids deprecated mediaChunks")
            Check.ok(vInput?["audio"] == nil, "video frame carries no audio")
        }

        Check.run("tool response frame shape") {
            let frame = json(GeminiLiveProtocol.toolResponse(id: "c1", name: "execute_omp_command", output: "done"))
            let rsp = ((frame["toolResponse"] as? [String: Any])?["functionResponses"]
                as? [[String: Any]])?.first
            Check.ok(rsp?["id"] as? String == "c1", "id")
            Check.ok((rsp?["response"] as? [String: Any])?["output"] as? String == "done", "output")
        }
    }

    static func parser() {
        Check.run("parses setupComplete + goAway") {
            Check.ok(GeminiLiveProtocol.parse(Data(#"{"setupComplete":{}}"#.utf8)) == [.setupComplete], "setup")
            Check.ok(GeminiLiveProtocol.parse(Data(#"{"goAway":{"timeLeft":"10s"}}"#.utf8)) == [.goAway], "goAway")
        }
        Check.run("parses model audio parts") {
            let pcm = Data([0, 1, 2, 3])
            let msg = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(pcm.base64EncodedString())"}}]},"turnComplete":true}}"#
            let events = GeminiLiveProtocol.parse(Data(msg.utf8))
            Check.ok(events.contains(.audio(pcm)), "audio decoded")
            Check.ok(events.contains(.turnComplete), "turn complete")
        }
        Check.run("parses interruption") {
            let events = GeminiLiveProtocol.parse(Data(#"{"serverContent":{"interrupted":true}}"#.utf8))
            Check.ok(events == [.interrupted], "interrupted")
        }
        Check.run("parses tool calls with generic args") {
            let msg = #"{"toolCall":{"functionCalls":[{"id":"f7","name":"execute_omp_command","args":{"prompt":"fix the build"}}]}}"#
            let events = GeminiLiveProtocol.parse(Data(msg.utf8))
            Check.ok(events == [.toolCall(id: "f7", name: "execute_omp_command",
                                          args: ["prompt": "fix the build"])], "omp tool call")
            let oc = #"{"toolCall":{"functionCalls":[{"id":"c2","name":"dispatch_openclaw_action","args":{"instruction":"open PR page","screen_context":"https://x.test"}}]}}"#
            let ocEvents = GeminiLiveProtocol.parse(Data(oc.utf8))
            Check.ok(ocEvents == [.toolCall(id: "c2", name: "dispatch_openclaw_action",
                                            args: ["instruction": "open PR page",
                                                   "screen_context": "https://x.test"])], "openclaw tool call")
        }
        Check.run("client text frame injects a completed turn") {
            let obj = try! JSONSerialization.jsonObject(
                with: GeminiLiveProtocol.clientText("build finished")) as! [String: Any]
            let content = obj["clientContent"] as! [String: Any]
            let turns = content["turns"] as! [[String: Any]]
            let parts = turns[0]["parts"] as! [[String: Any]]
            Check.ok(turns[0]["role"] as? String == "user", "arrives as a user turn")
            Check.ok(parts[0]["text"] as? String == "build finished", "carries the text")
            Check.ok(content["turnComplete"] as? Bool == true, "closes the turn so the model speaks")
        }
        Check.run("setup enables both transcription streams") {
            let obj = try! JSONSerialization.jsonObject(
                with: GeminiLiveProtocol.setup(model: "m")) as! [String: Any]
            let setup = obj["setup"] as! [String: Any]
            // Empty object = auto language detection. Absent = no transcripts.
            Check.ok(setup["inputAudioTranscription"] != nil, "input transcription requested")
            Check.ok(setup["outputAudioTranscription"] != nil, "output transcription requested")
        }
        Check.run("parses caption + heard transcripts") {
            let spoken = GeminiLiveProtocol.parse(Data(
                #"{"serverContent":{"outputTranscription":{"text":"on it"}}}"#.utf8))
            Check.ok(spoken == [.spokenTranscript(text: "on it")], "output -> caption")

            let final = GeminiLiveProtocol.parse(Data(
                #"{"serverContent":{"inputTranscription":{"text":"build it"}}}"#.utf8))
            Check.ok(final == [.heardTranscript(text: "build it", interim: false)], "input -> heard")

            let interim = GeminiLiveProtocol.parse(Data(
                #"{"serverContent":{"interimInputTranscription":{"text":"buil"}}}"#.utf8))
            Check.ok(interim == [.heardTranscript(text: "buil", interim: true)], "interim flagged")
        }
        Check.run("empty and malformed transcripts are dropped") {
            // An empty fragment must not churn the caption view.
            Check.ok(GeminiLiveProtocol.parse(Data(
                #"{"serverContent":{"outputTranscription":{"text":""}}}"#.utf8)).isEmpty, "empty text")
            Check.ok(GeminiLiveProtocol.parse(Data(
                #"{"serverContent":{"outputTranscription":{}}}"#.utf8)).isEmpty, "no text field")
            Check.ok(GeminiLiveProtocol.transcriptText("nonsense") == nil, "wrong type")
            Check.ok(GeminiLiveProtocol.transcriptText(nil) == nil, "absent")
        }
        Check.run("transcript rides alongside audio in one frame") {
            let both = #"""
            {"serverContent":{"outputTranscription":{"text":"hi"},
            "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm","data":"AAA="}}]},
            "turnComplete":true}}
            """#
            let events = GeminiLiveProtocol.parse(Data(both.utf8))
            Check.ok(events.contains(.spokenTranscript(text: "hi")), "caption present")
            Check.ok(events.contains(.turnComplete), "turnComplete still parsed")
            Check.ok(events.contains { if case .audio = $0 { return true }; return false }, "audio still parsed")
        }
        Check.run("garbage yields no events") {
            Check.ok(GeminiLiveProtocol.parse(Data("nope".utf8)).isEmpty, "non-json")
            Check.ok(GeminiLiveProtocol.parse(Data("{}".utf8)).isEmpty, "empty object")
        }
    }

    static func audioMath() {
        Check.run("RMS of PCM") {
            Check.eq(Double(AudioMath.rms(pcm16: Data(count: 20))), 0, "silence = 0")
            var full = Data()
            for _ in 0..<10 {
                withUnsafeBytes(of: Int16.max.littleEndian) { full.append(contentsOf: $0) }
            }
            Check.eq(Double(AudioMath.rms(pcm16: full)), 1.0, accuracy: 0.01, "full-scale ~ 1")
            Check.eq(Double(AudioMath.uiLevel(fromRMS: 0.2)), 0.7, accuracy: 0.001, "ui boost")
            Check.eq(Double(AudioMath.uiLevel(fromRMS: 0.9)), 1.0, "ui clamp")
        }
    }

    static func screenTargeting() {
        Check.run("focused window: phantom strips lose, frontmost app wins") {
            func win(_ id: UInt32, _ pid: Int32, layer: Int = 0,
                     w: CGFloat = 900, h: CGFloat = 600, a: CGFloat = 1,
                     regular: Bool = true) -> ScreenTargeting.WindowInfo {
                .init(id: id, pid: pid, layer: layer, width: w, height: h,
                      alpha: a, regularApp: regular)
            }
            // The field, front-to-back: everything that beat the real window.
            let field = [
                win(901, 500, layer: 25),                        // menu-bar item
                win(902, 501, w: 1470, h: 66, regular: false),   // OpenClaw HUD strip
                win(906, 503, w: 66, h: 20, a: 0),               // invisible helper
                win(907, 503, w: 1470, h: 90),                   // Terminal's phantom strip
                win(903, 502, w: 40, h: 40),                     // tiny palette
                win(904, 503),                                   // the user's real window
                win(905, 504),                                   // another app, further back
            ]
            Check.ok(ScreenTargeting.focusedWindowID(windows: field, excludingPid: 1) == 904,
                     "skips overlays, accessory strips, phantoms, and palettes")
            Check.ok(ScreenTargeting.focusedWindowID(windows: field, frontmostPid: 504,
                                                     excludingPid: 1) == 905,
                     "frontmost app's window preferred over higher z of another app")
            Check.ok(ScreenTargeting.focusedWindowID(windows: field, frontmostPid: 501,
                                                     excludingPid: 1) == 904,
                     "accessory frontmost (OpenClaw) has no qualifying window -> z-order")
            Check.ok(ScreenTargeting.focusedWindowID(windows: field, excludingPid: 503) == 905,
                     "own process never captured")
            Check.ok(ScreenTargeting.focusedWindowID(windows: [win(9, 5, regular: false)],
                                                     excludingPid: 1) == nil,
                     "nothing qualifies -> nil (display fallback)")
        }
        Check.run("still screens keep sending; pixels never outlive their window") {
            typealias T = ScreenTargeting
            // A window that is repainting: normal path.
            Check.ok(T.frameAction(hasNewPixels: true, cacheMatchesTarget: true,
                                   sendASAP: false, sinceLastSend: 1.0) == .send,
                     "new pixels on cadence are sent")
            Check.ok(T.frameAction(hasNewPixels: true, cacheMatchesTarget: true,
                                   sendASAP: false, sinceLastSend: 0.2) == .skip,
                     "cadence still throttles a busy window")
            Check.ok(T.frameAction(hasNewPixels: true, cacheMatchesTarget: false,
                                   sendASAP: true, sinceLastSend: 0) == .send,
                     "the user's turn jumps the cadence")

            // A window sitting still: SCStream stops producing pixels, and the
            // old code sent nothing at all — so the model stayed on whatever
            // was last moving. It must now keep seeing the current window.
            Check.ok(T.frameAction(hasNewPixels: false, cacheMatchesTarget: true,
                                   sendASAP: false, sinceLastSend: 1.0) == .resendCached,
                     "idle window re-sends its own last frame")
            Check.ok(T.frameAction(hasNewPixels: false, cacheMatchesTarget: true,
                                   sendASAP: true, sinceLastSend: 0) == .resendCached,
                     "asking about a frozen screen still shows that screen")

            // Just retargeted and the new window hasn't painted yet: staying
            // silent is right, because the only frame in hand is the *old*
            // window's — sending it is exactly the wrong-screen bug.
            Check.ok(T.frameAction(hasNewPixels: false, cacheMatchesTarget: false,
                                   sendASAP: true, sinceLastSend: 9) == .skip,
                     "never re-sends a frame from the previous target")
        }
        Check.run("output size: native when small, capped with aspect when big") {
            let small = ScreenTargeting.outputSize(for: CGSize(width: 400, height: 300))
            Check.ok(small == (800, 600), "2x native under the cap")
            let big = ScreenTargeting.outputSize(for: CGSize(width: 1600, height: 1000))
            Check.ok(big == (1280, 800), "capped long edge, aspect kept")
            let tall = ScreenTargeting.outputSize(for: CGSize(width: 500, height: 1200))
            Check.ok(tall == (532, 1280), "portrait caps on height, even width")
            let display = ScreenTargeting.outputSize(for: CGSize(width: 2560, height: 1664), scale: 1)
            Check.ok(display == (1280, 832), "display fallback matches old framing")
        }
    }

    static func shellQuote() {
        Check.run("omp prompt shell quoting") {
            Check.ok(OMPBridgeManager.shellQuote("hello") == "'hello'", "plain")
            Check.ok(OMPBridgeManager.shellQuote("it's") == #"'it'\''s'"#, "embedded quote")
        }
    }
}
