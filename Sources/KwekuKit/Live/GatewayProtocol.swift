import Foundation

/// One decoded frame from the Gateway websocket.
public enum GatewayFrame: Equatable, Sendable {
    /// Pre-auth challenge. Must be answered with a `connect` request.
    case challenge
    /// RPC reply correlated by request id.
    case response(id: String, ok: Bool, payload: GatewayPayload)
    /// Push event (`chat`, `session.message`, `tick`, …).
    case event(name: String, payload: GatewayPayload)
}

/// The slice of a frame payload Kweku actually reads. Keeping this a concrete
/// enum (rather than passing `[String: Any]` around) is what makes the parser
/// testable without a live gateway.
public enum GatewayPayload: Equatable, Sendable {
    case helloOK(protocolVersion: Int, scopes: [String])
    case subscribed(key: String)
    case runStarted(runId: String)
    case run(GatewayRunEvent)
    case error(code: String, message: String)
    case other
}

/// Progress for one dispatched run. `runId` is what lets Kweku ignore the
/// other sessions' traffic that shares this socket.
public struct GatewayRunEvent: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case status(phase: String)   // e.g. "starting_model"
        case delta(text: String)     // cumulative assistant text so far
        case final(text: String)     // terminal: the answer
        case failed(message: String) // terminal: the run errored
    }
    public var runId: String
    public var sessionKey: String
    public var state: State

    public var isTerminal: Bool {
        switch state {
        case .final, .failed: return true
        case .status, .delta: return false
        }
    }
}

/// Pure wire-format builders + parser for the OpenClaw Gateway WS protocol
/// (protocol v4). No I/O here — mirrors `GeminiLiveProtocol` so both sides of
/// the bridge are unit-testable.
///
/// Verified against a live gateway (2026.9.1): handshake, the `key` vs
/// `sessionKey` split between `sessions.messages.subscribe` and `chat.send`,
/// the mandatory `idempotencyKey`, and the `status`/`delta`/`final` run states.
public enum GatewayProtocol {

    public static let protocolVersion = 4
    public static let defaultURL = URL(string: "ws://127.0.0.1:18789")!
    /// Canonical main session. Sharing it means voice requests and the
    /// desktop/chat client land in the *same* conversation context.
    public static let defaultSessionKey = "agent:main:main"

    /// The same gateway as a browsable Control UI address — where a click on a
    /// waiting OpenClaw session goes, since it has no terminal to raise.
    /// Derived from `defaultURL` rather than written out a second time, so the
    /// socket and the page can't drift onto different hosts or ports.
    public static var dashboardURL: URL {
        var parts = URLComponents(url: defaultURL, resolvingAgainstBaseURL: false)
        parts?.scheme = (defaultURL.scheme == "wss") ? "https" : "http"
        parts?.path = "/"
        return parts?.url ?? URL(string: "http://127.0.0.1:18789/")!
    }

    // MARK: - Client → gateway frames

    /// Handshake reply. `client.id`/`client.mode` are closed enums server-side;
    /// `gateway-client` + `backend` is the pairing for an external app.
    public static func connect(id: String, token: String, version: String) -> Data {
        encode([
            "type": "req", "id": id, "method": "connect",
            "params": [
                "minProtocol": protocolVersion,
                "maxProtocol": protocolVersion,
                "client": [
                    "id": "gateway-client",
                    "displayName": "Kweku",
                    "version": version,
                    "platform": "macos",
                    "mode": "backend",
                ],
                "role": "operator",
                "scopes": ["operator.read", "operator.write"],
                "auth": ["token": token],
            ],
        ])
    }

    /// Subscribe to a session's transcript events. Note the param is `key`,
    /// *not* `sessionKey` — the two RPCs genuinely differ.
    public static func subscribe(id: String, sessionKey: String) -> Data {
        encode([
            "type": "req", "id": id,
            "method": "sessions.messages.subscribe",
            "params": ["key": sessionKey],
        ])
    }

    /// Start an agent turn. `idempotencyKey` is required by the schema and is
    /// echoed back as the `runId`, so we generate one we can correlate on.
    ///
    /// `screenshot` rides along as a chat attachment so the agent sees the
    /// actual screen instead of a description of it.
    public static func chatSend(id: String, sessionKey: String, message: String,
                                idempotencyKey: String, screenshot: Data? = nil) -> Data {
        var params: [String: Any] = [
            "sessionKey": sessionKey,
            "message": message,
            "idempotencyKey": idempotencyKey,
        ]
        if let screenshot, !screenshot.isEmpty {
            params["attachments"] = [imageAttachment(screenshot)]
        }
        return encode(["type": "req", "id": id, "method": "chat.send", "params": params])
    }

    /// The gateway normalises attachments and then silently drops any whose
    /// `content` is missing — no error, the image just never reaches the
    /// model. `content` (base64) and `mimeType` are the load-bearing fields.
    static func imageAttachment(_ jpeg: Data, fileName: String = "screen.jpg") -> [String: Any] {
        [
            "type": "image",
            "mimeType": "image/jpeg",
            "fileName": fileName,
            "content": jpeg.base64EncodedString(),
        ]
    }

    /// Decoded-size ceiling for a single image, per `hello-ok.policy`.
    /// A 720p JPEG sits far under this; the guard is for safety, not fit.
    public static let maxImageBytes = 6 * 1024 * 1024

    /// Cancel an in-flight run (used when the user interrupts by voice).
    public static func abort(id: String, sessionKey: String, runId: String) -> Data {
        encode([
            "type": "req", "id": id, "method": "sessions.abort",
            "params": ["key": sessionKey, "runId": runId],
        ])
    }

    // MARK: - Gateway → client parsing

    public static func parse(_ data: Data) -> GatewayFrame? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "event":
            guard let name = obj["event"] as? String else { return nil }
            if name == "connect.challenge" { return .challenge }
            let body = obj["payload"] as? [String: Any] ?? [:]
            return .event(name: name, payload: eventPayload(name: name, body: body))

        case "res":
            guard let id = obj["id"] as? String else { return nil }
            let ok = (obj["ok"] as? Bool) ?? false
            if !ok {
                let err = obj["error"] as? [String: Any] ?? [:]
                return .response(id: id, ok: false, payload: .error(
                    code: err["code"] as? String ?? "UNKNOWN",
                    message: err["message"] as? String ?? "unknown gateway error"))
            }
            return .response(id: id, ok: true,
                             payload: resultPayload(obj["payload"] as? [String: Any] ?? [:]))

        default:
            return nil
        }
    }

    private static func resultPayload(_ body: [String: Any]) -> GatewayPayload {
        if (body["type"] as? String) == "hello-ok" {
            let auth = body["auth"] as? [String: Any] ?? [:]
            return .helloOK(protocolVersion: body["protocol"] as? Int ?? 0,
                            scopes: auth["scopes"] as? [String] ?? [])
        }
        if (body["subscribed"] as? Bool) == true, let key = body["key"] as? String {
            return .subscribed(key: key)
        }
        if let runId = body["runId"] as? String { return .runStarted(runId: runId) }
        return .other
    }

    private static func eventPayload(name: String, body: [String: Any]) -> GatewayPayload {
        // Only `chat` frames carry run progress. Every other family (including
        // `session.message`) is transcript bookkeeping Kweku doesn't need.
        guard name == "chat",
              let runId = body["runId"] as? String,
              let sessionKey = body["sessionKey"] as? String,
              let state = body["state"] as? String
        else { return .other }

        let text = assistantText(body["message"] as? [String: Any])

        switch state {
        case "status":
            return .run(GatewayRunEvent(runId: runId, sessionKey: sessionKey,
                                        state: .status(phase: body["phase"] as? String ?? "working")))
        case "delta":
            return .run(GatewayRunEvent(runId: runId, sessionKey: sessionKey,
                                        state: .delta(text: text)))
        case "final":
            return .run(GatewayRunEvent(runId: runId, sessionKey: sessionKey,
                                        state: .final(text: text)))
        case "error", "aborted":
            // `aborted` is a real terminal state (OpenClaw's own client
            // handles it). Without it an aborted run never resolves and the
            // caller waits out the full dispatch timeout.
            let fallback = state == "aborted" ? "the task was cancelled" : "the run failed"
            let detail = body["errorMessage"] as? String
                ?? body["errorKind"] as? String
                ?? fallback
            return .run(GatewayRunEvent(runId: runId, sessionKey: sessionKey,
                                        state: .failed(message: detail)))
        default:
            return .other
        }
    }

    /// Assistant content is `[{type:"text", text:"…"}]`; older/simpler frames
    /// use a bare string. Both appear in practice.
    static func assistantText(_ message: [String: Any]?) -> String {
        guard let message else { return "" }
        if let s = message["content"] as? String { return s }
        guard let parts = message["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            (part["type"] as? String) == "text" ? part["text"] as? String : nil
        }.joined()
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}

// MARK: - Credentials

/// Reads the gateway token at runtime. Never logged, never bundled: it lives
/// in the user's own config, and the env var wins so a launchd/dev override
/// works without touching the file.
public enum GatewayCredentials {
    public static func token() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENCLAW_GATEWAY_TOKEN"], !env.isEmpty {
            return env
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = root["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }
}
