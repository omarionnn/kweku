import Foundation

/// Current Spotify state. Built by parsing one tab-delimited AppleScript
/// result, so the parsing is pure and unit-tested.
public struct NowPlaying: Equatable, Sendable {
    public var appRunning: Bool
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    public var album: String
    public var durationSec: Double
    public var positionSec: Double
    public var artworkURL: URL?
    public var trackID: String

    public init(appRunning: Bool, isPlaying: Bool, title: String, artist: String,
                album: String, durationSec: Double, positionSec: Double,
                artworkURL: URL?, trackID: String) {
        self.appRunning = appRunning; self.isPlaying = isPlaying
        self.title = title; self.artist = artist; self.album = album
        self.durationSec = durationSec; self.positionSec = positionSec
        self.artworkURL = artworkURL; self.trackID = trackID
    }

    public static let notRunning = NowPlaying(
        appRunning: false, isPlaying: false, title: "", artist: "", album: "",
        durationSec: 0, positionSec: 0, artworkURL: nil, trackID: "")

    /// Whether there's a track to display (playing or paused).
    public var hasTrack: Bool { appRunning && !trackID.isEmpty }

    /// Playback progress, 0…1.
    public var progress: Double {
        durationSec > 0 ? min(1, max(0, positionSec / durationSec)) : 0
    }

    /// Parse the AppleScript payload (see `SpotifyController.getScript`):
    /// `state \t name \t artist \t album \t durationMs \t positionSec \t artworkURL \t id`.
    /// A bare `stopped` (or anything short) means "app up, nothing to show".

    /// `m:ss` formatter for scrubber labels.
    public static func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    public static func parse(_ raw: String) -> NowPlaying {
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        guard fields.count >= 8 else {
            return NowPlaying(appRunning: true, isPlaying: fields.first == "playing",
                              title: "", artist: "", album: "", durationSec: 0,
                              positionSec: 0, artworkURL: nil, trackID: "")
        }
        let durationMs = Double(fields[4]) ?? 0
        return NowPlaying(
            appRunning: true,
            isPlaying: fields[0] == "playing",
            title: fields[1], artist: fields[2], album: fields[3],
            durationSec: durationMs / 1000,
            positionSec: Double(fields[5]) ?? 0,
            artworkURL: URL(string: fields[6]),
            trackID: fields[7])
    }
}
