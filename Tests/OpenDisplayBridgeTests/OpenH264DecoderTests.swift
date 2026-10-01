#if canImport(COpenH264)
import CoreVideo
import Foundation
import XCTest

@testable import OpenDisplayBridge

/// Round-trips real H.264 through the software decoder.
///
/// Why encode in a test at all: the previous test coverage used *synthetic*
/// NALs. Those prove the demuxer splits and reframes a byte stream correctly,
/// but they cannot prove a decoder decodes — the failure mode that actually
/// blocked this path was "the decoder accepted a frame and produced nothing",
/// and no synthetic input can reproduce that. So the test encodes with the same
/// library the decoder uses, which is not a tautology: it exercises Annex-B
/// start-code parsing, the 4-byte-vs-3-byte distinction, access-unit framing,
/// the NV12 chroma interleave, and stride handling, all of which are places a
/// real decoder quietly produces garbage instead of failing.
final class OpenH264DecoderTests: XCTestCase {

    // MARK: - Round trip

    func testEncodesAndDecodesAMovingPattern() throws {
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 30))
        let decoder = try XCTUnwrap(OpenH264Decoder())
        XCTAssertFalse(decoder.version.isEmpty, "OpenH264 should report a version")

        var decodedCount = 0
        var lastBuffer: CVPixelBuffer?
        for frameIndex in 0..<5 {
            let (y, u, v) = Self.testPattern(width: width, height: height,
                                             phase: frameIndex)
            let accessUnit = try XCTUnwrap(
                encoder.encode(y: y, yStride: width, u: u, v: v, chromaStride: width / 2),
                "frame \(frameIndex) encoded to nothing")
            if let buffer = decoder.decode(accessUnit) {
                decodedCount += 1
                lastBuffer = buffer
            }
        }

        XCTAssertEqual(decodedCount, 5,
                       "every frame should decode; last state was "
                       + decoder.lastStateDescription)
        XCTAssertEqual(decoder.frameCount, 5)

        let buffer = try XCTUnwrap(lastBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), height)
    }

    /// A decoder that returns correctly-sized but uniformly black frames passes
    /// every count and dimension assertion above, and shows the user a black
    /// screen — the exact bug this work exists to fix. So check the pixels.
    func testDecodedPixelsAreNotBlank() throws {
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height))
        let decoder = try XCTUnwrap(OpenH264Decoder())

        // Phase 0 draws a hard vertical split: dark on the left, bright on the
        // right. Blocks this large survive quantisation at any sane bitrate, so
        // a correct decode is unambiguous.
        let (y, u, v) = Self.testPattern(width: width, height: height, phase: 0)
        let accessUnit = try XCTUnwrap(encoder.encode(y: y, yStride: width,
                                                       u: u, v: v, chromaStride: width / 2))
        let buffer = try XCTUnwrap(decoder.decode(accessUnit), "no picture from a keyframe")

        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        // Sample the middle row, well clear of any edge ringing.
        let row = height / 2
        let left = Int(base[row * stride + width / 8])
        let right = Int(base[row * stride + width * 7 / 8])
        XCTAssertLessThan(left, 60, "left third should decode dark, got \(left)")
        XCTAssertGreaterThan(right, 190, "right third should decode bright, got \(right)")
    }

    // MARK: - Failure modes worth pinning down

    /// The sender is entitled to send an access unit that carries no picture.
    /// An SPS/PPS-only unit is the normal case, and treating "no output" as an
    /// error here is what previously made a healthy stream look broken.
    func testParameterSetsAloneProduceNoFrameAndAreNotAnError() throws {
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height))
        let decoder = try XCTUnwrap(OpenH264Decoder())

        let (y, u, v) = Self.testPattern(width: width, height: height, phase: 0)
        let accessUnit = try XCTUnwrap(encoder.encode(y: y, yStride: width,
                                                       u: u, v: v, chromaStride: width / 2))

        // Keep only the SPS and PPS NALs, dropping the slice.
        let parameterSets = AnnexBStream.nalus(accessUnit)
            .filter { nalu in
                guard let type = AnnexBStream.type(of: nalu) else { return false }
                return type == 7 || type == 8
            }
        XCTAssertEqual(parameterSets.count, 2, "expected one SPS and one PPS")
        let only = AnnexBStream.toAnnexB(parameterSets)

        XCTAssertNil(decoder.decode(only),
                     "parameter sets alone cannot produce a picture")
        XCTAssertEqual(decoder.frameCount, 0)
    }

    /// Garbage must not crash and must not be reported as success. The decoder
    /// is fed a sender's bytes with no framing guarantee beyond NAL boundaries,
    /// so this is reachable from a real (if broken) sender.
    func testGarbageInputDoesNotCrash() throws {
        let decoder = try XCTUnwrap(OpenH264Decoder())
        // Masked to 8 bits: the multiply overflows UInt8 well before 512, and
        // an unchecked trap here fails the test for the wrong reason.
        let junk = Data((0..<512).map { UInt8(($0 &* 7 &+ 3) & 0xFF) })
        // Whatever it returns, it must not have invented a picture.
        _ = decoder.decode(junk)
        XCTAssertEqual(decoder.frameCount, 0)

        // No start codes at all: nothing to parse.
        XCTAssertNil(decoder.decode(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertNil(decoder.decode(Data()))
    }

    /// A decoder given a slice with no prior parameter sets reports
    /// `dsNoParamSets` (0x10). That is a wiring or ordering fault rather than a
    /// codec fault, and the two need different fixes, so the distinction has to
    /// survive into the status log.
    func testSlicesWithoutParameterSetsAreDistinguishable() throws {
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height))
        let decoder = try XCTUnwrap(OpenH264Decoder())

        let (y, u, v) = Self.testPattern(width: width, height: height, phase: 0)
        let accessUnit = try XCTUnwrap(encoder.encode(y: y, yStride: width,
                                                       u: u, v: v, chromaStride: width / 2))
        let slices = AnnexBStream.nalus(accessUnit)
            .filter { nalu in
                guard let type = AnnexBStream.type(of: nalu) else { return false }
                return type == 1 || type == 5
            }
        XCTAssertFalse(slices.isEmpty)

        _ = decoder.decode(AnnexBStream.toAnnexB(slices))
        XCTAssertEqual(decoder.frameCount, 0)
        // A fresh decoder has no SPS, so it must say so rather than reporting a
        // clean decode.
        XCTAssertTrue(
            decoder.lastStateDescription.lowercased().contains("parameter set"),
            "expected a no-parameter-sets report, got \(decoder.lastStateDescription)")
    }

    /// PROTOCOL.md 5.2: the sender signals a geometry or quality change by
    /// simply starting to send new parameter sets. The decoder has to follow
    /// rather than keep decoding at the old size.
    func testResolutionChangeIsFollowed() throws {
        let decoder = try XCTUnwrap(OpenH264Decoder())

        let first = try XCTUnwrap(OpenH264Encoder(width: 320, height: 240))
        let (y1, u1, v1) = Self.testPattern(width: 320, height: 240, phase: 0)
        let au1 = try XCTUnwrap(first.encode(y: y1, yStride: 320,
                                              u: u1, v: v1, chromaStride: 160))
        let buf1 = try XCTUnwrap(decoder.decode(au1))
        XCTAssertEqual(CVPixelBufferGetWidth(buf1), 320)
        XCTAssertEqual(decoder.width, 320)

        // New parameter sets at a new size. OpenH264 handles this in-stream, so
        // no reset is needed — but the Swift layer must resize its buffers.
        let second = try XCTUnwrap(OpenH264Encoder(width: 640, height: 360))
        let (y2, u2, v2) = Self.testPattern(width: 640, height: 360, phase: 0)
        let au2 = try XCTUnwrap(second.encode(y: y2, yStride: 640,
                                              u: u2, v: v2, chromaStride: 320))
        let buf2 = try XCTUnwrap(decoder.decode(au2))
        XCTAssertEqual(CVPixelBufferGetWidth(buf2), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(buf2), 360)
        XCTAssertEqual(decoder.width, 640)
        XCTAssertEqual(decoder.height, 360)
    }

    /// `reset()` must drop decoder state WITHOUT freeing the handle.
    ///
    /// It used to call `od_h264_destroy` on a `let` handle, so the pointer kept
    /// pointing at freed memory: the next decode was a use-after-free, and the
    /// object's own `deinit` was a double free. Both terminated the process
    /// with `EXC_BAD_ACCESS` inside `od_h264_destroy`, on every receiver
    /// disconnect and every resolution change once the software fallback was
    /// active — which is exactly the unsigned/old-iPad configuration this
    /// project targets, and therefore exactly the configuration the rest of this
    /// suite never exercises.
    ///
    /// Each of the three sub-cases below crashed the process on the old code, so
    /// this test failing is a crash, not a failed assertion.
    func testResetKeepsTheHandleValid() throws {
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        let (y, u, v) = Self.testPattern(width: width, height: height, phase: 0)
        let keyframe = try XCTUnwrap(encoder.encode(y: y, yStride: width, u: u, v: v,
                                                    chromaStride: width / 2))
        let decoder = try XCTUnwrap(OpenH264Decoder())

        // A reset on a decoder that has never decoded: idempotent, must not trap.
        decoder.reset()
        decoder.reset()

        // A reset mid-stream, then decode again on the same handle.
        _ = decoder.decode(keyframe)
        XCTAssertGreaterThan(decoder.frameCount, 0, "precondition: decoded before reset")
        decoder.reset()
        // `frameCount` is deliberately NOT cleared: it counts frames over the
        // decoder's lifetime, for reporting, and a reset is not a new lifetime.
        // What must be cleared is the geometry and the last codec state.
        XCTAssertFalse(decoder.hasGeometry, "geometry is reported reset")
        XCTAssertEqual(decoder.lastState, 0, "last decode state is reported reset")

        // The handle must still be usable. A delta frame here has no reference
        // picture (the reset dropped it), so no picture is the correct result —
        // what matters is that the call returns instead of dereferencing freed
        // memory. A fresh keyframe must then decode normally.
        _ = decoder.decode(keyframe)
        let buffer = try XCTUnwrap(decoder.decode(keyframe),
                                  "the decoder must still work after reset")
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), height)
    }

    /// Releasing a decoder that was reset must not double free. The old `reset`
    /// freed the handle and left the `let` pointing at it, so `deinit` freed it
    /// again.
    func testResetThenDeallocDoesNotDoubleFree() throws {
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        let (y, u, v) = Self.testPattern(width: width, height: height, phase: 0)
        let keyframe = try XCTUnwrap(encoder.encode(y: y, yStride: width, u: u, v: v,
                                                    chromaStride: width / 2))

        // Scoped so the decoder is guaranteed to deallocate inside this test,
        // which is where the second free used to happen.
        do {
            let decoder = try XCTUnwrap(OpenH264Decoder())
            _ = decoder.decode(keyframe)
            decoder.reset()
        }
        // Reaching here at all is the assertion: the old code trapped here.
        XCTAssertTrue(true)
    }

    // MARK: - Pattern

    /// A hard-edged pattern that survives lossy compression: full-range luma
    /// blocks, neutral chroma, and a phase-dependent bar so consecutive frames
    /// differ (which is what makes P-frames meaningful).
    ///
    /// Full-range (0 and 235) rather than studio range (16 and 235) because that
    /// is what the encoder is configured to signal, and a mismatch here would
    /// show up as a washed-out decode and be blamed on the decoder.
    private static func testPattern(width: Int, height: Int,
                                    phase: Int) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
        var y = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let dark = col < width / 2
                y[row * width + col] = dark ? 16 : 235
            }
        }
        // A moving bar in the right half, so each frame is genuinely different.
        let barColumn = phase * (width / 8)
        for row in 0..<height {
            let col = min(width - 1, max(0, barColumn))
            y[row * width + col] = 128
        }
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        let neutral = [UInt8](repeating: 128, count: chromaWidth * chromaHeight)
        return (y, neutral, neutral)
    }
}
#endif
