#if canImport(COpenH264)
import COpenH264
import Foundation

/// Encodes I420 frames to Annex-B H.264 with OpenH264.
///
/// Exists so tests and the synthetic demo mode have a real H.264 stream to work
/// with. Nothing else on this Mac can produce one: VideoToolbox encode returns
/// `kVTParameterErr` for an unsigned process, and there is no ffmpeg installed.
/// OpenH264 is already linked for decoding, and its encoder is in the same
/// dylib, so this costs a dozen lines rather than a new dependency.
///
/// See `OpenH264Decoder` for why the software codec is in the picture at all.
final class OpenH264Encoder {
    private let handle: OpaquePointer
    let width: Int
    let height: Int

    /// One I420 frame plus start-code and emulation-prevention headroom.
    private let maxBytes: Int

    init?(width: Int, height: Int, fps: Int = 30, bitrate: Int = 1_500_000) {
        guard let handle = od_h264_encoder_create(Int32(width), Int32(height),
                                                  Int32(fps), Int32(bitrate))
        else { return nil }
        self.handle = handle
        self.width = width
        self.height = height
        self.maxBytes = Int(od_h264_encoder_max_bytes(Int32(width), Int32(height)))
    }

    deinit {
        od_h264_encoder_destroy(handle)
    }

    /// Reusable output buffer, so encoding a stream does not allocate per frame.
    private var scratch: [UInt8] = []

    /// Encodes one I420 frame into a complete Annex-B access unit.
    ///
    /// - Returns: the access unit, or nil if the encoder emitted nothing (legal
    ///   under rate control, though `bEnableFrameSkip` is off so it should not
    ///   happen here).
    func encode(y: [UInt8], yStride: Int,
                u: [UInt8], v: [UInt8], chromaStride: Int) -> Data? {
        if scratch.count != maxBytes {
            scratch = [UInt8](repeating: 0, count: maxBytes)
        }

        var isKeyframe: Int32 = 0
        let written: Int32 = y.withUnsafeBufferPointer { yPtr in
            u.withUnsafeBufferPointer { uPtr in
                v.withUnsafeBufferPointer { vPtr in
                    scratch.withUnsafeMutableBufferPointer { out in
                        od_h264_encoder_encode(
                            handle,
                            yPtr.baseAddress, Int32(yStride),
                            uPtr.baseAddress, Int32(chromaStride),
                            vPtr.baseAddress, Int32(chromaStride),
                            Int32(width), Int32(height),
                            out.baseAddress, Int32(maxBytes),
                            &isKeyframe)
                    }
                }
            }
        }
        guard written > 0 else { return nil }
        return Data(scratch[0..<Int(written)])
    }

    /// Forces the next encoded frame to be an IDR.
    func forceKeyframe() {
        od_h264_encoder_force_keyframe(handle)
    }
}
#endif
