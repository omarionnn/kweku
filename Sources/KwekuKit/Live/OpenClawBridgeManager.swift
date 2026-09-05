import Foundation

/// A background event surfaced by the OpenClaw gateway.
public struct OpenClawEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case working, attention, info }
    public var kind: Kind
    public var summary: String
}

/// Bridge to Omari's local OpenClaw engine (gateway on ws://127.0.0.1:18789).
///
/// Two channels, chosen for reliability:
/// - **Dispatch** uses the documented CLI surface (`openclaw agent --message …
///   --json`), which routes through the same gateway. The raw gateway WS
///   message schema is undocumented, so the CLI is the stable contract.
/// - **Background events** come from a listen-only WebSocket on the gateway:
///   any JSON frames are heuristically mapped (state/status/kind fields) onto
///   Kweku's notch states (amber ember ↔ ‼️ flash). Reconnects with backoff;
///   completely silent when OpenClaw isn't installed/running.
public final class OpenClawBridgeManager {
    public static let gatewayURL = URL(string: "ws://127.0.0.1:18789")!

    private var task: URLSessionWebSocketTask?
    private var listening = false
    private var onEvent: ((OpenClawEvent) -> Void)?

    public init() {}

    // MARK: - Dispatch (documented CLI surface)

    /// Run one OpenClaw task; returns bounded output for the Gemini
    /// toolResponse. Never throws — failures come back as text the model can
    /// relay ("OpenClaw isn't running", etc.).
    public static func dispatchTask(instruction: String, screenContext: String?) async -> String {
        var message = instruction
        if let ctx = screenContext, !ctx.isEmpty {
            message += "\n\nOn-screen context:\n\(ctx)"
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(message))
            }
        }
    }

    private static func run(_ message: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "openclaw agent --message \(shellQuote(message)) --json 2>&1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return "OpenClaw could not be launched: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 && out.contains("command not found") {
            return "OpenClaw is not installed on this Mac yet."
        }
        if out.isEmpty {
            out = process.terminationStatus == 0
                ? "(dispatched with no output)"
                : "openclaw exited with status \(process.terminationStatus)"
        }
        if out.count > 4000 { out = String(out.suffix(4000)) }
        return out
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Background events (gateway WebSocket, listen-only)

    /// Start listening for gateway events; reconnects every 60s while the
    /// gateway is unreachable. Events are delivered on the main queue.
    public func listenForBackgroundEvents(onEvent: @escaping (OpenClawEvent) -> Void) {
        self.onEvent = onEvent
        listening = true
        openSocket()
    }

    public func stopListening() {
        listening = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func openSocket() {
        guard listening else { return }
        let t = URLSession.shared.webSocketTask(with: Self.gatewayURL)
        task = t
        t.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, self.listening else { return }
            switch result {
            case .failure:
                // Gateway missing/down: retry quietly.
                self.task = nil
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) { self.openSocket() }
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                if let event = Self.mapEvent(data) {
                    DispatchQueue.main.async { self.onEvent?(event) }
                }
                self.receiveLoop()
            }
        }
    }

    /// Heuristic mapping of gateway JSON frames to notch states (pure,
    /// unit-tested). Unknown frames are ignored.
    public static func mapEvent(_ data: Data) -> OpenClawEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Collect plausible descriptor fields from common shapes.
        var descriptor = ""
        for key in ["type", "kind", "state", "status", "event", "method"] {
            if let v = obj[key] as? String { descriptor += v.lowercased() + " " }
        }
        if descriptor.isEmpty { return nil }
        let summary = (obj["summary"] as? String)
            ?? (obj["message"] as? String)
            ?? descriptor.trimmingCharacters(in: .whitespaces)

        let attention = ["finish", "complete", "done", "error", "fail", "alert", "attention", "pr "]
        let working = ["start", "running", "progress", "working", "busy", "dispatch"]
        if attention.contains(where: descriptor.contains) {
            return OpenClawEvent(kind: .attention, summary: summary)
        }
        if working.contains(where: descriptor.contains) {
            return OpenClawEvent(kind: .working, summary: summary)
        }
        return OpenClawEvent(kind: .info, summary: summary)
    }
}
