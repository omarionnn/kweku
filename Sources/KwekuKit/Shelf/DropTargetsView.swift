import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The choice strip that appears under the notch while a drag is armed.
///
/// Before this, every drop did the same thing — it went on the shelf. Dragging
/// something over the notch now offers three destinations, each its own drop
/// target, lighting up under the cursor.
struct DropTargetsView: View {
    @ObservedObject var shelf: ShelfStore
    /// Working directory of the most relevant agent session, if any. Nil
    /// disables the omp tile rather than dispatching into the wrong repo.
    var agentCwd: () -> String?
    /// Called with a short toast to show after a drop resolves.
    var onDispatch: (String) -> Void

    static let bodyHeight: CGFloat = 62
    static let expandedWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 8) {
            tile(symbol: "tray.full", title: "Shelf", tint: .white) { providers in
                shelf.ingest(providers)
                return "Added to shelf"
            }
            tile(symbol: "sparkles", title: "Ask Kweku", tint: .cyan) { providers in
                let what = await DropTargetsView.describe(providers)
                guard !what.isEmpty else { return "Nothing to ask about" }
                Task {
                    _ = await OpenClawBridgeManager.shared.dispatch(
                        instruction: "Take a look at this and tell me what I need to know: \(what)",
                        screenContext: nil)
                }
                return "Asked Kweku"
            }
            tile(symbol: "terminal", title: "To agent", tint: NotchRim.amber,
                 enabled: agentCwd() != nil) { providers in
                let what = await DropTargetsView.describe(providers)
                guard !what.isEmpty, let cwd = agentCwd() else { return "No agent session" }
                Task {
                    _ = await OMPBridgeManager.dispatchCommand(what, cwd: cwd)
                }
                return "Sent to \((cwd as NSString).lastPathComponent)"
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.bodyHeight)
    }

    // MARK: - Tile

    private func tile(symbol: String, title: String, tint: Color, enabled: Bool = true,
                      action: @escaping ([NSItemProvider]) async -> String) -> some View {
        DropTile(symbol: symbol, title: title, tint: tint, enabled: enabled) { providers in
            Task { onDispatch(await action(providers)) }
        }
    }

    // MARK: - Payload description

    /// Turn dropped providers into one line of text an agent can act on: file
    /// paths, URLs, or the literal text. Images have no textual form, so they
    /// come back empty and the caller declines the drop.
    static func describe(_ providers: [NSItemProvider]) async -> String {
        var parts: [String] = []
        for provider in providers {
            if let part = await describeOne(provider) { parts.append(part) }
        }
        return parts.joined(separator: " ")
    }

    private static func describeOne(_ provider: NSItemProvider) async -> String? {
        let ids = provider.registeredTypeIdentifiers
        // File first: a file drag also advertises a plain URL we must ignore.
        if ids.contains(UTType.fileURL.identifier) || ids.contains(UTType.url.identifier) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url.map { $0.isFileURL ? $0.path : $0.absoluteString })
                }
            }
        }
        if ids.contains(UTType.plainText.identifier) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    continuation.resume(returning: string as? String)
                }
            }
        }
        return nil
    }
}

/// One drop destination. Owns its own `isTargeted` so the tiles light up
/// independently as the cursor crosses between them.
private struct DropTile: View {
    var symbol: String
    var title: String
    var tint: Color
    var enabled: Bool
    var perform: ([NSItemProvider]) -> Void

    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? tint : tint.opacity(0.3))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 0.75 : 0.28))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.16 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(targeted ? tint.opacity(0.9) : Color.white.opacity(0.1),
                              lineWidth: targeted ? 1.4 : 0.5)
        )
        .scaleEffect(targeted ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
        .onDrop(of: ShelfStore.acceptedTypes, isTargeted: $targeted) { providers in
            guard enabled else { return false }
            perform(providers)
            return true
        }
    }
}
