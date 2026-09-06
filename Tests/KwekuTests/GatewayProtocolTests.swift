import Foundation
@testable import KwekuKit

/// Frames here are trimmed copies of real traffic captured from a live
/// gateway (OpenClaw 2026.9.1, protocol v4), so these tests pin the actual
/// wire contract rather than an assumed one.
enum GatewayProtocolTests {

    static func all() {
        requests()
        handshake()
        runEvents()
        isolation()
        trimming()
        reconnectBackoff()
    }

    // MARK: - Reconnect policy

    static func reconnectBackoff() {
        Check.run("a credential failure always yields another attempt") {
            var policy = ReconnectPolicy()
            // The regression this pins: `openSocket` used to return without
            // scheduling anything when the token read came back nil, so the
            // bridge stayed dead until Kweku was relaunched.
            for _ in 0..<20 {
                Check.ok(policy.next(unauthorized: true) > 0, "every retry has a real delay")
            }
            Check.ok(policy.delay <= ReconnectPolicy.maxDelay, "backoff stays capped")
        }

        Check.run("credential retries start slower than dropped sockets") {
            var creds = ReconnectPolicy()
            var socket = ReconnectPolicy()
            Check.ok(creds.next(unauthorized: true) >= ReconnectPolicy.unauthorizedFloor,
                     "unauthorized honours its floor")
            Check.ok(socket.next() == ReconnectPolicy.baseDelay, "a dropped socket retries fast")
        }

        Check.run("backoff grows, caps, and resets on a good handshake") {
            var policy = ReconnectPolicy()
            Check.ok(policy.next() == 1, "first wait is the base delay")
            Check.ok(policy.next() == 2, "then doubles")
            for _ in 0..<10 { _ = policy.next() }
            Check.ok(policy.next() == ReconnectPolicy.maxDelay, "saturates at the ceiling")
            policy.reset()
            Check.ok(policy.next() == ReconnectPolicy.baseDelay, "helloOK makes the next blip fast")
        }
    }

    // MARK: - Client → gateway

    static func requests() {
        Check.run("connect declares the allowed client id + mode") {
            let obj = json(GatewayProtocol.connect(id: "k1", token: "t0k", version: "9.9"))
            let params = obj["params"] as! [String: Any]
            let client = params["client"] as! [String: Any]
            // Both are closed server-side enums; the gateway rejects anything else.
            Check.ok(client["id"] as? String == "gateway-client", "client id is the external-app value")
            Check.ok(client["mode"] as? String == "backend", "client mode is backend")
            Check.ok(params["minProtocol"] as? Int == 4 && params["maxProtocol"] as? Int == 4,
                     "pins protocol v4")
            let auth = params["auth"] as! [String: Any]
            Check.ok(auth["token"] as? String == "t0k", "token travels in auth.token")
            Check.ok(obj["method"] as? String == "connect", "method")
        }

        Check.run("screenshot rides as an attachment with a `content` field") {
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
            let send = json(GatewayProtocol.chatSend(id: "k4", sessionKey: "s", message: "look",
                                                     idempotencyKey: "i", screenshot: jpeg))
            let params = send["params"] as! [String: Any]
            guard let attachments = params["attachments"] as? [[String: Any]],
                  let first = attachments.first else { return Check.ok(false, "no attachments") }
            // `content` is load-bearing: the gateway normalises attachments and
            // then silently drops any without it — schema-valid, invisible to
            // the model, no error. Renaming this field breaks vision silently,
            // so it is pinned here.
            Check.ok(first["content"] as? String == jpeg.base64EncodedString(), "base64 under `content`")
            Check.ok(first["mimeType"] as? String == "image/jpeg", "mimeType")
            Check.ok(first["type"] as? String == "image", "type")
            Check.ok(first["fileName"] != nil, "fileName present")
        }

        Check.run("no attachment key when there is no screenshot") {
            let none = json(GatewayProtocol.chatSend(id: "k5", sessionKey: "s", message: "hi",
                                                     idempotencyKey: "i"))
            let noneParams = none["params"] as! [String: Any]
            Check.ok(noneParams["attachments"] == nil, "absent when nil")

            let empty = json(GatewayProtocol.chatSend(id: "k6", sessionKey: "s", message: "hi",
                                                      idempotencyKey: "i", screenshot: Data()))
            let emptyParams = empty["params"] as! [String: Any]
            Check.ok(emptyParams["attachments"] == nil, "absent when empty")
        }

        Check.run("subscribe uses `key`, chat.send uses `sessionKey`") {
            // This asymmetry is real and cost a round-trip to discover.
            let sub = json(GatewayProtocol.subscribe(id: "k2", sessionKey: "agent:main:main"))
            let subParams = sub["params"] as! [String: Any]
            Check.ok(subParams["key"] as? String == "agent:main:main", "subscribe -> key")
            Check.ok(subParams["sessionKey"] == nil, "subscribe rejects sessionKey")

            let send = json(GatewayProtocol.chatSend(id: "k3", sessionKey: "agent:main:main",
                                                     message: "hi", idempotencyKey: "kweku-1"))
            let sendParams = send["params"] as! [String: Any]
            Check.ok(sendParams["sessionKey"] as? String == "agent:main:main", "chat.send -> sessionKey")
            Check.ok(sendParams["idempotencyKey"] as? String == "kweku-1", "idempotencyKey is mandatory")
        }
    }

    // MARK: - Gateway → client

    static func handshake() {
        Check.run("parses the pre-auth challenge") {
            let frame = GatewayProtocol.parse(Data(
                #"{"type":"event","event":"connect.challenge","payload":{"nonce":"n","ts":1}}"#.utf8))
            Check.ok(frame == .challenge, "challenge")
        }

        Check.run("parses hello-ok with scopes") {
            let raw = #"""
            {"type":"res","id":"k1","ok":true,"payload":{"type":"hello-ok","protocol":4,
            "auth":{"role":"operator","scopes":["operator.read","operator.write"]}}}
            """#
            guard case .response(_, true, .helloOK(let version, let scopes))? =
                GatewayProtocol.parse(Data(raw.utf8))
            else { return Check.ok(false, "expected hello-ok") }
            Check.ok(version == 4, "protocol 4")
            Check.ok(scopes == ["operator.read", "operator.write"], "negotiated scopes")
        }

        Check.run("parses a rejected request") {
            let raw = #"{"type":"res","id":"k9","ok":false,"error":{"code":"INVALID_REQUEST","message":"nope"}}"#
            guard case .response(_, false, .error(let code, let message))? =
                GatewayProtocol.parse(Data(raw.utf8))
            else { return Check.ok(false, "expected error") }
            Check.ok(code == "INVALID_REQUEST" && message == "nope", "code + message")
        }

        Check.run("parses chat.send acknowledgement") {
            let raw = #"{"type":"res","id":"k3","ok":true,"payload":{"runId":"kweku-7","status":"started"}}"#
            guard case .response(_, true, .runStarted(let runId))? =
                GatewayProtocol.parse(Data(raw.utf8))
            else { return Check.ok(false, "expected runStarted") }
            Check.ok(runId == "kweku-7", "runId")
        }
    }

    static func runEvents() {
        Check.run("status -> working phase") {
            guard case .run(let event)? = payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main",
            "state":"status","phase":"starting_model"}}
            """#) else { return Check.ok(false, "expected run event") }
            Check.ok(event.state == .status(phase: "starting_model"), "phase carried")
            Check.ok(!event.isTerminal, "status is not terminal")
        }

        Check.run("delta carries cumulative assistant text") {
            guard case .run(let event)? = payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main",
            "state":"delta","deltaText":"ong","message":{"role":"assistant",
            "content":[{"type":"text","text":"pong"}]}}}
            """#) else { return Check.ok(false, "expected run event") }
            // We read the cumulative snapshot, not deltaText, so a dropped
            // frame can't corrupt the text we end up speaking.
            Check.ok(event.state == .delta(text: "pong"), "uses cumulative content")
            Check.ok(!event.isTerminal, "delta is not terminal")
        }

        Check.run("final is terminal and yields the answer") {
            guard case .run(let event)? = payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main",
            "state":"final","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}}
            """#) else { return Check.ok(false, "expected run event") }
            Check.ok(event.state == .final(text: "pong"), "final text")
            Check.ok(event.isTerminal, "final is terminal")
        }

        Check.run("error is terminal and keeps the reason") {
            guard case .run(let event)? = payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main",
            "state":"error","errorKind":"provider","errorMessage":"model unavailable"}}
            """#) else { return Check.ok(false, "expected run event") }
            Check.ok(event.state == .failed(message: "model unavailable"), "message preferred over kind")
            Check.ok(event.isTerminal, "error is terminal")
        }

        Check.run("aborted is terminal, not a hang") {
            guard case .run(let event)? = payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main",
            "state":"aborted"}}
            """#) else { return Check.ok(false, "expected run event") }
            Check.ok(event.isTerminal, "aborted resolves the dispatch")
            Check.ok(event.state == .failed(message: "the task was cancelled"), "cancel wording")
        }

        Check.run("multi-part assistant content joins in order") {
            let text = GatewayProtocol.assistantText([
                "content": [
                    ["type": "text", "text": "one "],
                    ["type": "thinking", "text": "ignored"],
                    ["type": "text", "text": "two"],
                ],
            ])
            Check.ok(text == "one two", "only text parts, in order")
            Check.ok(GatewayProtocol.assistantText(["content": "bare"]) == "bare", "bare string form")
            Check.ok(GatewayProtocol.assistantText(nil).isEmpty, "missing message")
        }
    }

    static func isolation() {
        Check.run("non-chat and malformed frames are ignored") {
            // The socket carries every session's traffic; anything without a
            // usable run shape must decode to `.other` so it can be dropped.
            Check.ok(payload(#"""
            {"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:main",
            "message":{"role":"user","content":"hi"}}}
            """#) == .other, "session.message is not run progress")

            Check.ok(payload(#"{"type":"event","event":"tick","payload":{}}"#) == .other, "tick")
            Check.ok(payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"s","state":"weird"}}
            """#) == .other, "unknown state")
            Check.ok(payload(#"""
            {"type":"event","event":"chat","payload":{"state":"final"}}
            """#) == .other, "chat without a runId is unusable")
            Check.ok(GatewayProtocol.parse(Data("not json".utf8)) == nil, "garbage")
            Check.ok(GatewayProtocol.parse(Data(#"{"type":"mystery"}"#.utf8)) == nil, "unknown frame type")
        }

        Check.run("run events keep their session key for filtering") {
            guard case .run(let event)? = payload(#"""
            {"type":"event","event":"chat","payload":{"runId":"other-run",
            "sessionKey":"agent:main:someone-else","state":"final",
            "message":{"role":"assistant","content":[{"type":"text","text":"not mine"}]}}}
            """#) else { return Check.ok(false, "expected run event") }
            Check.ok(event.runId == "other-run", "runId preserved")
            Check.ok(event.sessionKey == "agent:main:someone-else", "sessionKey preserved")
        }
    }

    static func trimming() {
        Check.run("dispatch output is bounded and never empty") {
            Check.ok(OpenClawBridgeManager.trim("   \n  ") == "(no output)", "blank -> placeholder")
            Check.ok(OpenClawBridgeManager.trim("  hi  ") == "hi", "trimmed")
            let long = String(repeating: "x", count: 5000)
            Check.ok(OpenClawBridgeManager.trim(long).count == 4000, "capped at the limit")
            Check.ok(OpenClawBridgeManager.trim("abcdef", limit: 3) == "def", "keeps the tail")
        }

        Check.run("gateway errors read as speech, not logs") {
            Check.ok(!GatewayError.timedOut.spoken.isEmpty, "timeout")
            Check.ok(GatewayError.runFailed("disk full").spoken.contains("disk full"), "carries the cause")
            Check.ok(GatewayError.rejected(code: "X", message: "bad key").spoken.contains("bad key"),
                     "surfaces the rejection")
        }
    }

    // MARK: - Helpers

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func payload(_ raw: String) -> GatewayPayload? {
        guard case .event(_, let payload)? = GatewayProtocol.parse(Data(raw.utf8)) else { return nil }
        return payload
    }
}
