import Foundation
import KwekuKit

enum NowPlayingTests {
    static func all() {
        let tab = "\t"

        Check.run("parses a full playing payload") {
            let raw = ["playing", "Song", "Artist", "Album", "210000", "63.5",
                       "https://i.scdn.co/image/abc", "spotify:track:xyz"].joined(separator: tab)
            let np = NowPlaying.parse(raw)
            Check.ok(np.appRunning && np.isPlaying, "playing")
            Check.ok(np.title == "Song" && np.artist == "Artist" && np.album == "Album", "fields")
            Check.eq(np.durationSec, 210, "ms -> seconds")
            Check.eq(np.positionSec, 63.5, "position seconds")
            Check.ok(np.artworkURL?.absoluteString == "https://i.scdn.co/image/abc", "artwork url")
            Check.ok(np.trackID == "spotify:track:xyz", "id")
            Check.ok(np.hasTrack, "has a track")
        }

        Check.run("paused payload has a track but is not playing") {
            let raw = ["paused", "S", "A", "Al", "120000", "0", "https://x/y", "id1"].joined(separator: tab)
            let np = NowPlaying.parse(raw)
            Check.ok(!np.isPlaying && np.hasTrack, "paused with track")
        }

        Check.run("stopped payload has no track") {
            let np = NowPlaying.parse("stopped")
            Check.ok(np.appRunning, "app still up")
            Check.ok(!np.isPlaying && !np.hasTrack, "nothing to show")
        }

        Check.run("progress is position/duration, clamped") {
            var np = NowPlaying.parse(["playing", "S", "A", "Al", "100000", "50", "https://x/y", "id"].joined(separator: tab))
            Check.eq(np.progress, 0.5, "half way")
            np.positionSec = 999
            Check.eq(np.progress, 1, "clamped to 1")
            np.durationSec = 0
            Check.eq(np.progress, 0, "no divide-by-zero")
        }

        Check.run("time formatting") {
            Check.ok(NowPlaying.formatTime(0) == "0:00", "zero")
            Check.ok(NowPlaying.formatTime(63) == "1:03", "1:03")
            Check.ok(NowPlaying.formatTime(605) == "10:05", "10:05")
        }

        Check.run("auto-show rule: playing, or paused within grace") {
            Check.ok(MusicHub.shouldShow(hasTrack: true, isPlaying: true, secondsSincePlaying: 999),
                     "playing always shows")
            Check.ok(MusicHub.shouldShow(hasTrack: true, isPlaying: false, secondsSincePlaying: 30),
                     "paused 30s still shows")
            Check.ok(!MusicHub.shouldShow(hasTrack: true, isPlaying: false, secondsSincePlaying: 61),
                     "paused 61s yields to critter")
            Check.ok(!MusicHub.shouldShow(hasTrack: false, isPlaying: false, secondsSincePlaying: 0),
                     "no track never shows")
        }
    }
}
