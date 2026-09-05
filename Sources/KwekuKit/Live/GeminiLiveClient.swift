import Foundation

/// Persistent websocket to the Gemini Live API. Owns nothing but the socket:
/// wire formats live in `GeminiLiveProtocol`; orchestration in
/// `LiveSessionController`. Events are delivered on the main queue.
final class GeminiLiveClient {
    enum State { case idle, connecting, live, closed }

    private(set) var state: State = .idle
    private var task: URLSessionWebSocketTask?

    var onEvent: ((GeminiServerEvent) -> Void)?
    var onClose: ((String) -> Void)?

    func connect(apiKey: String, model: String) {
        guard var components = URLComponents(string: GeminiLiveProtocol.endpointBase) else { return }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return }

        state = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(GeminiLiveProtocol.setup(model: model))
        receiveLoop()
    }

    func disconnect() {
        state = .closed
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Outgoing

    func sendAudioChunk(_ pcm16k: Data) {
        guard state == .live else { return }
        send(GeminiLiveProtocol.audioChunk(pcm16k))
    }

    func sendVideoFrame(_ jpeg: Data) {
        guard state == .live else { return }
        send(GeminiLiveProtocol.videoFrame(jpeg))
    }

    func sendToolResponse(id: String, name: String, output: String) {
        send(GeminiLiveProtocol.toolResponse(id: id, name: name, output: output))
    }

    /// Deliver a late OpenClaw result as a fresh turn so the model speaks it.
    func sendClientText(_ text: String) {
        guard state == .live else { return }
        send(GeminiLiveProtocol.clientText(text))
    }

    private func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if let error {
                DispatchQueue.main.async { self?.fail("send: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Incoming

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self.fail("receive: \(error.localizedDescription)") }
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                let events = GeminiLiveProtocol.parse(data)
                DispatchQueue.main.async {
                    for event in events {
                        if case .setupComplete = event { self.state = .live }
                        self.onEvent?(event)
                    }
                }
                self.receiveLoop()
            }
        }
    }

    private func fail(_ reason: String) {
        guard state != .closed else { return }
        state = .closed
        task = nil
        onClose?(reason)
    }
}
