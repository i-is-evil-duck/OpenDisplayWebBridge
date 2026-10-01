#if canImport(COpenH264)
import COpenH264
import CoreMedia
import CoreVideo
import Foundation

/// Software H.264 decode, via OpenH264.
///
/// ## Why this exists
///
/// The bridge relays, so it holds no pixels. To feed a receiver that cannot
/// decode H.264 itself — an old iPad with neither WebCodecs (iOS 16.4+) nor MSE
/// (iOS 13+) — the bridge has to decode the sender's H.264 and re-encode as VP8
/// for WebRTC.
///
/// `VideoToolboxDecoder` is the right first choice: it is hardware-accelerated
/// and needs no extra dependency. But macOS gates the hardware media path
/// behind a real Developer ID signature, and this process is unsigned.
/// `VTDecompressionSessionDecodeFrame` then returns `noErr`, reports no error,
/// and the output callback simply never fires. The symptom is indistinguishable
/// from a dead stream unless you know to look for it, which is why this backend
/// exists: OpenH264 is not gated, so the path works unsigned.
///
/// Verified on this machine (see WEBRTC_PLAN.md):
///
/// ```
/// signed .app (adhoc)          encoders: NONE   probe: -12902   no output
/// unsigned SwiftPM binary      encoders: NONE   probe: -12902   no output
/// OpenDisplay.app (Dev ID)     encodes fine, decodes fine
/// ```
///
/// ## Cost
///
/// Software decode of a 1080p stream is well within a modern CPU but not free,
/// and it is only used when hardware is unavailable. On a signed build prefer
/// `VideoToolboxDecoder`; see `H264DecoderFactory`.
///
/// Not thread-safe. `H264Transcoder` already serialises all access behind its
/// own lock.
final class OpenH264Decoder {
    /// Handle from `od_h264_create`. `OdH264Decoder` is an incomplete struct
    /// type, so Swift imports the pointer as `OpaquePointer` already — there is
    /// no typed pointer to keep in sync, and no cast that could silently go wrong.
    private let handle: OpaquePointer

    /// Bytes for the previous frame, retained only so a caller that gets no
    /// picture for a few frames can be told so distinctly from a caller that got
    /// a blank one. Not used for output.
    private(set) var version: String = ""

    /// Number of frames produced, for status reporting.
    private(set) var frameCount: Int = 0

    init?() {
        guard let handle = od_h264_create() else { return nil }
        self.handle = handle
        version = String(cString: od_h264_version())
    }

    deinit {
        od_h264_destroy(handle)
    }

    /// True once OpenH264 has reported picture dimensions, which it only does
    /// after decoding a frame that carries an SPS. Until then it cannot allocate
    /// a pixel buffer and callers should expect nil.
    private(set) var hasGeometry = false
    private(set) var width = 0
    private(set) var height = 0

    /// Decodes one Annex-B access unit into a `CVPixelBuffer`.
    ///
    /// Returns nil when the access unit legitimately produced no picture — an
    /// SPS/PPS-only access unit, or a non-reference frame — which is normal and
    /// not an error. The caller distinguishes "nothing yet" from "broken" via
    /// `lastState`.
    func decode(_ annexB: Data) -> CVPixelBuffer? {
        var frame = OdH264Frame()
        // The C struct is zeroed inside od_h264_decode; `od_h264_decode` is
        // documented as taking the buffer by reference and not reading it.
        let rc = annexB.withUnsafeBytes { raw -> Int32 in
            od_h264_decode(handle,
                           raw.bindMemory(to: UInt8.self).baseAddress,
                           Int32(annexB.count), &frame)
        }
        guard rc == 0 else {
            lastState = rc
            return nil
        }
        lastState = frame.state

        guard let y = frame.y, let u = frame.u, let v = frame.v,
              frame.width > 0, frame.height > 0 else { return nil }

        // Track the current geometry rather than pinning it at the first frame.
        // A resolution change mid-stream (PROTOCOL.md 5.2: the sender just
        // starts sending new parameter sets) is normal, and the pixel buffers
        // here are sized per frame, so following the change costs nothing.
        let dims = (width: Int(frame.width), height: Int(frame.height))
        if !hasGeometry || dims.width != width || dims.height != height {
            hasGeometry = true
            width = dims.width
            height = dims.height
        }

        guard let buffer = Self.makePixelBuffer(width: dims.width, height: dims.height)
        else { return nil }

        let ok = CVPixelBufferLockBaseAddress(buffer, [])
        guard ok == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let yDest = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvDest = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yDestStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvDestStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        // OpenH264's output planes are its own and are overwritten by the next
        // decode, so the copy is mandatory rather than an optimisation. Y is a
        // straight row copy; the chroma planes are interleaved into the single
        // UV plane of the bi-planar buffer.
        let yStride = Int(frame.yStride)
        let uvStride = Int(frame.uvStride)
        let chromaWidth = dims.width / 2
        let chromaHeight = dims.height / 2

        for row in 0..<dims.height {
            let from = y.advanced(by: row * yStride)
            let to = yDest.advanced(by: row * yDestStride)
                .assumingMemoryBound(to: UInt8.self)
            memcpy(to, from, dims.width)
        }
        for row in 0..<chromaHeight {
            let to = uvDest.advanced(by: row * uvDestStride)
                .assumingMemoryBound(to: UInt8.self)
            let uFrom = u.advanced(by: row * uvStride)
            let vFrom = v.advanced(by: row * uvStride)
            for col in 0..<chromaWidth {
                to[col * 2] = uFrom[col]
                to[col * 2 + 1] = vFrom[col]
            }
        }

        frameCount += 1
        return buffer
    }

    /// Last OpenH264 `DECODING_STATE` seen. 0 is `dsErrorFree`. The value that
    /// matters in practice is `dsNoParamSets` (0x10): slices arrived with no
    /// SPS/PPS, which is a demuxing or ordering bug, not a codec problem.
    private(set) var lastState: Int32 = 0

    /// Human-readable `lastState`, for the status log.
    var lastStateDescription: String {
        switch lastState {
        case 0x00: return "error-free"
        case 0x01: return "frame pending"
        case 0x02: return "reference lost"
        case 0x04: return "bitstream error"
        case 0x08: return "dependent layer lost"
        case 0x10: return "no parameter sets in the bitstream"
        case 0x20: return "error concealed"
        case 0x40: return "null reference list pointers"
        default: return "state 0x\(String(lastState, radix: 16))"
        }
    }

    /// Discards decoder state, forcing the next access unit to be a keyframe.
    ///
    /// Needed when the stream geometry changes (PROTOCOL.md 5.2: the sender
    /// simply starts sending new parameter sets) or after a gap long enough
    /// that the reference chain is unusable.
    ///
    /// The handle survives: this resets the decoder, it does not destroy it.
    /// `handle` is a `let`, so freeing it here would leave a dangling pointer
    /// that the next `decode` dereferences and `deinit` frees a second time —
    /// a use-after-free followed by a double free, which crashed the process
    /// with `EXC_BAD_ACCESS` in `od_h264_destroy` on every receiver disconnect
    /// once the software fallback was active. Callers that genuinely want the
    /// decoder gone should drop the object and let `deinit` do it once.
    ///
    /// Idempotent, and the decoder is usable again immediately afterwards.
    @discardableResult
    func reset() -> Bool {
        let ok = od_h264_reset(handle) == 0
        hasGeometry = false
        width = 0
        height = 0
        lastState = 0
        return ok
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var buffer: CVPixelBuffer?
        // Bi-planar full-range rather than planar: NV12 is what libwebrtc's
        // software VP8 encoder consumes natively, so no conversion happens
        // downstream. Full-range because screen pixels are 0-255, not the
        // studio 16-235.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(format),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            // IOSurface-backed buffers can be handed to the encoder without a
            // further copy.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        // Colour metadata is an *attachment*, not a creation attribute:
        // CVPixelBufferCreate silently ignores it in the attribute dictionary.
        // The encoder set full-range BT.709, so say so here, or the browser
        // applies a second conversion and the picture looks washed out.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
#endif
