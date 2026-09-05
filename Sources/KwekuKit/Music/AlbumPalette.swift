import Foundation

/// A plain 0…1 RGB triple, so the colour maths stays free of AppKit and can be
/// unit-tested against synthetic pixels.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public var brightness: Double { max(r, max(g, b)) }
    public var saturation: Double {
        let hi = brightness, lo = min(r, min(g, b))
        return hi <= 0 ? 0 : (hi - lo) / hi
    }
    /// Hue in degrees, 0…360. Meaningless when saturation is 0.
    public var hue: Double {
        let hi = brightness, lo = min(r, min(g, b)), d = hi - lo
        guard d > 0 else { return 0 }
        let h: Double
        switch hi {
        case r: h = 60 * ((g - b) / d)
        case g: h = 60 * (2 + (b - r) / d)
        default: h = 60 * (4 + (r - g) / d)
        }
        return h < 0 ? h + 360 : h
    }

    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        self.init(r1 + m, g1 + m, b1 + m)
    }
}

/// Picks the one colour from album art that should tint the island.
///
/// Averaging the whole cover gives mud — every record averages to grey-brown.
/// Instead pixels vote in hue buckets, weighted by how colourful and how bright
/// they are, and the winning bucket's average becomes the accent. Cover art is
/// often mostly black or mostly a photo, so the colour that *reads* is usually
/// a minority of the pixels: the neon on the sleeve, not the background.
///
/// The result is then forced to be legible on a black island — real album
/// colours are frequently too dark or too washed to sit on the notch.
public enum AlbumPalette {
    /// Pixels below these are treated as background, not colour.
    static let minSaturation = 0.18
    static let minBrightness = 0.12
    /// Blown-out highlights carry no usable hue.
    static let maxBrightness = 0.97
    /// Below this share of colourful pixels, treat the art as greyscale.
    static let minColourfulShare = 0.02

    /// The accent for a downsampled cover, or nil when the art has no colour
    /// worth using (black-and-white sleeves) — the caller falls back to white.
    public static func accent(from pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }

        let bucketCount = 12                       // 30° per bucket
        var weights = [Double](repeating: 0, count: bucketCount)
        var sums = [RGB](repeating: RGB(0, 0, 0), count: bucketCount)
        var colourful = 0

        for p in pixels {
            let s = p.saturation, v = p.brightness
            guard s >= minSaturation, v >= minBrightness, v <= maxBrightness else { continue }
            colourful += 1
            // Saturated beats washed; mid-bright beats murky.
            let weight = s * (0.35 + 0.65 * v)
            let bucket = min(bucketCount - 1, Int(p.hue / 360 * Double(bucketCount)))
            weights[bucket] += weight
            sums[bucket] = RGB(sums[bucket].r + p.r * weight,
                               sums[bucket].g + p.g * weight,
                               sums[bucket].b + p.b * weight)
        }

        guard Double(colourful) / Double(pixels.count) >= minColourfulShare,
              let winner = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[winner] > 0
        else { return nil }

        let total = weights[winner]
        let mean = RGB(sums[winner].r / total, sums[winner].g / total, sums[winner].b / total)
        return readable(mean)
    }

    /// Force a colour to read as an accent on black: keep the hue, guarantee
    /// enough saturation to look deliberate and enough brightness to be seen,
    /// and pull back blinding highlights.
    public static func readable(_ colour: RGB) -> RGB {
        RGB(hue: colour.hue,
            saturation: min(0.92, max(0.55, colour.saturation)),
            brightness: min(0.98, max(0.72, colour.brightness)))
    }
}
