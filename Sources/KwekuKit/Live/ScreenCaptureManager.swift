import AppKit
import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Pure targeting maths for the screen stream (unit-tested).
public enum ScreenTargeting {
    /// Frontmost regular window of `pid` from a front-to-back window list —
    /// the first layer-0 entry the compositor reports for that process.
    public static func frontWindowID(pid: Int32,
                                     windows: [(id: UInt32, pid: Int32, layer: Int)]) -> UInt32? {
        windows.first { $0.pid == pid && $0.layer == 0 }?.id
    }

    /// Output size for a window: at native pixels when small, capped at
    /// `maxLong` on the long edge, aspect preserved, even dimensions (the
    /// encoder dislikes odd ones). Legibility beats bandwidth here — a capped
    /// single window is still far sharper than a whole squashed desktop.
    public static func outputSize(for size: CGSize, scale: CGFloat = 2,
                                  maxLong: CGFloat = 1280) -> (width: Int, height: Int) {
        var w = max(2, size.width * scale), h = max(2, size.height * scale)
        let long = max(w, h)
        if long > maxLong {
            let f = maxLong / long
            w *= f; h *= f
        }
        return (Int(w / 2) * 2, Int(h / 2) * 2)
    }
}

/// Streams the *focused window* for the Live session's vision channel.
///
/// The old behaviour — whole first display, squashed to 720p — is why "read my
/// screen" kept missing the window the user was actually in: a window on a
/// second display was never captured at all, and on a big display it shrank
/// into illegibility. Now the stream targets the frontmost window itself
/// (`SCContentFilter(desktopIndependentWindow:)`), retargets when focus moves,
/// and falls back to the keyboard-focus display when no window qualifies.
///
/// Captures internally at 5 FPS but *sends* at 1 FPS — so `noteUserTurn()`
/// can push a fresh frame within ~200ms when it's the user's turn to ask.
/// Frames are ≤1280-long-edge JPEG to keep token usage down.
final class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var onFrame: ((Data) -> Void)?
    private var lastSentAt = Date.distantPast
    private var sendASAP = false
    private var framesSent = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.kweku.screencap")

    // What the stream is aimed at right now. Written on main (retarget path),
    // read on main; the SCStream holds the actual filter.
    private var targetWindowID: CGWindowID = 0        // 0 = display fallback
    private var targetDisplayID: CGDirectDisplayID = 0
    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    /// Surfaced problems (missing permission, stream death) for the UI/status.
    var onIssue: ((String) -> Void)?

    /// Most recent frame sent upstream, kept so a dispatched OpenClaw task can
    /// carry the actual screen rather than a description of it. Written on
    /// `queue`, read from main.
    private let frameLock = NSLock()
    private var lastFrame: Data?

    /// The current screen as JPEG, at most ~1s old. Nil before the first frame
    /// or when screen capture isn't permitted.
    func latestFrame() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return lastFrame
    }


    // MARK: - Lifecycle

    func startStreaming(onFrame: @escaping (Data) -> Void) {
        self.onFrame = onFrame

        // Explicit, surfaced permission check instead of silent no-frames.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onIssue?("Screen Recording not granted — enable Kweku in System Settings › Privacy › Screen Recording, then relaunch. Session continues audio-only.")
            return
        }

        retarget(force: true)

        // Focus moves two ways: another app activates (notification), or the
        // user switches windows within the app (nothing fires — poll gently).
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.retarget() }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.retarget() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        onFrame = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        targetWindowID = 0
        targetDisplayID = 0
    }

    /// The user is about to speak/ask — re-aim at whatever is focused *now*,
    /// then push the next captured frame immediately so the model sees the
    /// current window, not the one focus left a second ago.
    func noteUserTurn() {
        retarget()
        queue.async { self.sendASAP = true }
    }

    // MARK: - Focus tracking (main thread)

    /// Aim the stream at the frontmost window; fall back to the display with
    /// keyboard focus. No-op when the target hasn't changed.
    private func retarget(force: Bool = false) {
        guard force || stream != nil else { return }

        // Front-to-back z-order comes from the window server; SCShareableContent
        // makes no ordering promise, so the choice is made here and matched there.
        var frontID: UInt32?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier,
           let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            let windows = info.compactMap { d -> (id: UInt32, pid: Int32, layer: Int)? in
                guard let id = d[kCGWindowNumber as String] as? UInt32,
                      let owner = d[kCGWindowOwnerPID as String] as? Int32,
                      let layer = d[kCGWindowLayer as String] as? Int else { return nil }
                return (id, owner, layer)
            }
            frontID = ScreenTargeting.frontWindowID(pid: pid, windows: windows)
        }
        let screenID = (NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()

        // Already aimed correctly — the 2s poll must not thrash the stream.
        if !force {
            if let frontID, frontID == targetWindowID { return }
            if frontID == nil, targetWindowID == 0, screenID == targetDisplayID { return }
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if force { self.onIssue?("Screen capture unavailable: \(error.localizedDescription)") }
                    return
                }
                guard let content else { return }

                if let frontID, let win = content.windows.first(where: { $0.windowID == frontID }) {
                    self.apply(filter: SCContentFilter(desktopIndependentWindow: win),
                               size: ScreenTargeting.outputSize(for: win.frame.size))
                    self.targetWindowID = frontID
                    self.targetDisplayID = 0
                    return
                }
                // Fallback: the display that has keyboard focus (not .first —
                // that pin is exactly what used to hide the second monitor).
                let display = content.displays.first { $0.displayID == screenID }
                    ?? content.displays.first
                guard let display else {
                    if force { self.onIssue?("No display found for screen capture") }
                    return
                }
                self.apply(filter: SCContentFilter(display: display, excludingWindows: []),
                           size: ScreenTargeting.outputSize(for: CGSize(width: display.width,
                                                             height: display.height), scale: 1))
                self.targetWindowID = 0
                self.targetDisplayID = display.displayID
            }
        }
    }

    /// Point the existing stream at a new filter, or start one if this is the
    /// first target. Live retargeting keeps the session's video channel open —
    /// no gap, no renegotiation.
    private func apply(filter: SCContentFilter, size: (width: Int, height: Int)) {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5) // capture 5 FPS
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true

        if let stream {
            stream.updateContentFilter(filter) { [weak self] err in
                if let err { self?.onIssue?("Screen retarget failed: \(err.localizedDescription)") }
            }
            stream.updateConfiguration(config) { _ in }
            return
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stream.startCapture { [weak self] err in
                if let err { self?.onIssue?("Screen capture failed: \(err.localizedDescription)") }
            }
            self.stream = stream
        } catch {
            onIssue?("Screen capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let now = Date()
        guard sendASAP || now.timeIntervalSince(lastSentAt) >= 0.95 else { return }
        sendASAP = false
        lastSentAt = now

        guard let jpeg = Self.jpegData(from: pixelBuffer, context: ciContext) else { return }
        frameLock.lock()
        lastFrame = jpeg
        frameLock.unlock()
        framesSent += 1
        if ProcessInfo.processInfo.environment["KWEKU_LIVE_DEBUG"] != nil, framesSent % 10 == 1 {
            let line = "\(now.timeIntervalSince1970) frame#\(framesSent) jpeg=\(jpeg.count)B\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/kweku_live.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            } else { try? line.write(toFile: "/tmp/kweku_live.log", atomically: true, encoding: .utf8) }
        }
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onIssue?("Screen stream stopped: \(error.localizedDescription)")
    }

    static func jpegData(from pixelBuffer: CVPixelBuffer, context: CIContext, quality: CGFloat = 0.6) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
