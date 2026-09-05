import AppKit
import Combine

/// Opt-in Spotify watcher. Polls the desktop app ~1s and publishes now-playing
/// state + cached artwork for the Dynamic-Island panel.
///
/// Off by default. Enabling it is the lazy trigger for the one-time Automation
/// prompt (only when Spotify is also running). Album art is fetched from the
/// URL Spotify provides — the module's one network use; nothing is fetched
/// while the module is disabled.
@MainActor
public final class MusicHub: ObservableObject {
    @Published public private(set) var enabled = false
    @Published public private(set) var now: NowPlaying = .notRunning
    @Published public private(set) var artwork: NSImage?
    @Published public private(set) var permissionDenied = false

    private var timer: Timer?
    private var loadedArtworkURL: String?

    private let defaultsKey = "musicEnabled"

    public init() {
        enabled = UserDefaults.standard.bool(forKey: defaultsKey)
        if enabled { startPolling() }
    }

    /// A track worth showing (module on, Spotify up, something loaded).
    public var isShowing: Bool { enabled && now.hasTrack }

    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: defaultsKey)
        if on { startPolling() } else { stopPolling() }
    }

    private func startPolling() {
        // Defer the first poll: it runs a synchronous AppleScript Apple Event,
        // which must not happen during view construction / first render (it
        // races SwiftUI's update and aborts the process).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        timer?.invalidate(); timer = nil
        now = .notRunning
        artwork = nil
        loadedArtworkURL = nil
        permissionDenied = false
    }

    private func poll() {
        let result = SpotifyController.fetch()
        if ProcessInfo.processInfo.environment["KWEKU_MUSIC_DEBUG"] != nil {
            FileHandle.standardError.write(Data("music fetch=\(result) enabled=\(enabled)\n".utf8))
        }
        switch result {
        case .ok(let np):
            permissionDenied = false
            if np != now { now = np }
            loadArtworkIfNeeded(np)
        case .notRunning:
            permissionDenied = false
            if now != .notRunning { now = .notRunning; artwork = nil; loadedArtworkURL = nil }
        case .denied:
            permissionDenied = true
        case .failed:
            break
        }
    }

    private func loadArtworkIfNeeded(_ np: NowPlaying) {
        guard let url = np.artworkURL else {
            artwork = nil; loadedArtworkURL = nil; return
        }
        guard url.absoluteString != loadedArtworkURL else { return }
        loadedArtworkURL = url.absoluteString
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            await MainActor.run { self?.artwork = image }
        }
    }

    // MARK: Controls (optimistic; a poll reconciles within ~1s)

    public func togglePlayPause() {
        SpotifyController.playPause()
        now.isPlaying.toggle()
    }

    public func next() { SpotifyController.next() }
    public func previous() { SpotifyController.previous() }

    public func seek(toFraction fraction: Double) {
        let seconds = max(0, min(1, fraction)) * now.durationSec
        SpotifyController.seek(toSeconds: seconds)
        now.positionSec = seconds
    }
}
