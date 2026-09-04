import AppKit
import Combine

/// Orchestrates a Charlie Live session: websocket + mic/speaker + screen
/// stream + omp tool dispatch. Owned by `NotchContentRoot`; started/stopped
/// from the right-click menu (all permission prompts are lazy — they fire on
/// the user's first Start).
@MainActor
public final class LiveSessionController: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var status = ""

    public let audio = AudioEngineManager()
    private let screen = ScreenCaptureManager()
    private let client = GeminiLiveClient()

    /// Supplied by the content root: cwd of the most relevant agent session.
    public var ompCwdProvider: () -> String? = { nil }

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
        guard let key = Self.apiKey else { status = "no API key"; return false }

        client.onEvent = { [weak self] event in self?.handle(event) }
        client.onClose = { [weak self] reason in
            MainActor.assumeIsolated {
                self?.status = "closed: \(reason)"
                self?.stop()
            }
        }
        client.connect(apiKey: key, model: Self.model)

        audio.onMicChunk = { [weak self] chunk in self?.client.sendAudioChunk(chunk) }
        do { try audio.start() } catch {
            status = "audio failed: \(error.localizedDescription)"
            client.disconnect()
            return false
        }
        screen.startStreaming { [weak self] jpeg in self?.client.sendVideoFrame(jpeg) }

        running = true
        status = "connecting"
        return true
    }

    public func stop() {
        guard running else { return }
        screen.stop()
        audio.stop()
        client.disconnect()
        running = false
    }

    // MARK: - Event routing

    private func handle(_ event: GeminiServerEvent) {
        switch event {
        case .setupComplete:
            status = "live"
        case .audio(let pcm):
            audio.enqueuePlayback(pcm)
        case .interrupted:
            audio.interruptPlayback()
        case .toolCall(let id, let name, let prompt):
            let cwd = ompCwdProvider()
            Task { [weak self] in
                let output = name == "execute_omp_command"
                    ? await OMPBridgeManager.dispatchCommand(prompt, cwd: cwd)
                    : "unknown tool \(name)"
                self?.client.sendToolResponse(id: id, name: name, output: output)
            }
        case .goAway:
            status = "server ending session"
        case .turnComplete:
            break
        }
    }
}
