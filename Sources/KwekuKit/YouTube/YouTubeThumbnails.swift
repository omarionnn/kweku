import AppKit

/// Thumbnails, fetched before the notch opens rather than while it is open.
///
/// A drop is on screen for two to five seconds. `AsyncImage` inside it would
/// spend the first of those showing a hole and then pop the picture in
/// halfway through the animation — the one moment the thing is being looked
/// at. So the image is pulled *before* the drop is posted, and the view reads
/// it synchronously from here, already decoded.
@MainActor
public enum YouTubeThumbnails {

    /// Small on purpose: this holds the last handful of announced videos, and
    /// a thumbnail is ~15 KB. Anything beyond the queue depth is dead weight.
    private static let limit = 24
    private static var cache: [URL: NSImage] = [:]
    private static var order: [URL] = []

    public static func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        return cache[url]
    }

    /// Fetch and decode, unless it's already in hand. Returns once it's ready
    /// to draw, so callers can await it before posting a notice.
    @discardableResult
    public static func prefetch(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let hit = cache[url] { return hit }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data)
        else { return nil }

        cache[url] = image
        order.append(url)
        if order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return image
    }
}
