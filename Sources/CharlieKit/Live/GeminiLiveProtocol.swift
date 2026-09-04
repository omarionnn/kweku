import Foundation

/// Events Charlie receives over the Live websocket.
public enum GeminiServerEvent: Equatable, Sendable {
    case setupComplete
    case audio(Data)                                  // 24kHz 16-bit PCM mono
    case toolCall(id: String, name: String, prompt: String)
    case interrupted                                  // user barge-in: flush playback
    case turnComplete
    case goAway
}

/// Pure wire-format builders + parser for the Gemini Live (BidiGenerateContent)
/// protocol. No I/O here — fully unit-tested.
public enum GeminiLiveProtocol {

    public static let defaultModel = "models/gemini-2.5-flash-native-audio-preview-12-2025"
    public static let endpointBase =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    public static let systemInstruction = """
        You are Charlie, a friendly macOS coding companion living inside the \
        screen notch. You can see the user's screen, speak verbally, execute \
        coding commands via oh-my-pi, and search the web.
        """

    // MARK: - Client → server frames

    /// Session setup: model, AUDIO responses, system instruction, tools
    /// (Google Search + the omp executor).
    public static func setup(model: String, system: String = systemInstruction) -> Data {
        let frame: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "systemInstruction": ["parts": [["text": system]]],
                "tools": [
                    [
                        "functionDeclarations": [[
                            "name": "execute_omp_command",
                            "description": "Executes a coding task or terminal command inside the user's active oh-my-pi session.",
                            "parameters": [
                                "type": "OBJECT",
                                "properties": [
                                    "prompt": [
                                        "type": "STRING",
                                        "description": "The command or instruction to pass to oh-my-pi.",
                                    ],
                                ],
                                "required": ["prompt"],
                            ],
                        ]],
                    ],
                    ["googleSearch": [String: String]()],
                ],
            ],
        ]
        return encode(frame)
    }

    /// One realtime media chunk (mic audio or a screen frame).
    public static func realtimeChunk(mimeType: String, base64: String) -> Data {
        encode(["realtimeInput": ["mediaChunks": [["mimeType": mimeType, "data": base64]]]])
    }

    public static func audioChunk(_ pcm16k: Data) -> Data {
        realtimeChunk(mimeType: "audio/pcm;rate=16000", base64: pcm16k.base64EncodedString())
    }

    public static func videoFrame(_ jpeg: Data) -> Data {
        realtimeChunk(mimeType: "image/jpeg", base64: jpeg.base64EncodedString())
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

        if let content = obj["serverContent"] as? [String: Any] {
            if (content["interrupted"] as? Bool) == true { events.append(.interrupted) }
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
                let args = fn["args"] as? [String: Any]
                let prompt = (args?["prompt"] as? String) ?? ""
                events.append(.toolCall(id: id, name: name, prompt: prompt))
            }
        }
        return events
    }
}
