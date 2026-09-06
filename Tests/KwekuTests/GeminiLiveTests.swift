import Foundation
@testable import KwekuKit

enum GeminiLiveTests {
    static func all() {
        setupFrame()
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
            let tools = (setup?["tools"] as? [[String: Any]]) ?? []
            Check.ok(tools.count == 2, "two tool groups")
            let fns = (tools.first?["functionDeclarations"] as? [[String: Any]]) ?? []
            Check.ok(fns.count == 2, "two function declarations")
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

    static func mediaFrames() {
        Check.run("audio + video chunks use the right mime types") {
            let audio = json(GeminiLiveProtocol.audioChunk(Data([1, 2, 3])))
            let aChunk = (((audio["realtimeInput"] as? [String: Any])?["mediaChunks"]
                as? [[String: Any]]))?.first
            Check.ok(aChunk?["mimeType"] as? String == "audio/pcm;rate=16000", "pcm 16k mime")
            Check.ok(aChunk?["data"] as? String == Data([1, 2, 3]).base64EncodedString(), "b64 payload")

            let video = json(GeminiLiveProtocol.videoFrame(Data([9])))
            let vChunk = (((video["realtimeInput"] as? [String: Any])?["mediaChunks"]
                as? [[String: Any]]))?.first
            Check.ok(vChunk?["mimeType"] as? String == "image/jpeg", "jpeg mime")
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
        Check.run("front window: first layer-0 entry of the focused pid wins") {
            let windows: [(id: UInt32, pid: Int32, layer: Int)] = [
                (901, 500, 25),   // someone's overlay, in front but not layer 0
                (902, 400, 0),    // another app's window
                (903, 500, 0),    // the focused app's frontmost regular window
                (904, 500, 0),    // same app, further back
            ]
            Check.ok(ScreenTargeting.frontWindowID(pid: 500, windows: windows) == 903, "picks 903")
            Check.ok(ScreenTargeting.frontWindowID(pid: 999, windows: windows) == nil,
                     "unknown pid -> nil (display fallback)")
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
