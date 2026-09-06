import AppKit
import UniformTypeIdentifiers

/// Holds the notch's items: ingestion from the pasteboard/drops, persistence
/// via bookmarks in Application Support, thumbnails, and drag-out payloads.
@MainActor
public final class ShelfStore: ObservableObject {
    @Published public private(set) var items: [ShelfItem] = []

    /// Drag types the notch accepts.
    public static let acceptedTypes: [UTType] = [.fileURL, .url, .png, .tiff, .plainText]

    private var thumbnailCache: [UUID: NSImage] = [:]

    public init() { load() }

    // MARK: - Storage locations

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kweku", isDirectory: true)
        // One-time migration from pre-rebrand data directories.
        if !FileManager.default.fileExists(atPath: dir.path) {
            for old in ["Charlie", "Notchling"] {
                let legacy = base.appendingPathComponent(old, isDirectory: true)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try? FileManager.default.moveItem(at: legacy, to: dir)
                    break
                }
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var blobsDir: URL {
        let dir = supportDir.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var shelfFile: URL { supportDir.appendingPathComponent("shelf.json") }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.shelfFile),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }
        items = decoded.sorted { $0.addedAt > $1.addedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.shelfFile, options: .atomic)
    }

    // MARK: - Mutation

    public func remove(_ item: ShelfItem) {
        discardBlob(of: item)
        items.removeAll { $0.id == item.id }
        thumbnailCache[item.id] = nil
        save()
    }

    /// Empty the shelf in one write. The blobs go first, then the list — the
    /// old form called `remove` per item *while iterating that same list*, and
    /// re-saved the file once per item to reach the same end state.
    public func clear() {
        for item in items { discardBlob(of: item) }
        items.removeAll()
        thumbnailCache.removeAll()
        save()
    }

    /// Delete an item's backing image bytes, if it has any.
    private func discardBlob(of item: ShelfItem) {
        guard let blob = item.blobFile else { return }
        try? FileManager.default.removeItem(at: Self.blobsDir.appendingPathComponent(blob))
    }

    private func add(_ item: ShelfItem) {
        items.insert(item, at: 0)
        save()
    }

    // MARK: - Ingestion (drop / pasteboard)

    /// Asynchronously ingest dropped item providers. Returns immediately; the
    /// UI updates as each provider resolves.
    public func ingest(_ providers: [NSItemProvider]) {
        for provider in providers { ingestOne(provider) }
    }

    private func ingestOne(_ provider: NSItemProvider) {
        let ids = provider.registeredTypeIdentifiers

        // File first — a file drag also carries a plain URL we must ignore.
        if ids.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in self?.addFile(url) }
            }
            return
        }
        if ids.contains(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor in self?.addLink(url) }
            }
            return
        }
        for imgType in [UTType.png, UTType.tiff] where ids.contains(imgType.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: imgType.identifier) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in self?.addImage(data, uti: imgType.identifier) }
            }
            return
        }
        if ids.contains(UTType.plainText.identifier) {
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] string, _ in
                guard let s = string as? String else { return }
                Task { @MainActor in self?.addText(s) }
            }
        }
    }

    private func addFile(_ url: URL) {
        let uti = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier
        let bookmark = makeBookmark(for: url)
        add(ShelfItem(kind: .file, displayName: url.lastPathComponent,
                      bookmark: bookmark, uti: uti))
    }

    private func addLink(_ url: URL) {
        add(ShelfItem(kind: .link, displayName: url.host ?? "link",
                      urlString: url.absoluteString))
    }

    private func addText(_ string: String) {
        let firstLine = string.split(whereSeparator: \.isNewline).first.map(String.init) ?? "note"
        add(ShelfItem(kind: .text, displayName: String(firstLine.prefix(24)), text: string))
    }

    private func addImage(_ data: Data, uti: String) {
        let id = UUID()
        let ext = (uti == UTType.tiff.identifier) ? "tiff" : "png"
        let name = "\(id.uuidString).\(ext)"
        try? data.write(to: Self.blobsDir.appendingPathComponent(name))
        add(ShelfItem(id: id, kind: .image, displayName: "image",
                      blobFile: name, uti: uti))
    }

    private func makeBookmark(for url: URL) -> Data? {
        // Security-scoped where possible; fall back to a plain bookmark
        // (non-sandboxed builds still resolve either).
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope],
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData()
    }

    // MARK: - Drag-out

    /// Build the `Sendable` write payload for an item, reading any blob now so
    /// the background promise writer never re-enters the store.
    public func promisePayload(for item: ShelfItem) -> PromisePayload? {
        switch item.kind {
        case .file:  return item.bookmark.map { .file(bookmark: $0) }
        case .text:  return item.text.map { .text($0) }
        case .link:  return item.urlString.map { .link($0) }
        case .image:
            guard let blob = item.blobFile,
                  let data = try? Data(contentsOf: Self.blobsDir.appendingPathComponent(blob))
            else { return nil }
            return .image(data)
        }
    }

    // MARK: - Thumbnails

    public func thumbnail(for item: ShelfItem) -> NSImage {
        if let cached = thumbnailCache[item.id] { return cached }
        let image = makeThumbnail(for: item)
        thumbnailCache[item.id] = image
        return image
    }

    private func makeThumbnail(for item: ShelfItem) -> NSImage {
        let side: CGFloat = 40
        switch item.kind {
        case .file:
            if let bm = item.bookmark, let url = PromisePayload.resolve(bm) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: side, height: side)
                return icon
            }
            return symbol("doc", side: side)
        case .image:
            if let blob = item.blobFile,
               let img = NSImage(contentsOf: Self.blobsDir.appendingPathComponent(blob)) {
                return resized(img, side: side)
            }
            return symbol("photo", side: side)
        case .link:
            return symbol("link", side: side)
        case .text:
            return symbol("doc.text", side: side)
        }
    }

    private func symbol(_ name: String, side: CGFloat) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.6, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = false
        return img
    }

    private func resized(_ image: NSImage, side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
