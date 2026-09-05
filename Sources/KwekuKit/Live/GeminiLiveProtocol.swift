import Foundation

/// Events Kweku receives over the Live websocket.
public enum GeminiServerEvent: Equatable, Sendable {
    case setupComplete
    case audio(Data)                                  // 24kHz 16-bit PCM mono
    case toolCall(id: String, name: String, args: [String: String])
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
        You are Kweku, an elite personal developer companion living inside \
        Omari's MacBook notch. You are sharp, developer-native, concise, and \
        highly action-oriented. You can see Omari's screen in real time, \
        listen and talk verbally, execute terminal tasks in oh-my-pi, and run \
        complex browser/OS automations through your OpenClaw runtime engine. \
        Address Omari naturally as his companion.
        """

    // MARK: - Client → server frames

    /// Session setup: model, AUDIO responses, system instruction, tools
    /// (OpenClaw dispatcher + omp executor + Google Search).
    public static func setup(model: String, system: String = systemInstruction) -> Data {
        let frame: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "systemInstruction": ["parts": [["text": system]]],
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
                let raw = (fn["args"] as? [String: Any]) ?? [:]
                let args = raw.compactMapValues { $0 as? String }
                events.append(.toolCall(id: id, name: name, args: args))
            }
        }
        return events
    }
}
