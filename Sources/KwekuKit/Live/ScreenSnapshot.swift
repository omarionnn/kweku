import AppKit
import ScreenCaptureKit
import CoreImage

/// One frame of the focused window, on demand, without a Live session.
///
/// `ScreenCaptureManager` only holds a frame while it's streaming, which is
/// exactly the wrong shape for a command you fire once from the notch. This
/// renders a single frame through `SCScreenshotManager` and hands it back —
/// no stream, no retarget, nothing left running afterwards.
///
/// It honours redaction the same way the stream does, and refuses rather than
/// degrading: if the focused window is one Kweku isn't allowed to see, the
/// answer is "no", not a blanked placeholder. A one-shot path that could be
/// pointed at a password manager would make the whole redaction mechanism a
/// formality.
public enum ScreenSnapshot {

    public struct Shot: Sendable {
        public var jpeg: Data
        public var app: String
        public var title: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case noPermission
        /// The focused window is withheld by the redaction rules.
        case redacted(app: String, reason: String)
        case noWindow
        case failed(String)

        /// One line for the notch, in the second person.
        public var message: String {
            switch self {
            case .noPermission:
                return "Kweku needs Screen Recording to read your screen"
            case .redacted(let app, let reason):
                return "\(app) is hidden from Kweku — \(reason)"
            case .noWindow:
                return "No window to read"
            case .failed(let why):
                return why
            }
        }
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Resolve the frontmost qualifying window the same way the stream does.
    ///
    /// Shared with `ScreenCaptureManager.retarget` so a one-shot read and the
    /// Live stream can never disagree about which window is "in front" — two
    /// answers to that question is one too many.
    static func frontmostWindowID() -> UInt32? {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var policyCache: [Int32: Bool] = [:]
        func regular(_ pid: Int32) -> Bool {
            if let hit = policyCache[pid] { return hit }
            let isRegular = NSRunningApplication(processIdentifier: pid)?
                .activationPolicy == .regular
            policyCache[pid] = isRegular
            return isRegular
        }
        let windows = info.compactMap { d -> ScreenTargeting.WindowInfo? in
            guard let id = d[kCGWindowNumber as String] as? UInt32,
                  let owner = d[kCGWindowOwnerPID as String] as? Int32,
                  let layer = d[kCGWindowLayer as String] as? Int
            else { return nil }
            let bounds = d[kCGWindowBounds as String] as? [String: Any]
            return ScreenTargeting.WindowInfo(
                id: id, pid: owner, layer: layer,
                width: CGFloat((bounds?["Width"] as? Double) ?? 0),
                height: CGFloat((bounds?["Height"] as? Double) ?? 0),
                alpha: CGFloat((d[kCGWindowAlpha as String] as? Double) ?? 1),
                regularApp: regular(owner))
        }
        return ScreenTargeting.focusedWindowID(
            windows: windows,
            frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            excludingPid: ProcessInfo.processInfo.processIdentifier)
    }

    /// Grab the focused window now.
    public static func capture() async -> Result<Shot, Failure> {
        guard ScreenCaptureManager.hasScreenAccess else {
            CGRequestScreenCaptureAccess()
            return .failure(.noPermission)
        }
        guard #available(macOS 14.0, *) else {
            return .failure(.failed("Screen reading needs macOS 14 or later"))
        }
        guard let windowID = frontmostWindowID() else { return .failure(.noWindow) }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            let ns = error as NSError
            if ns.code == ScreenCaptureManager.userDeclined { return .failure(.noPermission) }
            return .failure(.failed("Screen capture unavailable: \(error.localizedDescription)"))
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return .failure(.noWindow)
        }

        let app = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        // Decided before a filter exists, exactly as the stream does it, so a
        // denied window is never rendered at all.
        let verdict = ScreenRedaction.verdict(for: .init(app: app, title: title),
                                              extraTerms: ScreenRedaction.userTerms,
                                              enabled: ScreenRedaction.enabled)
        if let reason = verdict.reason {
            return .failure(.redacted(app: app.isEmpty ? "That window" : app, reason: reason))
        }

        let config = SCStreamConfiguration()
        let size = ScreenTargeting.outputSize(for: window.frame.size)
        config.width = size.width
        config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) {
                buffer, error in
                guard error == nil, let buffer, buffer.isValid,
                      let pixels = CMSampleBufferGetImageBuffer(buffer),
                      let jpeg = ScreenCaptureManager.jpegData(from: pixels, context: ciContext)
                else {
                    continuation.resume(returning: .failure(.failed(
                        error.map { "Screen read failed: \($0.localizedDescription)" }
                            ?? "Screen read produced no image")))
                    return
                }
                continuation.resume(returning: .success(
                    Shot(jpeg: jpeg, app: app, title: title)))
            }
        }
    }
}
