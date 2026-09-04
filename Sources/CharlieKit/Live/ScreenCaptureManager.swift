import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Streams the primary display at ~1 FPS, downscaled to 720p and encoded as
/// JPEG, for the Live session's vision channel. First use triggers the macOS
/// Screen Recording consent (grant in System Settings, then relaunch Charlie —
/// standard macOS behaviour).
final class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var onFrame: ((Data) -> Void)?
    private var lastFrameAt = Date.distantPast
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.charlie.screencap")

    func startStreaming(onFrame: @escaping (Data) -> Void) {
        self.onFrame = onFrame
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self, let display = content?.displays.first, error == nil else { return }

            let config = SCStreamConfiguration()
            config.width = 1280
            config.height = 720
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // ~1 FPS
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3
            config.showsCursor = true

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                stream.startCapture { _ in }
                self.stream = stream
            } catch { /* capture unavailable; session continues audio-only */ }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        onFrame = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        // Belt-and-braces throttle on top of minimumFrameInterval.
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= 0.95 else { return }
        lastFrameAt = now

        guard let jpeg = Self.jpegData(from: pixelBuffer, context: ciContext) else { return }
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
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
