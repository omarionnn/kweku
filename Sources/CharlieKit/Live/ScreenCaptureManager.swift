import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Streams the primary display for the Live session's vision channel.
/// Captures internally at 5 FPS but *sends* at 1 FPS — so `noteUserTurn()`
/// can push a fresh frame within ~200ms when it's the user's turn to ask
/// ("read my screen" always sees the current screen, not a second-old one).
/// Frames are 720p JPEG to keep token usage down.
final class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var onFrame: ((Data) -> Void)?
    private var lastSentAt = Date.distantPast
    private var sendASAP = false
    private var framesSent = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.charlie.screencap")

    /// Surfaced problems (missing permission, stream death) for the UI/status.
    var onIssue: ((String) -> Void)?

    func startStreaming(onFrame: @escaping (Data) -> Void) {
        self.onFrame = onFrame

        // Explicit, surfaced permission check instead of silent no-frames.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onIssue?("Screen Recording not granted — enable Charlie in System Settings › Privacy › Screen Recording, then relaunch. Session continues audio-only.")
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.onIssue?("Screen capture unavailable: \(error.localizedDescription)")
                return
            }
            guard let display = content?.displays.first else {
                self.onIssue?("No display found for screen capture")
                return
            }

            let config = SCStreamConfiguration()
            config.width = 1280
            config.height = 720
            config.minimumFrameInterval = CMTime(value: 1, timescale: 5) // capture 5 FPS
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3
            config.showsCursor = true

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                stream.startCapture { [weak self] err in
                    if let err { self?.onIssue?("Screen capture failed: \(err.localizedDescription)") }
                }
                self.stream = stream
            } catch {
                self.onIssue?("Screen capture failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        onFrame = nil
    }

    /// The user is about to speak/ask — push the next captured frame
    /// immediately so the model sees the *current* screen.
    func noteUserTurn() {
        queue.async { self.sendASAP = true }
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
        framesSent += 1
        if ProcessInfo.processInfo.environment["CHARLIE_LIVE_DEBUG"] != nil, framesSent % 10 == 1 {
            let line = "\(now.timeIntervalSince1970) frame#\(framesSent) jpeg=\(jpeg.count)B\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/charlie_live.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            } else { try? line.write(toFile: "/tmp/charlie_live.log", atomically: true, encoding: .utf8) }
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
