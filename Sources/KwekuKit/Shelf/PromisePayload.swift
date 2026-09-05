import Foundation

/// A self-contained, `Sendable` snapshot of what to write when a held item is
/// dragged out via `NSFilePromiseProvider`. Captured on the main actor, then
/// executed on the promise's background queue — so the writer never touches
/// the store or the main actor.
public enum PromisePayload: Sendable {
    case file(bookmark: Data)
    case image(Data)
    case text(String)
    case link(String)

    /// Materialise the item at `url` (the destination the receiver chose).
    public func write(to url: URL) throws {
        let fm = FileManager.default
        switch self {
        case .file(let bookmark):
            guard let src = Self.resolve(bookmark) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(at: src, to: url)
        case .image(let data):
            try data.write(to: url)

        case .text(let string):
            try Data(string.utf8).write(to: url)

        case .link(let string):
            // Finder-recognised .webloc plist.
            let plist: [String: Any] = ["URL": string]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url)
        }
    }

    /// Resolve a bookmark, tolerating both security-scoped and plain bookmarks
    /// (non-sandboxed builds may have produced either).
    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return try? URL(resolvingBookmarkData: bookmark, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
