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
    }
}
