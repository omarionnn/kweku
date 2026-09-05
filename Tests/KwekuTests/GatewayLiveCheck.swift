import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KwekuKit

/// Opt-in end-to-end check against a real gateway. Skipped by default so
/// `make test` stays offline and deterministic:
///
///     KWEKU_LIVE_GATEWAY=1 swift run KwekuTests
///
/// Uses a scratch session key so it never writes into the real conversation.
enum GatewayLiveCheck {

    static let sessionKey = "agent:main:kweku-livecheck"

    static func run() {
        guard ProcessInfo.processInfo.environment["KWEKU_LIVE_GATEWAY"] != nil else {
            print("- live gateway: skipped (set KWEKU_LIVE_GATEWAY=1 to run)")
            return
        }
        guard GatewayCredentials.token() != nil else {
            Check.ok(false, "no gateway token found — is OpenClaw configured?")
            return
        }

        let client = GatewayClient(sessionKey: sessionKey)
        var sawProgress = false
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<String, GatewayError>?

        client.start()
        client.dispatch(
            "Reply with exactly: pong",
            timeout: 120,
            onProgress: { _ in sawProgress = true },
            onTerminal: { result in outcome = result; done.signal() })

        // The test runner is synchronous; callbacks land on the main queue, so
        // pump the runloop rather than blocking it outright.
        let deadline = Date().addingTimeInterval(120)
        while done.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        client.stop()

        switch outcome {
        case .success(let text):
            Check.ok(text.lowercased().contains("pong"), "round-trip answer (got: \(text.prefix(80)))")
            Check.ok(sawProgress, "streamed progress before the final answer")
        case .failure(let error):
            Check.ok(false, "dispatch failed: \(error.spoken)")
        case nil:
            Check.ok(false, "timed out with no terminal event")
        }

        vision()
    }

    /// Proves the screenshot actually reaches the model's eyes. Schema
    /// acceptance is not proof: the gateway drops attachments whose `content`
    /// is missing without raising an error, so the only real test is asking
    /// the agent to describe an image it could not otherwise guess.
    private static func vision() {
        guard let jpeg = quadrantJPEG() else {
            Check.ok(false, "could not build the test image")
            return
        }

        let client = GatewayClient(sessionKey: "agent:main:kweku-visioncheck")
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<String, GatewayError>?

        client.start()
        client.dispatch(
            "Look at the attached image. It is split into four quadrants. Name the colour of "
            + "each: top-left, top-right, bottom-left, bottom-right. Reply with exactly four "
            + "words separated by commas. If you cannot see an image, reply exactly: NO IMAGE",
            screenshot: jpeg,
            timeout: 120,
            onProgress: { _ in },
            onTerminal: { result in outcome = result; done.signal() })

        let deadline = Date().addingTimeInterval(120)
        while done.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        client.stop()

        guard case .success(let answer)? = outcome else {
            Check.ok(false, "vision dispatch produced no answer")
            return
        }
        let lower = answer.lowercased()
        Check.ok(!lower.contains("no image"), "the model received an image (got: \(answer.prefix(60)))")
        for colour in ["red", "green", "blue", "yellow"] {
            Check.ok(lower.contains(colour), "saw \(colour) (got: \(answer.prefix(60)))")
        }
    }

    /// 64×64 JPEG: red, green, blue, yellow quadrants — an arrangement the
    /// model cannot guess without actually seeing it.
    private static func quadrantJPEG() -> Data? {
        let side = 64, half = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // CoreGraphics origin is bottom-left, so the y values are flipped
        // relative to how the prompt describes top and bottom.
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: half, width: half, height: half), CGColor(red: 0.86, green: 0.08, blue: 0.08, alpha: 1)),
            (CGRect(x: half, y: half, width: half, height: half), CGColor(red: 0.08, green: 0.78, blue: 0.08, alpha: 1)),
            (CGRect(x: 0, y: 0, width: half, height: half), CGColor(red: 0.08, green: 0.08, blue: 0.86, alpha: 1)),
            (CGRect(x: half, y: 0, width: half, height: half), CGColor(red: 0.94, green: 0.86, blue: 0.08, alpha: 1)),
        ]
        for (rect, colour) in quadrants {
            ctx.setFillColor(colour)
            ctx.fill(rect)
        }

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
