import AppKit
import CoreGraphics

extension AlbumPalette {
    /// Side length of the grid the cover is squashed into before voting. Small
    /// on purpose: it costs nothing, and averaging away JPEG noise and fine
    /// detail leaves the broad colour regions the eye actually registers.
    static let sampleSide = 16

    /// Downsample a cover and pick its accent. Returns nil for greyscale art or
    /// anything we can't read.
    public static func accent(for image: NSImage) -> RGB? {
        guard let pixels = sample(image) else { return nil }
        return accent(from: pixels)
    }

    static func sample(_ image: NSImage) -> [RGB]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let side = sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &bytes, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        return stride(from: 0, to: bytes.count, by: 4).compactMap { i in
            // Skip transparent pixels: premultiplied, so they'd read as black
            // and drag the vote toward "no colour here".
            guard bytes[i + 3] > 200 else { return nil }
            return RGB(Double(bytes[i]) / 255,
                       Double(bytes[i + 1]) / 255,
                       Double(bytes[i + 2]) / 255)
        }
    }
}
