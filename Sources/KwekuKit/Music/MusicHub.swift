import AppKit
import Combine
import SwiftUI
import CoreImage

/// Automatic Spotify watcher — no toggle. The Spotify *process* is detected
/// permission-free via NSWorkspace launch/terminate notifications; polling
/// (and therefore the one-time Automation prompt) only happens while Spotify
/// is actually running. The island shows while a track is playing and for a
/// 30s grace period after pause, then yields back to the critter.
@MainActor
public final class MusicHub: ObservableObject {
    @Published public private(set) var now: NowPlaying = .notRunning
    @Published public private(set) var artwork: NSImage?
    /// Accent pulled from the current cover; nil for greyscale art, where the
    /// island stays white rather than tinting itself an arbitrary colour.
    @Published public private(set) var accent: RGB?
    /// Anchor for interpolating the playhead between polls.
    @Published public private(set) var clock = PlaybackClock()
    @Published public private(set) var permissionDenied = false
    /// Whether the island should occupy the notch right now.
    @Published public private(set) var showing = false

    private var timer: Timer?
    private var loadedArtworkURL: String?
    private var lastPlayingAt: Date = .distantPast
    private var observers: [NSObjectProtocol] = []
    /// Volume-write throttle state — see `setVolume`.
    private var volumeSentAt: Date = .distantPast
    private var volumeFlush: DispatchWorkItem?

    public init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, launched) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                 (NSWorkspace.didTerminateApplicationNotification, false)] {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == SpotifyController.bundleID else { return }
                MainActor.assumeIsolated { launched ? self?.startPolling() : self?.stopPolling() }
            }
            observers.append(obs)
        }
        if SpotifyController.isRunning() { startPolling() }
    }

    deinit {
        for obs in observers { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        timer?.invalidate()
    }

    /// Pure showing rule (unit-tested): playing, or paused within the grace.
    public nonisolated static func shouldShow(hasTrack: Bool, isPlaying: Bool,
                                              secondsSincePlaying: TimeInterval,
                                              grace: TimeInterval = 30) -> Bool {
        hasTrack && (isPlaying || secondsSincePlaying < grace)
    }

    public var isShowing: Bool { showing }

    private func startPolling() {
        guard timer == nil else { return }
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
        accent = nil
        loadedArtworkURL = nil
        clock = PlaybackClock()
        permissionDenied = false
        showing = false
    }

    private func poll() {
        let result = SpotifyController.fetch()
        if ProcessInfo.processInfo.environment["KWEKU_MUSIC_DEBUG"] != nil {
            FileHandle.standardError.write(Data("music fetch=\(result)\n".utf8))
        }
        switch result {
        case .ok(let np):
            permissionDenied = false
            if np != now { now = np }
            // Re-anchor every poll, not just on change: this is also what
            // absorbs playback moving without us (scrubbed in Spotify itself,
            // skipped from the menu bar, AirPods double-tap).
            reanchor()
            if np.isPlaying { lastPlayingAt = Date() }
            loadArtworkIfNeeded(np)
        case .notRunning:
            permissionDenied = false
            if now != .notRunning {
                now = .notRunning; artwork = nil; accent = nil; loadedArtworkURL = nil
                clock = PlaybackClock()
            }
        case .denied:
            permissionDenied = true
        case .failed:
            break
        }
        let show = Self.shouldShow(hasTrack: now.hasTrack, isPlaying: now.isPlaying,
                                   secondsSincePlaying: Date().timeIntervalSince(lastPlayingAt))
        if show != showing { showing = show }
    }

    private func loadArtworkIfNeeded(_ np: NowPlaying) {
        guard let url = np.artworkURL else {
            artwork = nil; accent = nil; loadedArtworkURL = nil; return
        }
        guard url.absoluteString != loadedArtworkURL else { return }
        loadedArtworkURL = url.absoluteString
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            let accent = AlbumPalette.accent(for: image)
            await MainActor.run { self?.artwork = image; self?.accent = accent }
        }
    }

    // MARK: Controls (optimistic; a poll reconciles within ~1s)

    public func togglePlayPause() {
        SpotifyController.playPause()
        now.isPlaying.toggle()
        reanchor()
    }

    public func next() { SpotifyController.next() }
    public func previous() { SpotifyController.previous() }

    public func seek(toFraction fraction: Double) {
        let seconds = max(0, min(1, fraction)) * now.durationSec
        SpotifyController.seek(toSeconds: seconds)
        now.positionSec = seconds
        reanchor()
    }

    /// Set Spotify's output level, 0…100.
    ///
    /// The local value moves immediately so the slider tracks the cursor, but
    /// the AppleScript write is throttled. A drag across the bar crosses ~100
    /// whole percents, and `NSAppleScript.executeAndReturnError` is synchronous
    /// on the main thread — sending one per sample would stutter the very
    /// animation the slider is trying to draw. Trailing-edge, so the value you
    /// release on is always the value that lands.
    public func setVolume(_ percent: Int) {
        let clamped = SpotifyController.clampVolume(percent)
        guard clamped != now.volume else { return }
        now.volume = clamped
        scheduleVolumeSend(clamped)
    }

    /// Ceiling of ~12 writes a second — far below what a drag generates, far
    /// above what a finger can perceive as lag.
    private static let volumeSendInterval: TimeInterval = 0.08

    private func scheduleVolumeSend(_ value: Int) {
        volumeFlush?.cancel()
        volumeFlush = nil
        let since = Date().timeIntervalSince(volumeSentAt)
        guard since < Self.volumeSendInterval else { return sendVolume(value) }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.sendVolume(value) }
        }
        volumeFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.volumeSendInterval - since),
                                      execute: work)
    }

    private func sendVolume(_ value: Int) {
        volumeFlush = nil
        volumeSentAt = Date()
        SpotifyController.setVolume(value)
    }

    public func toggleShuffle() {
        let next = !now.shuffling
        SpotifyController.setShuffling(next)
        now.shuffling = next
    }

    public func toggleRepeat() {
        let next = !now.repeating
        SpotifyController.setRepeating(next)
        now.repeating = next
    }

    /// Pin the clock to what we currently believe, as of now.
    private func reanchor() {
        clock = PlaybackClock(anchor: now.positionSec, anchoredAt: Date(),
                              isPlaying: now.isPlaying, duration: now.durationSec)
    }
}
