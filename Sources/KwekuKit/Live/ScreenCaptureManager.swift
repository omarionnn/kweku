import AppKit
import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Pure targeting maths for the screen stream (unit-tested).
public enum ScreenTargeting {
    /// One on-screen window as the compositor reports it, front-to-back.
    public struct WindowInfo: Equatable {
        public var id: UInt32
        public var pid: Int32
        public var layer: Int
        public var width: CGFloat
        public var height: CGFloat
        public var alpha: CGFloat
        /// Owner has `.regular` activation policy — a real app the user can
        /// be "in", as opposed to accessory HUDs, gateways, and overlays.
        public var regularApp: Bool

        public init(id: UInt32, pid: Int32, layer: Int,
                    width: CGFloat, height: CGFloat, alpha: CGFloat = 1,
                    regularApp: Bool) {
            self.id = id; self.pid = pid; self.layer = layer
            self.width = width; self.height = height; self.alpha = alpha
            self.regularApp = regularApp
        }
    }

    /// The window the user is actually in.
    ///
    /// Two field failures shape this. `NSWorkspace.frontmostApplication` +
    /// "its first window" aimed at an accessory HUD's 1470×66 strip; and a
    /// bare z-order scan still lost to *phantom* windows — real apps keep
    /// nameless full-width strips (Terminal: 1470×68, alpha 1) and invisible
    /// helpers (66×20, alpha 0) at layer 0 ahead of their actual windows.
    ///
    /// So: qualify hard (layer 0, visible, regular app, big enough to be a
    /// working window), then prefer the frontmost app's topmost qualifying
    /// window, else the topmost qualifying window overall — the compositor's
    /// z-order settles what "in front" means.
    public static func focusedWindowID(windows: [WindowInfo],
                                       frontmostPid: Int32? = nil,
                                       excludingPid: Int32,
                                       minWidth: CGFloat = 200,
                                       minHeight: CGFloat = 150) -> UInt32? {
        let qualified = windows.filter {
            $0.layer == 0 && $0.pid != excludingPid && $0.regularApp && $0.alpha > 0
                && $0.width >= minWidth && $0.height >= minHeight
        }
        if let frontmostPid, let own = qualified.first(where: { $0.pid == frontmostPid }) {
            return own.id
        }
        return qualified.first?.id
    }

    /// What to do with one buffer the compositor just handed us.
    public enum FrameAction: Equatable {
        case send           // carries new pixels: encode, cache, transmit
        case resendCached   // nothing moved, but the model is owed a frame
        case skip
    }

    /// ScreenCaptureKit only generates pixels when the content *changes* —
    /// `SCFrameStatusIdle` is documented as "new frame was not generated
    /// because the display did not change". A still window therefore starves
    /// the vision channel completely, and the model goes on answering from the
    /// last window that happened to be moving. That is the whole "you're on
    /// oh-my-pi" bug: an agent terminal repaints constantly and so keeps
    /// feeding frames, while a paused Spotify window feeds none, so the model
    /// never stops looking at the terminal.
    ///
    /// So a still screen re-sends its last good frame on the normal cadence.
    /// The cache may only be re-sent while it still belongs to the window the
    /// stream is aimed at *now* (`cacheMatchesTarget`) — re-sending across a
    /// retarget would restage the previous window's pixels as the current
    /// screen, which is the same lie in the other direction.
    public static func frameAction(hasNewPixels: Bool,
                                   cacheMatchesTarget: Bool,
                                   sendASAP: Bool,
                                   sinceLastSend: TimeInterval,
                                   interval: TimeInterval = 0.95) -> FrameAction {
        guard sendASAP || sinceLastSend >= interval else { return .skip }
        if hasNewPixels { return .send }
        return cacheMatchesTarget ? .resendCached : .skip
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
    private var heartbeat: DispatchSourceTimer?

    /// A session is open and wants frames. Distinct from `stream != nil`: the
    /// first aim can fail (a transient `SCShareableContent` error), and gating
    /// the poll on the stream instead would strand the session with no vision
    /// for its whole life and only a one-line status to say so.
    private var streaming = false

    /// Surfaced problems (missing permission, stream death) for the UI/status.
    var onIssue: ((String) -> Void)?

    /// Most recent frame sent upstream, kept so a dispatched OpenClaw task can
    /// carry the actual screen rather than a description of it, and so a still
    /// screen still has something to send. Written on `queue` and from the
    /// seed grab, read from main.
    ///
    /// `generation` is a monotonic id for the current aim, bumped on every
    /// retarget. A cached frame carries the generation it was captured under,
    /// so pixels can never outlive the window they came from.
    private let frameLock = NSLock()
    private var lastFrame: Data?
    private var lastFrameGeneration: UInt64 = 0
    private var generation: UInt64 = 0

    /// Set when the current aim is a window that must not leave the machine.
    /// Keyed by generation so a stale verdict can never outlive its window.
    private var redaction: (generation: UInt64, reason: String)?

    /// What is in front right now, for the timeline and the triage trigger.
    private var currentApp = ""
    private var currentTitle = ""

    /// Told about every aim change: app, window title, whether it's redacted.
    var onAim: ((String, String, Bool) -> Void)?

    /// Told about every frame that goes out, so the screen timeline can decide
    /// whether this instant is worth remembering. Called on `queue`.
    var onMoment: ((_ app: String, _ title: String, _ jpeg: Data?, _ redacted: Bool) -> Void)?

    /// The current screen as JPEG, at most ~1s old. Nil before the first frame
    /// or when screen capture isn't permitted.
    func latestFrame() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return lastFrame
    }

    private var currentGeneration: UInt64 {
        frameLock.lock(); defer { frameLock.unlock() }
        return generation
    }

    /// Open a new aim. The cache is *not* cleared — it stays readable for an
    /// OpenClaw dispatch — but its generation no longer matches, so no idle
    /// frame can re-send it as if it were the new window.
    private func beginTarget(app: String = "", title: String = "",
                             redactedAs reason: String? = nil) -> UInt64 {
        frameLock.lock(); defer { frameLock.unlock() }
        generation &+= 1
        currentApp = app
        currentTitle = title
        redaction = reason.map { (generation, $0) }
        return generation
    }

    /// Why this generation is being withheld, if it is.
    private func redactionReason(for gen: UInt64) -> String? {
        frameLock.lock(); defer { frameLock.unlock() }
        return redaction?.generation == gen ? redaction?.reason : nil
    }

    private var currentWindow: (app: String, title: String) {
        frameLock.lock(); defer { frameLock.unlock() }
        return (currentApp, currentTitle)
    }

    private func cache(_ jpeg: Data, generation gen: UInt64) {
        frameLock.lock()
        lastFrame = jpeg
        lastFrameGeneration = gen
        frameLock.unlock()
    }

    private func cachedFrame(for gen: UInt64) -> Data? {
        frameLock.lock(); defer { frameLock.unlock() }
        return lastFrameGeneration == gen ? lastFrame : nil
    }


    // MARK: - Lifecycle

    /// Whether this process may capture the screen *right now*, asked without
    /// prompting. Checked before the Live socket opens, because whether Kweku
    /// can see decides what its system instruction is allowed to claim.
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// `SCStreamErrorUserDeclined`. The enum isn't surfaced to Swift, so the
    /// raw value from `SCError.h` stands in for it.
    static let userDeclined = -3801

    /// Why vision is off, in the words the model and the UI both get.
    static let permissionIssue =
        "Screen Recording not granted — enable Kweku in System Settings › Privacy › "
        + "Screen Recording, then relaunch. Session continues audio-only."

    func startStreaming(onFrame: @escaping (Data) -> Void) {
        self.onFrame = onFrame

        // Deliberately *not* gated on `CGPreflightScreenCaptureAccess()`.
        // That call answers for the legacy CoreGraphics capture path, and on
        // this machine it returns false for apps that hold a live "Screen &
        // System Audio Recording" grant — Kweku included, with its toggle
        // plainly on. Refusing to start on that answer is a self-inflicted
        // blindness that looks exactly like a revoked permission.
        //
        // ScreenCaptureKit is the thing we actually use, so let it answer:
        // `SCShareableContent` fails with a permission error when the grant
        // really is missing, and that error is what surfaces to the user.
        Self.dbg("preflight(legacy CG)=\(Self.hasScreenAccess) — advisory only")
        streaming = true
        retarget(force: true)

        // Focus moves two ways: another app activates (notification), or the
        // user switches windows within the app (nothing fires — poll gently).
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.retarget() }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.retarget() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        startHeartbeat()
    }

    /// Guarantees the model a frame every second, whatever the compositor does.
    ///
    /// A still window may deliver `.idle` buffers, or it may deliver nothing at
    /// all — the two are indistinguishable from outside, and only one of them
    /// gives the sample-buffer path a chance to react. Hanging the fix on that
    /// distinction is how the channel went quiet in the first place, so the
    /// cadence is driven from here instead and the buffer path is just the
    /// cheap route when frames happen to be arriving.
    private func startHeartbeat() {
        let beat = DispatchSource.makeTimerSource(queue: queue)
        beat.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        beat.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastSentAt) >= 0.95,
                  let jpeg = self.cachedFrame(for: self.currentGeneration)
            else { return }
            self.lastSentAt = now
            self.sendASAP = false
            self.framesSent += 1
            if Self.debug {
                Self.dbg("frame#\(self.framesSent) resend(heartbeat) jpeg=\(jpeg.count)B")
            }
            self.onFrame?(jpeg)
            self.noteMoment(jpeg)
        }
        beat.resume()
        heartbeat = beat
    }

    func stop() {
        streaming = false
        stream?.stopCapture { _ in }
        stream = nil
        onFrame = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        heartbeat?.cancel()
        heartbeat = nil
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


    // MARK: - Debug (env-gated; same switch as the frame log)

    static let debug = ProcessInfo.processInfo.environment["KWEKU_LIVE_DEBUG"] != nil
        || UserDefaults.standard.bool(forKey: "liveDebug")

    static func dbg(_ s: String) {
        guard debug else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/kweku_live.log") {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else { try? line.write(toFile: "/tmp/kweku_live.log", atomically: true, encoding: .utf8) }
    }
    // MARK: - Focus tracking (main thread)

    /// Aim the stream at the frontmost window; fall back to the display with
    /// keyboard focus. No-op when the target hasn't changed.
    private func retarget(force: Bool = false) {
        guard force || streaming else { return }

        // Front-to-back z-order comes from the window server; SCShareableContent
        // makes no ordering promise, so the choice is made here and matched there.
        var frontID: UInt32?
        if let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
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
            frontID = ScreenTargeting.focusedWindowID(
                windows: windows,
                frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                excludingPid: ProcessInfo.processInfo.processIdentifier)
        }
        Self.dbg("retarget force=\(force) frontID=\(frontID.map(String.init) ?? "nil") current=\(targetWindowID)/\(targetDisplayID)")
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
                    // ScreenCaptureKit is the authority on its own permission:
                    // a declined grant comes back as `SCStreamErrorUserDeclined`
                    // here, and only then is it worth sending the user to
                    // System Settings (or raising the system prompt).
                    let ns = error as NSError
                    let declined = ns.code == Self.userDeclined
                    Self.dbg("shareable content error domain=\(ns.domain) code=\(ns.code) "
                             + "declined=\(declined)")
                    if declined {
                        CGRequestScreenCaptureAccess()
                        self.onIssue?(Self.permissionIssue)
                    } else if force {
                        self.onIssue?("Screen capture unavailable: \(error.localizedDescription)")
                    }
                    return
                }
                guard let content else { return }

                if let frontID, let win = content.windows.first(where: { $0.windowID == frontID }) {
                    let app = win.owningApplication?.applicationName ?? ""
                    let title = win.title ?? ""
                    // Decided here, before a filter exists, so a denied window
                    // never reaches the encoder at all.
                    let verdict = ScreenRedaction.verdict(
                        for: .init(app: app, title: title),
                        extraTerms: ScreenRedaction.userTerms,
                        enabled: ScreenRedaction.enabled)
                    Self.dbg("aim window id=\(frontID) '\(title)' app='\(app)' "
                             + "\(Int(win.frame.width))x\(Int(win.frame.height)) "
                             + "redacted=\(verdict.isRedacted)")
                    self.apply(filter: SCContentFilter(desktopIndependentWindow: win),
                               size: ScreenTargeting.outputSize(for: win.frame.size),
                               app: app, title: title, redactedAs: verdict.reason)
                    self.targetWindowID = frontID
                    self.targetDisplayID = 0
                    if let reason = verdict.reason {
                        self.onIssue?("Screen hidden from Kweku — \(reason).")
                    }
                    self.onAim?(app, title, verdict.isRedacted)
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
                Self.dbg("aim display id=\(display.displayID)")
                self.apply(filter: SCContentFilter(display: display, excludingWindows: []),
                           size: ScreenTargeting.outputSize(for: CGSize(width: display.width,
                                                             height: display.height), scale: 1),
                           app: "Desktop", title: "whole display")
                self.targetWindowID = 0
                self.targetDisplayID = display.displayID
                self.onAim?("Desktop", "whole display", false)
            }
        }
    }

    /// Point the existing stream at a new filter, or start one if this is the
    /// first target. Live retargeting keeps the session's video channel open —
    /// no gap, no renegotiation.
    private func apply(filter: SCContentFilter, size: (width: Int, height: Int),
                       app: String = "", title: String = "", redactedAs reason: String? = nil) {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5) // capture 5 FPS
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true

        // New aim: cached pixels from the old window stop counting as "now",
        // and the next real frame goes out without waiting for the cadence.
        let gen = beginTarget(app: app, title: title, redactedAs: reason)
        queue.async { self.sendASAP = true }

        // A withheld window still gets a frame every second — a placeholder
        // card saying so. Going silent instead would be indistinguishable from
        // the channel dying, which is the failure this whole path exists to
        // prevent, and would leave the model narrating the window before it.
        if reason != nil {
            cache(Self.redactedFrame(), generation: gen)
        }

        if let stream {
            stream.updateContentFilter(filter) { [weak self] err in
                Self.dbg("updateContentFilter -> \(err.map { "\($0)" } ?? "ok")")
                if let err { self?.onIssue?("Screen retarget failed: \(err.localizedDescription)") }
            }
            stream.updateConfiguration(config) { err in
                Self.dbg("updateConfiguration -> \(err.map { "\($0)" } ?? "ok")")
            }
            seedFrame(filter: filter, config: config, generation: gen)
            return
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stream.startCapture { [weak self] err in
                if let err { self?.onIssue?("Screen capture failed: \(err.localizedDescription)") }
            }
            self.stream = stream
            seedFrame(filter: filter, config: config, generation: gen)
        } catch {
            onIssue?("Screen capture failed: \(error.localizedDescription)")
        }
    }

    /// One guaranteed grab of a freshly aimed target.
    ///
    /// The stream itself only emits pixels on change, so switching to a window
    /// that is sitting still can deliver nothing at all — leaving the model on
    /// the window it was watching before. `SCScreenshotManager` renders on
    /// demand, so the switch is visible to the model immediately rather than
    /// whenever the new window next happens to repaint.
    private func seedFrame(filter: SCContentFilter, config: SCStreamConfiguration,
                           generation gen: UInt64) {
        guard #available(macOS 14.0, *) else { return }
        // Withheld window: the placeholder is already cached and the heartbeat
        // will carry it. Rendering the real thing "just for the seed" would
        // defeat the entire point of the verdict.
        guard redactionReason(for: gen) == nil else { return }
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) {
            [weak self] buffer, error in
            guard let self, error == nil, let buffer, buffer.isValid,
                  let pixels = CMSampleBufferGetImageBuffer(buffer),
                  let jpeg = Self.jpegData(from: pixels, context: self.ciContext)
            else { return }
            self.queue.async {
                // A newer aim may have landed while this grab was in flight.
                guard self.currentGeneration == gen else { return }
                self.cache(jpeg, generation: gen)
                self.sendASAP = false
                self.lastSentAt = Date()
                Self.dbg("seed gen=\(gen) jpeg=\(jpeg.count)B")
                self.onFrame?(jpeg)
                self.noteMoment(jpeg)
            }
        }
    }

    // MARK: - SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Buffers keep arriving while the screen sits still, but only a
        // `.complete`/`.started` one carries pixels; the rest say "nothing
        // changed". Treat an unreadable status as fresh and let the image
        // buffer decide, so an OS change can't silently mute the channel.
        let now = Date()
        let gen = currentGeneration

        // Withheld window: drop the buffer without ever reading its pixels.
        // The heartbeat keeps the cadence alive with the placeholder card.
        guard redactionReason(for: gen) == nil else { return }

        let status = Self.frameStatus(of: sampleBuffer)
        let maybeFresh = status == nil || status == .complete || status == .started
        let pixelBuffer = maybeFresh ? CMSampleBufferGetImageBuffer(sampleBuffer) : nil
        let action = ScreenTargeting.frameAction(
            hasNewPixels: pixelBuffer != nil,
            cacheMatchesTarget: cachedFrame(for: gen) != nil,
            sendASAP: sendASAP,
            sinceLastSend: now.timeIntervalSince(lastSentAt))

        let jpeg: Data?
        switch action {
        case .skip:
            return
        case .send:
            jpeg = pixelBuffer.flatMap { Self.jpegData(from: $0, context: ciContext) }
            if let jpeg { cache(jpeg, generation: gen) }
        case .resendCached:
            jpeg = cachedFrame(for: gen)
        }
        guard let jpeg else { return }

        sendASAP = false
        lastSentAt = now
        framesSent += 1
        if Self.debug {
            try? jpeg.write(to: URL(fileURLWithPath: "/tmp/kweku_frame.jpg"))
            // Log every frame with its provenance: a run of `resend` is the
            // vision channel staying alive on a motionless screen, which is
            // precisely what used to fail silently.
            Self.dbg("frame#\(framesSent) \(action == .send ? "fresh" : "resend") "
                     + "gen=\(gen) status=\(status.map { "\($0.rawValue)" } ?? "?") "
                     + "jpeg=\(jpeg.count)B")
        }
        onFrame?(jpeg)
        noteMoment(jpeg)
    }

    /// Offer this instant to the screen timeline. The store decides whether it
    /// is worth keeping — this path runs once a second and must stay cheap.
    private func noteMoment(_ jpeg: Data?) {
        guard let onMoment else { return }
        let window = currentWindow
        onMoment(window.app, window.title, jpeg, redactionReason(for: currentGeneration) != nil)
    }

    /// The card sent in place of a window that must not leave the machine.
    ///
    /// It says what it is, so the model can tell Omari "that one's private"
    /// rather than reporting a black screen or, worse, describing whatever it
    /// last saw.
    static func redactedFrame() -> Data {
        if let cached = cachedRedactedFrame { return cached }
        let size = NSSize(width: 960, height: 540)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = "Screen hidden\n\nThis window is private and is not being shared.\n"
            + "Tell Omari you cannot see this one."
        text.draw(in: NSRect(x: 60, y: 180, width: size.width - 120, height: 220),
                  withAttributes: [
                    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
                    .paragraphStyle: style,
                  ])
        image.unlockFocus()
        let data = image.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) }
            ?? Data()
        cachedRedactedFrame = data
        return data
    }

    private static var cachedRedactedFrame: Data?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onIssue?("Screen stream stopped: \(error.localizedDescription)")
    }

    /// The compositor's verdict on this buffer, from the sample attachments.
    /// Nil when the attachment is missing or unrecognised.
    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
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
