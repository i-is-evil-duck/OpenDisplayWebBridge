import CoreVideo
import Foundation
import XCTest

@testable import OpenDisplayBridge

/// Replays a capture from the real `OpenDisplay.app` sender.
///
/// ## Why a real capture is checked in
///
/// Every other test in this suite generates its H.264 with OpenH264's encoder,
/// which is convenient and deterministic but self-consistent in a way the real
/// sender is not. Two bugs survived that gap and cost most of the time spent on
/// this work:
///
/// 1. **A mid-stream decoder teardown.** `lastSPS`/`lastPPS` were primed lazily,
///    so the second access unit always looked like a parameter-set change and
///    invalidated a working decoder. Every P-frame after that had no reference
///    picture. Symptom: one frame, then silence, no error.
///
/// 2. **A lock-ordering deadlock.** `ingest` held the transcoder lock across
///    `VTDecompressionSessionDecodeFrame`, while VideoToolbox's callback
///    re-enters the same lock from `vtdecoder-callback-queue`. Symptom: the
///    process hangs with no crash and no log line.
///
/// Neither reproduced on the synthetic 320x240 stream; both reproduced on the
/// first frame of this 292x360 capture. A 336-byte fixture is a cheap way to
/// keep them fixed.
///
/// ## Why the access units are replayed separately
///
/// `real-sender-292x360.264` is the concatenation of the sender's access units,
/// each of which arrived as its own wire frame. Feeding the file as a single
/// frame hands the demux three pictures in one sample buffer, which is malformed
/// and which no conformant sender produces — so it is split back apart here
/// rather than treated as a supported input.
final class RealSenderStreamTests: XCTestCase {

    private static let fixture = "real-sender-292x360.264"

    private func loadFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: Self.fixture, withExtension: nil,
            subdirectory: "Fixtures") ?? Bundle.module.url(
            forResource: Self.fixture, withExtension: nil),
            "the checked-in sender capture must be in the test bundle")
        return try Data(contentsOf: url)
    }

    /// Splits the capture back into the wire frames the sender actually sent.
    private func wireFrames(_ data: Data) -> [Data] {
        // A sender repeats SPS and PPS on every keyframe, so a new parameter set
        // marks the start of the next access unit. Anything before the first one
        // is a leading partial and is discarded.
        let nalus = AnnexBStream.nalus(data)
        var frames: [Data] = []
        var current: [Data] = []
        for nalu in nalus {
            let type = AnnexBStream.type(of: nalu)
            if type == 7, !current.isEmpty {
                frames.append(AnnexBStream.toAnnexB(current))
                current = []
            }
            if !current.isEmpty || type == 7 {
                current.append(nalu)
            }
        }
        if !current.isEmpty { frames.append(AnnexBStream.toAnnexB(current)) }
        return frames
    }

    /// The end-to-end assertion: real sender bytes in, real pictures out.
    ///
    /// This is the test that deadlocks if the lock ordering regresses, which is
    /// deliberate — a hang is a louder signal than a subtly wrong pixel, and the
    /// suite's own timeout will catch it.
    func testRealSenderStreamDecodesToFrames() throws {
        let capture = try loadFixture()
        let frames = wireFrames(capture)
        XCTAssertGreaterThanOrEqual(frames.count, 2,
                                    "expected multiple access units in the capture")

        let transcoder = H264Transcoder()
        defer { transcoder.stop() }

        let sizes = SizeBox()
        transcoder.onFrame = { buffer, _ in
            sizes.record(width: CVPixelBufferGetWidth(buffer),
                         height: CVPixelBufferGetHeight(buffer))
        }
        let statusBox = StatusBox()
        transcoder.onStatus = { statusBox.record($0) }

        for frame in frames {
            transcoder.ingest(frame)
            // VideoToolbox is asynchronous; a yield keeps the in-flight cap from
            // dropping frames for reasons unrelated to what is being tested.
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        Thread.sleep(forTimeInterval: 0.5)

        let diagnostics = "backend=\(transcoder.backendName) sizes=\(sizes.all) "
            + "status=\(statusBox.all.joined(separator: " | "))"

        XCTAssertGreaterThan(sizes.count, 0,
                             "no frames decoded from the real capture. \(diagnostics)")

        // The geometry must match the sender's, and it is rotated relative to the
        // display: 292x360, not 360x292. A decoder that ignored the SPS would
        // report the other way round.
        for size in sizes.all {
            XCTAssertEqual(size.width, 292, diagnostics)
            XCTAssertEqual(size.height, 360, diagnostics)
        }
    }

    /// The stream must be accepted as a whole, not just its first picture.
    /// PROTOCOL.md 5.2 has the sender repeat SPS/PPS on every IDR, and a
    /// receiver that mistakes that for a geometry change tears itself down
    /// mid-stream — the first of the two bugs described above.
    func testRepeatedParameterSetsDoNotResetTheStream() throws {
        let capture = try loadFixture()
        // The capture has three access units and the sender repeats parameter
        // sets on each; a rebuild on the second one is the regression.
        let frames = wireFrames(capture)
        XCTAssertGreaterThanOrEqual(frames.count, 3,
                                    "this test needs at least three access units")

        let transcoder = H264Transcoder()
        defer { transcoder.stop() }
        let statusBox = StatusBox()
        transcoder.onStatus = { statusBox.record($0) }

        for frame in frames { transcoder.ingest(frame) }

        let rebuilds = statusBox.all.filter { $0.hasPrefix("stream is") }.count
        XCTAssertEqual(rebuilds, 1,
                       "the stream must be configured once, not per access unit: "
                       + statusBox.all.joined(separator: " | "))
    }

    // Note on what this file deliberately does *not* assert: that the decoded
    // pixels contain recognisable image content.
    //
    // The checked-in capture happens to be of a nearly uniform region of the
    // desktop — its keyframe is 144 bytes for a 292x360 frame, which is what a
    // flat picture compresses to, and it decodes to a constant luma. That makes
    // a content assertion here a test of the desktop's wallpaper rather than of
    // the code. Content is asserted instead on the synthetic stream, where the
    // picture is known by construction:
    // `H264TranscoderFallbackTests.testDecodedPixelsMatchTheSource` for the
    // VideoToolbox path and `OpenH264DecoderTests.testDecodedPixelsAreNotBlank`
    // for the software one.

    // MARK: - Helpers

    private struct Size {
        let width: Int
        let height: Int
    }

    private final class SizeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Size] = []
        var all: [Size] { lock.lock(); defer { lock.unlock() }; return sizes }
        var count: Int { all.count }
        func record(width: Int, height: Int) {
            lock.lock(); defer { lock.unlock() }
            sizes.append(Size(width: width, height: height))
        }
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func record(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }
    }
}
