import Foundation
import CharlieKit

enum GeminiLiveTests {
    static func all() {
        setupFrame()
        mediaFrames()
        parser()
        audioMath()
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
            let fns = tools.first?["functionDeclarations"] as? [[String: Any]]
            Check.ok(fns?.first?["name"] as? String == "execute_omp_command", "omp tool declared")
            let params = fns?.first?["parameters"] as? [String: Any]
            Check.ok((params?["required"] as? [String]) == ["prompt"], "prompt required")
            Check.ok(tools.last?["googleSearch"] != nil, "google search enabled")
            let system = setup?["systemInstruction"] as? [String: Any]
            let text = ((system?["parts"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            Check.ok(text.contains("Charlie") && text.contains("oh-my-pi"), "system instruction")
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
        Check.run("parses tool calls") {
            let msg = #"{"toolCall":{"functionCalls":[{"id":"f7","name":"execute_omp_command","args":{"prompt":"fix the build"}}]}}"#
            let events = GeminiLiveProtocol.parse(Data(msg.utf8))
            Check.ok(events == [.toolCall(id: "f7", name: "execute_omp_command", prompt: "fix the build")], "tool call")
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

    static func shellQuote() {
        Check.run("omp prompt shell quoting") {
            Check.ok(OMPBridgeManager.shellQuote("hello") == "'hello'", "plain")
            Check.ok(OMPBridgeManager.shellQuote("it's") == #"'it'\''s'"#, "embedded quote")
        }
    }
}
