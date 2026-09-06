import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit view that both draws a thumbnail and starts an `NSFilePromiseProvider`
/// drag so held items can be dropped into Finder, Mail, Slack, etc.
final class ShelfItemDragView: NSView, NSFilePromiseProviderDelegate {
    var image: NSImage? { didSet { needsDisplay = true } }
    var fileType: String = UTType.data.identifier
    var fileName: String = "item"
    var payload: PromisePayload?
    /// Take this item off the shelf. Owned here rather than by a SwiftUI
    /// `.contextMenu` on the representable: right-clicks land on *this* view,
    /// and with no menu of its own AppKit walked the event up to the notch's
    /// own context menu — so the only way to remove an item opened the
    /// Critter/Weather/Agents menu instead, and the item could never leave.
    var onRemove: (() -> Void)?

    private let ioQueue = OperationQueue()

    override var wantsUpdateLayer: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // Needed so the view is in the responder chain for the drag.
    override func mouseDown(with event: NSEvent) {}

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onRemove != nil else { return nil }
        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove from Shelf",
                                action: #selector(removeFromShelf), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    /// Posted explicitly rather than left to `NSView`'s default handling: the
    /// notch floats in a borderless panel that can never become key, and the
    /// default path is unreliable there.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else {
            super.rightMouseDown(with: event); return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeFromShelf() { onRemove?() }

    override func mouseDragged(with event: NSEvent) {
        guard payload != nil else { return }
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        let dragItem = NSDraggingItem(pasteboardWriter: provider)
        let preview = image ?? NSImage(size: bounds.size)
        dragItem.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let payload else {
            completionHandler(CocoaError(.fileWriteUnknown)); return
        }
        do { try payload.write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { ioQueue }
}

extension ShelfItemDragView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// SwiftUI bridge placing a draggable thumbnail.
struct ShelfThumb: NSViewRepresentable {
    let item: ShelfItem
    let store: ShelfStore

    func makeNSView(context: Context) -> ShelfItemDragView { ShelfItemDragView() }

    func updateNSView(_ view: ShelfItemDragView, context: Context) {
        view.image = store.thumbnail(for: item)
        view.fileType = item.dragUTI
        view.fileName = item.suggestedFilename
        view.payload = store.promisePayload(for: item)
        // Captures the item, not the view, so the removal still completes when
        // opening the menu drops the hover and takes the shelf away underneath.
        view.onRemove = { [weak store] in
            Task { @MainActor in store?.remove(item) }
        }
    }
}
