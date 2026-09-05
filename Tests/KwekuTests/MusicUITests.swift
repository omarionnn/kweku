import Foundation
import KwekuKit

/// The two pieces of the Spotify island that are real logic rather than layout:
/// interpolating the playhead between polls, and picking a colour off a cover.
enum MusicUITests {
    static func all() {
        playbackClock()
        albumPalette()
    }

    // MARK: Playback clock

    static func playbackClock() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        Check.run("playing position runs forward between polls") {
            let clock = PlaybackClock(anchor: 30, anchoredAt: t0,
                                      isPlaying: true, duration: 180)
            Check.eq(clock.position(at: t0), 30, "at the anchor")
            Check.eq(clock.position(at: t0 + 0.5), 30.5, "half a second later")
            Check.eq(clock.position(at: t0 + 0.9), 30.9, "just before the next poll")
        }
        Check.run("paused holds still") {
            let clock = PlaybackClock(anchor: 30, anchoredAt: t0,
                                      isPlaying: false, duration: 180)
            Check.eq(clock.position(at: t0 + 10), 30, "no drift while paused")
        }
        Check.run("never runs past the end of the track") {
            let clock = PlaybackClock(anchor: 179, anchoredAt: t0,
                                      isPlaying: true, duration: 180)
            // A poll can land late (the app was busy); the bar must not
            // overshoot into a progress > 1.
            Check.eq(clock.position(at: t0 + 30), 180, "clamped to the duration")
            Check.eq(clock.progress(at: t0 + 30), 1.0, "progress caps at 1")
            Check.eq(clock.remaining(at: t0 + 30), 0, "no negative remaining")
        }
        Check.run("a backwards clock doesn't rewind the bar") {
            let clock = PlaybackClock(anchor: 30, anchoredAt: t0,
                                      isPlaying: true, duration: 180)
            Check.eq(clock.position(at: t0 - 5), 30, "skew holds at the anchor")
        }
        Check.run("a track with no duration reports no progress") {
            let clock = PlaybackClock(anchor: 5, anchoredAt: t0,
                                      isPlaying: true, duration: 0)
            Check.eq(clock.progress(at: t0 + 1), 0, "no divide by zero")
        }
        Check.run("interpolation beats polling for smoothness") {
            let clock = PlaybackClock(anchor: 30, anchoredAt: t0,
                                      isPlaying: true, duration: 180)
            // Thirty frames across one poll interval must all differ — this is
            // the whole point, versus the old bar that moved once a second.
            let samples = (0..<30).map { clock.progress(at: t0 + Double($0) / 30) }
            Check.ok(Set(samples.map { Int($0 * 100_000) }).count == 30,
                     "every frame advances")
        }
    }

    // MARK: Album palette

    static func albumPalette() {
        Check.run("greyscale art yields no accent") {
            let greys = (0..<64).map { RGB(Double($0) / 64, Double($0) / 64, Double($0) / 64) }
            Check.ok(AlbumPalette.accent(from: greys) == nil, "black-and-white sleeve stays white")
        }
        Check.run("empty input is handled") {
            Check.ok(AlbumPalette.accent(from: []) == nil, "no pixels, no accent")
        }
        Check.run("a minority colour still wins over a dark majority") {
            // The common case: a mostly-black cover with a small bright motif.
            // Averaging the cover would return near-black; voting finds the red.
            var pixels = [RGB](repeating: RGB(0.02, 0.02, 0.02), count: 90)
            pixels += [RGB](repeating: RGB(0.85, 0.12, 0.15), count: 10)
            guard let accent = AlbumPalette.accent(from: pixels) else {
                return Check.ok(false, "expected an accent")
            }
            Check.ok(accent.r > accent.g && accent.r > accent.b, "reads as red")
            Check.ok(accent.hue < 30 || accent.hue > 330, "hue is in the reds")
        }
        Check.run("the winning hue is the most colourful, not the most common") {
            // Slightly more washed-out blue than vivid orange: the orange
            // should still win, because weight favours saturation.
            var pixels = [RGB](repeating: RGB(0.42, 0.46, 0.55), count: 60)
            pixels += [RGB](repeating: RGB(0.95, 0.55, 0.1), count: 40)
            guard let accent = AlbumPalette.accent(from: pixels) else {
                return Check.ok(false, "expected an accent")
            }
            Check.ok(accent.r > accent.b, "orange beat the washed blue")
        }
        Check.run("dark colours are lifted to something visible on black") {
            let murky = RGB(0.10, 0.03, 0.03)
            let lifted = AlbumPalette.readable(murky)
            Check.ok(lifted.brightness >= 0.72, "bright enough to see")
            Check.ok(lifted.saturation >= 0.55, "saturated enough to look deliberate")
            Check.ok(abs(lifted.hue - murky.hue) < 1, "hue survives the lift")
        }
        Check.run("blinding colours are pulled back") {
            let blinding = AlbumPalette.readable(RGB(1, 1, 0.99))
            Check.ok(blinding.brightness <= 0.98, "capped")
        }
        Check.run("hue survives a round trip through HSB") {
            for hue in stride(from: 0.0, to: 360.0, by: 30) {
                let colour = RGB(hue: hue, saturation: 0.8, brightness: 0.9)
                Check.ok(abs(colour.hue - hue) < 0.5, "\(hue)° round-trips")
            }
        }
    }
}
