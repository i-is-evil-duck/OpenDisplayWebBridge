import Foundation
import VideoToolbox
import CoreMedia

/// Reports what the host can actually encode, so "no video" is never a
/// mystery again.
///
/// This exists because a bare `swiftc` test binary reported ZERO H.264 encoders
/// on Apple Silicon, which is not credible — M-series Macs all have hardware
/// H.264 encode. A non-bundled binary appears to enumerate differently from a
/// real app, so the app reports for itself instead of trusting a probe run
/// outside its own context.
enum EncoderReport {

    struct Info {
        var encoders: [String]
        var hardwareH264: Bool
        var reason: String?
    }

    static func collect() -> Info {
        var encoders: [String] = []
        var list: CFArray?
        let status = VTCopyVideoEncoderList(nil, &list)
        if status == noErr { encoders = (list as? [String]) ?? [] }

        return Info(encoders: encoders.sorted(),
                    hardwareH264: encoders.contains { $0.lowercased().contains("h264") },
                    reason: status == noErr ? nil : "VTCopyVideoEncoderList -> \(status)")
    }

    /// One-line summary for the app log.
    static func summary() -> String {
        let i = collect()
        if i.encoders.isEmpty {
            return "encoders: NONE reported (VT status \(i.reason ?? "ok, empty"))"
                + " — a bare non-bundled binary enumerates differently; ignore if"
                + " a real session encodes fine"
        }
        return "encoders: \(i.encoders.joined(separator: ", "))"
            + (i.hardwareH264 ? " [H.264 yes]" : " [H.264 NO]")
    }

    /// Probe: actually submit one frame and report the status. Enumeration can
    /// claim support that EncodeFrame then refuses.
    static func probeEncode(width: Int = 320, height: Int = 240) -> String {
        var callback: VTCompressionOutputCallback = { _, _, _, _, _ in }
        var session: VTCompressionSession?
        let create = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: callback, refcon: nil,
            compressionSessionOut: &session)
        guard create == noErr, let s = session else {
            return "probe: create failed \(create)"
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return "probe: no pixel buffer" }
        let rc = VTCompressionSessionEncodeFrame(
            s, imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
        VTCompressionSessionInvalidate(s)
        return "probe: EncodeFrame -> \(rc) (\(rc == noErr ? "OK" : "failed"))"
    }
}
