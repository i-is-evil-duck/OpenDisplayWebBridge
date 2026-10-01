import CoreFoundation
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder producing OpenDisplay-ready Annex B frames:
/// [optional telemetry JSON prefix] [0001 SPS] [0001 PPS] (keyframe only) [0001 slices]
/// Mirrors the real sender's encode contract (PROTOCOL.md §5): one access unit
/// per frame, parameter sets on every IDR, 4-byte start codes, real-time, no B-frames.
final class VTBox: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var pendingCaptureMs: [Double] = []
    private var forceNextKey = false
    private var reportedErrors: Set<OSStatus> = []

    /// Surfaces encoder failures. `VTCompressionSessionEncodeFrame` can fail
    /// outright (kVTParameterErr when the host has no encoder backend at all,
    /// for instance) and in that case the completion block never runs — so
    /// without this the sender looks perfectly healthy while emitting nothing.
    var onError: ((String) -> Void)?

    init?(width: Int, height: Int, fps: Int = 30, bitrate: Int = 4_000_000) {
        self.width = width
        self.height = height
        var captured: AsyncStream<Data>.Continuation!
        let s = AsyncStream<Data> { captured = $0 }
        self.stream = s
        self.continuation = captured

        let callback: VTCompressionOutputCallback = { refCon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            let box = Unmanaged<VTBox>.fromOpaque(refCon!).takeUnretainedValue()
            box.handleOutput(sampleBuffer)
        }
        var out: VTCompressionSession?
        let err = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &out
        )
        guard err == noErr, let created = out else { return nil }
        self.session = created

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    }

    deinit { if let s = session { VTCompressionSessionInvalidate(s) } }

    func requestKeyframe() {
        lock.lock(); forceNextKey = true; lock.unlock()
    }

    /// Draws one test-pattern frame into a pixel buffer and submits it.
    func encodeTestPattern(frameIndex: Int, captureMs: Double) {
        guard let session else { return }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        if let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: colorSpace, bitmapInfo: bitmapInfo.rawValue) {
            TestPattern.draw(into: ctx, width: width, height: height, frame: frameIndex)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        lock.lock()
        pendingCaptureMs.append(captureMs)
        let props: [String: Any]? = forceNextKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] : nil
        forceNextKey = false
        lock.unlock()

        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
        let rc = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 30), frameProperties: props as CFDictionary?, infoFlagsOut: nil) { [weak self] status, _, _ in
            guard let self else { return }
            if status != noErr {
                self.dropPendingCapture()
            }
        }
        // A rejected frame never reaches the completion block above, so the
        // capture-time entry has to be dropped here or the mapping between
        // submitted frames and emitted output drifts.
        if rc != noErr {
            dropPendingCapture()
            reportError(rc)
        }
    }

    private func dropPendingCapture() {
        lock.lock()
        if !pendingCaptureMs.isEmpty { pendingCaptureMs.removeFirst() }
        lock.unlock()
    }

    /// Report each distinct failure once — at 30 fps an unthrottled log would
    /// bury everything else.
    private func reportError(_ status: OSStatus) {
        lock.lock()
        let firstTime = !reportedErrors.contains(status)
        reportedErrors.insert(status)
        lock.unlock()
        guard firstTime else { return }
        onError?("H.264 encode rejected a frame: OSStatus \(status)")
    }

    private func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let capMs = pendingCaptureMs.isEmpty ? ODControl.nowMs() : pendingCaptureMs.removeFirst()
        lock.unlock()

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length > 0 else { return }
        let avccPayload = Data(bytes: dataPointer, count: length)

        // Keyframe detection from sample attachments (NotSync absent/false => key).
        //
        // This used to reach into the CFArray with a raw `CFArrayGetValueAtIndex`
        // cast to NSDictionary, which the compiler flagged as *always* failing.
        // The cast never succeeded, so `isKey` stayed true for EVERY frame and
        // SPS/PPS were prepended to delta frames too — a straight violation of
        // the §5 contract ("every IDR prefixed with current SPS+PPS") that
        // needlessly bloated the stream. Use the copying accessor so the
        // attachments actually bridge to a Swift dictionary.
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [Any],
           let dict = arr.first as? [String: Any],
           let notSync = dict[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKey = !notSync
        }

        var out = Data()
        if isKey, let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if let sps = parameterSet(fd, index: 0), let pps = parameterSet(fd, index: 1) {
                out.append(AnnexB.startCode); out.append(sps)
                out.append(AnnexB.startCode); out.append(pps)
            }
        }
        out.append(AnnexB.avccToAnnexB(avccPayload))

        // Telemetry prefix (PROTOCOL.md §5.1): cap = capture, snd = send, sender-clock ms.
        let now = ODControl.nowMs()
        let meta = "{\"cap\":\(Int(capMs)),\"snd\":\(Int(now))}"
        var frame = Data(meta.utf8)
        frame.append(out)
        continuation.yield(frame)
    }

    private func parameterSet(_ fd: CMFormatDescription, index: Int) -> Data? {
        var ptr: UnsafePointer<UInt8>?
        var len = 0
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &len, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
              let ptr else { return nil }
        return Data(bytes: ptr, count: len)
    }
}

/// Moving-box test pattern with a frame counter — enough motion to judge latency/stutter.
enum TestPattern {
    static func draw(into ctx: CGContext, width: Int, height: Int, frame: Int) {
        let dark = CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        let accent = CGColor(red: 0.20, green: 0.60, blue: 0.95, alpha: 1)
        ctx.setFillColor(dark)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let box = CGFloat(min(width, height)) / 5
        let t = CGFloat(frame) / 30
        let x = (CGFloat(width) - box) * (0.5 + 0.42 * sin(t * 1.3))
        let y = (CGFloat(height) - box) * (0.5 + 0.42 * cos(t))
        ctx.setFillColor(accent)
        ctx.fill(CGRect(x: x, y: y, width: box, height: box))

        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        TestPattern.drawCounter("OpenDisplay bridge demo — frame \(frame)",
                                into: ctx, at: CGPoint(x: 20, y: 40))
    }

    /// Frame counter. Uses CoreText rather than CGContextShowTextAtPoint, which
    /// is deprecated "No longer supported" (macOS 10.9) and no longer draws.
    static func drawCounter(_ text: String, into ctx: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 0.9),
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
