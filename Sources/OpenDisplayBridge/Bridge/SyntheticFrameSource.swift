import CoreGraphics
import CoreVideo
import Foundation

/// A generated frame source for the WebRTC spike (WEBRTC_PLAN.md W0.3).
///
/// The whole point of W0.3 is to prove that a decoded `CVPixelBuffer` reaches a
/// browser, so the pixels must not depend on a working H.264 *encoder* — this
/// host's hardware path is unreachable from an unsigned binary. Drawing directly
/// into a `CVPixelBuffer` sidesteps encoding entirely; libvpx does the VP8
/// encode inside WebRTC.
final class SyntheticFrameSource {
    private let width: Int
    private let height: Int
    private var frameIndex = 0
    private var nextFrameTime = CFAbsoluteTimeGetCurrent()

    /// Target rate. VP8 is a software encoder, so start conservative and measure
    /// before raising this.
    var fps: Double = 15

    init(width: Int = 480, height: Int = 270) {
        self.width = width
        self.height = height
    }

    /// Returns nil when it is not yet time for the next frame, so the caller can
    /// stay in a tight receive loop without pacing by hand.
    func nextFrame(force: Bool = false) -> (CVPixelBuffer, Int64)? {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now < nextFrameTime { return nil }
        nextFrameTime = now + (1.0 / fps)

        guard let buffer = makeBuffer() else { return nil }
        draw(into: buffer, index: frameIndex)
        frameIndex += 1
        // Monotonic nanoseconds; nothing on the wire carries a PTS.
        return (buffer, Int64(now * 1_000_000_000))
    }

    private func makeBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    /// A frame counter plus a moving box. The counter is what makes the browser
    /// assertion meaningful: a still image would pass a naive "did we get a
    /// frame" check even if nothing were actually advancing.
    private func draw(into buffer: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                 | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: space, bitmapInfo: info.rawValue) else { return }

        ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let box = CGFloat(min(width, height)) / 4
        let t = CGFloat(index) / 15
        let x = (CGFloat(width) - box) * (0.5 + 0.4 * sin(t * 1.7))
        let y = (CGFloat(height) - box) * (0.5 + 0.4 * cos(t * 1.1))
        ctx.setFillColor(CGColor(red: 0.20, green: 0.65, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: box, height: box))

        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        TestPattern.drawCounter("WebRTC W0.3 — frame \(index)",
                                into: ctx, at: CGPoint(x: 12, y: 26))
    }
}
