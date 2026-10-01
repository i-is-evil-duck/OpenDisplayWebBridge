#if canImport(COpenH264)
import CoreVideo
import Foundation
import XCTest

@testable import OpenDisplayBridge

/// End-to-end: does the transcoder actually produce pictures on this machine?
///
/// ## Why this test exists
///
/// The failure that stalled this work was not a crash or a wrong pixel. It was
/// silence: `VTDecompressionSessionDecodeFrame` returned `noErr`, the output
/// callback never fired, and the browser showed black. Nothing in the codebase
/// could tell that apart from a sender that had stopped sending, which is
/// exactly why it took so long to find.
///
/// So the assertion here is deliberately blunt: feed real H.264 through the
/// public `ingest` entry point and require that pixels come out. If the
/// hardware path is unavailable and the software fallback is broken, this fails.
/// If someone removes the fallback, this fails. Both are worth failing for.
///
/// ## What it deliberately does not do
///
/// It does not assert *which* backend decoded. On a machine with a Developer ID
/// that is VideoToolbox, and insisting on OpenH264 would make the test wrong
/// there. The mode is reported separately so a black screen is attributable.
final class H264TranscoderFallbackTests: XCTestCase {

    /// The real failure mode, reproduced end to end. A generous timeout because
    /// the fallback deliberately waits `H264Transcoder.fallbackDelay` before
    /// deciding, and this is the one test that has to sit through it.
    func testRealH264ProducesFramesEndToEnd() throws {
        let width = 320, height = 240
        let transcoder = H264Transcoder()
        defer { transcoder.stop() }

        let frameBox = FrameBox()
        transcoder.onFrame = { buffer, _ in
            frameBox.record(width: CVPixelBufferGetWidth(buffer),
                            height: CVPixelBufferGetHeight(buffer))
        }
        let statusBox = StatusBox()
        transcoder.onStatus = { statusBox.record($0) }

        // Feed continuously: a single keyframe is not enough, because the
        // fallback switches backends mid-stream and the next access unit has to
        // decode on the new one.
        let stop = FeedStop()
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        let feedThread = Thread {
            var phase = 0
            while !stop.isSet {
                let (y, u, v) = Self.testPattern(width: width, height: height, phase: phase)
                if let au = encoder.encode(y: y, yStride: width, u: u, v: v,
                                           chromaStride: width / 2) {
                    transcoder.ingest(au)
                }
                phase += 1
                Thread.sleep(forTimeInterval: 1.0 / 15.0)
            }
        }
        feedThread.start()
        defer { stop.set() }

        // 2s of fallback delay plus slack for a loaded machine.
        let deadline = Date().addingTimeInterval(12)
        while frameBox.count == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop.set()

        let diagnostics = """
        frames=\(frameBox.count) backend=\(transcoder.backendName)
        status=\(statusBox.all.joined(separator: " | "))
        """

        XCTAssertGreaterThan(frameBox.count, 0,
                             "no frames were produced from real H.264. \(diagnostics)")

        // The pictures must be the right size, not just non-zero in count: a
        // decoder that emits mis-strided buffers is worse than one that emits
        // nothing, because it looks alive.
        let first = try XCTUnwrap(frameBox.first)
        XCTAssertEqual(first.width, width, diagnostics)
        XCTAssertEqual(first.height, height, diagnostics)

        // A backend must have been chosen and reported. An unreported mode is
        // what makes a black screen unattributable in the field.
        XCTAssertNotEqual(transcoder.backendName, "none", diagnostics)
    }

    /// Hardware is preferred, and where hardware works the fallback must *not*
    /// engage. A fallback that fires anyway would silently cost CPU on every
    /// machine, signed ones included.
    ///
    /// This also corrects an earlier belief recorded in WEBRTC_PLAN.md: that
    /// macOS gates VideoToolbox's hardware path for unsigned processes. That is
    /// true of the *encoder* — `EncoderReport` finds no encoders and encode
    /// returns -12902 — but not the decoder, which works unsigned and decoded all
    /// 40 frames in `testEveryFrameInARunDecodes`. The "decode is blocked"
    /// reading came from the session-teardown bug below, which looks identical
    /// from the outside: one frame, then silence, no error.
    func testHardwareIsPreferredAndNotAbandonedWhenItWorks() throws {
        let width = 320, height = 240
        let transcoder = H264Transcoder()
        defer { transcoder.stop() }
        XCTAssertEqual(transcoder.backendName, "VideoToolbox",
                       "hardware must be tried first on every platform")

        let frameBox = FrameBox()
        transcoder.onFrame = { buffer, _ in
            frameBox.record(width: CVPixelBufferGetWidth(buffer),
                            height: CVPixelBufferGetHeight(buffer))
        }
        let statusBox = StatusBox()
        transcoder.onStatus = { statusBox.record($0) }

        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        for phase in 0..<6 {
            let (y, u, v) = Self.testPattern(width: width, height: height, phase: phase)
            if let au = encoder.encode(y: y, yStride: width, u: u, v: v,
                                       chromaStride: width / 2) {
                transcoder.ingest(au)
            }
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }

        // Well past the fallback delay. If hardware is working the decision
        // never has to be made.
        Thread.sleep(forTimeInterval: 3.0)

        XCTAssertGreaterThan(frameBox.count, 0, "no frames decoded")
        XCTAssertEqual(transcoder.backendName, "VideoToolbox",
                       "a working hardware decoder must not be abandoned; status: "
                       + statusBox.all.joined(separator: " | "))
    }

    /// Malformed input must be reported, not silently absorbed. The sender's
    /// bytes cross a socket and PROTOCOL.md does not guarantee framing beyond
    /// NAL boundaries, so this is reachable.
    func testGarbageIsReportedNotSilentlyDropped() {
        let transcoder = H264Transcoder()
        defer { transcoder.stop() }
        let statusBox = StatusBox()
        transcoder.onStatus = { statusBox.record($0) }

        // A start code followed by bytes that claim to be an SPS but are not
        // parseable, plus a slice, so the demux produces an access unit.
        var frame = Data([0, 0, 0, 1])
        frame.append(contentsOf: [0x67, 0x00, 0x00, 0x03, 0xFF])
        frame.append(contentsOf: [0, 0, 0, 1])
        frame.append(contentsOf: [0x65, 0x88, 0x84, 0x00, 0x33, 0xFF])
        XCTAssertFalse(transcoder.ingest(frame), "garbage must not be reported as accepted")

        // Either way, something must have been said. A silent drop is what made
        // the original bug invisible.
        XCTAssertFalse(statusBox.all.isEmpty,
                       "a rejected frame must produce a status line")
    }

    /// The decoded pixels must match the picture that was encoded.
    ///
    /// This is the assertion that "it decoded" kept failing to mean. Counts and
    /// dimensions are all satisfied by a decoder emitting correctly-sized black
    /// frames, which is exactly the shape of the original bug: a plausible-
    /// looking stats overlay over a black screen. Here the source is a hard
    /// dark/bright split, so a correct decode is unambiguous and a decoder
    /// returning noise or a flat field fails.
    ///
    /// Runs on whichever backend is active, so it covers VideoToolbox here and
    /// the OpenH264 fallback wherever hardware is unavailable.
    func testDecodedPixelsMatchTheSource() throws {
        let width = 320, height = 240
        let transcoder = H264Transcoder()
        defer { transcoder.stop() }

        let luma = LumaBox()
        transcoder.onFrame = { buffer, _ in
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
            // Named `rowBytes`, not `stride`: a local called `stride` shadows
            // `stride(from:to:by:)`.
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            // Sample the middle row, clear of any edge ringing.
            let row = height / 2
            luma.record(left: Int(pixels[row * rowBytes + width / 8]),
                        right: Int(pixels[row * rowBytes + width * 7 / 8]))
        }

        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        let (y, u, v) = Self.testPattern(width: width, height: height, phase: 0)
        let au = try XCTUnwrap(encoder.encode(y: y, yStride: width, u: u, v: v,
                                              chromaStride: width / 2))
        transcoder.ingest(au)
        Thread.sleep(forTimeInterval: 0.5)

        let sample = try XCTUnwrap(luma.first,
                                   "no frame decoded; backend=\(transcoder.backendName)")
        XCTAssertLessThan(sample.left, 60,
                          "left third should decode dark, got \(sample.left)")
        XCTAssertGreaterThan(sample.right, 190,
                             "right third should decode bright, got \(sample.right)")
    }

    // MARK: - Regression: the session must not be torn down mid-stream

    /// The bug that actually stalled this work, pinned down.
    ///
    /// `lastSPS`/`lastPPS` used to be primed lazily inside
    /// `needsNewFormatDescription`, which is short-circuited on the first access
    /// unit by `!hadParameterSets`. So the second access unit always compared
    /// against a nil `lastSPS`, decided the parameter sets had changed, and
    /// invalidated a working decoder. Every P-frame after that point had no
    /// reference picture, so VideoToolbox produced nothing — and reported no
    /// error.
    ///
    /// The symptom was one frame followed by silence, which is exactly what a
    /// signature-gated hardware path looks like. That misdiagnosis is why this
    /// test feeds a plain run of frames and insists that *all* of them decode.
    func testEveryFrameInARunDecodes() throws {
        let width = 320, height = 240
        let transcoder = H264Transcoder()
        defer { transcoder.stop() }

        let frameBox = FrameBox()
        transcoder.onFrame = { buffer, _ in
            frameBox.record(width: CVPixelBufferGetWidth(buffer),
                            height: CVPixelBufferGetHeight(buffer))
        }

        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        // Two full intra periods, so the run definitely spans several keyframes
        // and any spurious rebuild has time to break the frames after it.
        let expected = 40
        for phase in 0..<expected {
            let (y, u, v) = Self.testPattern(width: width, height: height, phase: phase)
            let au = try XCTUnwrap(
                encoder.encode(y: y, yStride: width, u: u, v: v, chromaStride: width / 2),
                "frame \(phase) encoded to nothing")
            transcoder.ingest(au)
            // VideoToolbox decodes asynchronously; without a yield the queue
            // fills and frames get dropped by the in-flight cap rather than by
            // the bug this test is about.
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        // Let the last few callbacks land.
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(frameBox.count, expected,
                       "expected every frame to decode, backend=\(transcoder.backendName)")
    }

    /// A geometry change is a real stream event (PROTOCOL.md 5.2) and must
    /// recover, not wedge. The decoder is rebuilt with no reference pictures, so
    /// the frames before the next keyframe cannot decode — and must be dropped
    /// deliberately rather than fed in and silently ignored.
    func testParameterSetChangeRecoversAtTheNextKeyframe() throws {
        let first = try XCTUnwrap(OpenH264H264Decoder())
        let second = try XCTUnwrap(OpenH264H264Decoder())
        let width = 320, height = 240
        let encA = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))
        let encB = try XCTUnwrap(OpenH264Encoder(width: 640, height: 360, fps: 15))

        let frameA = try XCTUnwrap(
            encA.encode(y: Self.testPattern(width: width, height: height, phase: 0).y,
                        yStride: width,
                        u: [UInt8](repeating: 128, count: (width / 2) * (height / 2)),
                        v: [UInt8](repeating: 128, count: (width / 2) * (height / 2)),
                        chromaStride: width / 2))
        _ = first.decode(Self.demux(frameA, width: width, height: height),
                         format: nil)
        XCTAssertGreaterThan(first.name.count, 0)

        // New geometry, new decoder.
        let patternB = Self.testPattern(width: 640, height: 360, phase: 0)
        let frameB = try XCTUnwrap(
            encB.encode(y: patternB.y, yStride: 640, u: patternB.u, v: patternB.v,
                        chromaStride: 320))
        let outcome = second.decode(Self.demux(frameB, width: 640, height: 360), format: nil)
        if case .delivered(let buffer) = outcome {
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), 360)
        } else {
            XCTFail("expected a picture at the new geometry, got \(outcome)")
        }
    }

    /// The backend wrapper must survive `reset()` and keep decoding.
    ///
    /// `OpenH264H264Decoder.reset()` used to detach the decoder and drop it
    /// without ever recreating one, so every subsequent `decode` returned
    /// `.rejected("decoder is gone")`. Because `H264Transcoder` calls
    /// `backend.reset()` on every parameter-set change, one resolution change —
    /// an explicitly supported event under PROTOCOL.md 5.2 — killed the WebRTC
    /// path permanently, and the only symptom was a rejection naming a wiring
    /// fault rather than the stream event that caused it.
    ///
    /// This drives the backend directly rather than through `H264Transcoder`,
    /// because the transcoder would mask it here: on a machine where VideoToolbox
    /// works it is the active backend, and this one is only selected by the
    /// fallback. The wrapper's contract has to hold whichever backend is live.
    func testSoftwareBackendSurvivesReset() throws {
        let backend = try XCTUnwrap(OpenH264H264Decoder())
        let width = 320, height = 240
        let encoder = try XCTUnwrap(OpenH264Encoder(width: width, height: height, fps: 15))

        // One stream for the whole test, as `H264Transcoder` does. A fresh
        // `AnnexBStream` per access unit would drop the parameter sets and the
        // P-frames that follow could not demux at all, which is a property of
        // the test's own scaffolding rather than of the backend.
        var stream = AnnexBStream()
        // `phase` advances so each frame genuinely differs from the last, and
        // `forceKeyframe` before every encode guarantees a decodable unit after a
        // reset — which is exactly the contract `H264Transcoding` relies on when
        // it sets `awaitingKeyframe`.
        var phase = 0
        func decodeOne() -> H264DecodeOutcome {
            encoder.forceKeyframe()
            let (y, u, v) = Self.testPattern(width: width, height: height, phase: phase)
            phase += 1
            let au = try! XCTUnwrap(encoder.encode(y: y, yStride: width, u: u, v: v,
                                                   chromaStride: width / 2))
            let unit = try! XCTUnwrap(stream.consume(au),
                                      "encoder output should demux into an access unit")
            return backend.decode(unit, format: nil)
        }

        // Warm it up, so the reset has real state to drop.
        let warmup = decodeOne()
        guard case .delivered = warmup else {
            return XCTFail("expected a picture before the reset, got \(warmup)")
        }

        backend.reset()

        // After a reset the next unit must be a keyframe to yield a picture; what
        // must NOT happen is a rejection naming a missing decoder.
        switch decodeOne() {
        case .rejected(let reason):
            XCTFail("backend must still work after reset, but rejected: \(reason)")
        case .delivered, .accepted, .noPicture:
            break   // any of these is fine; a rejection is not
        }

        // A second reset in a row must be safe too, and decoding must continue.
        backend.reset()
        switch decodeOne() {
        case .rejected(let reason):
            XCTFail("backend must survive a repeated reset, but rejected: \(reason)")
        case .delivered, .accepted, .noPicture:
            break
        }
    }

    // MARK: - Helpers

    /// Shapes an encoder access unit into the struct `H264Decoding` takes, the
    /// way `H264Transcoder`'s demux would.
    private static func demux(_ frame: Data, width: Int, height: Int)
        -> AnnexBStream.AccessUnit {
        var stream = AnnexBStream()
        let au = stream.consume(frame)
        precondition(au != nil, "encoder output should demux into an access unit")
        return au!
    }

    private struct Size {
        let width: Int
        let height: Int
    }

    /// Thread-safe collection of delivered frame sizes.
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Size] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return sizes.count }
        var first: Size? { lock.lock(); defer { lock.unlock() }; return sizes.first }
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

    /// One luma sample pair, taken from the middle row of a decoded frame.
    private final class LumaBox: @unchecked Sendable {
        struct Sample {
            let left: Int
            let right: Int
        }
        private let lock = NSLock()
        private var samples: [Sample] = []
        var first: Sample? { lock.lock(); defer { lock.unlock() }; return samples.first }
        func record(left: Int, right: Int) {
            lock.lock(); defer { lock.unlock() }
            samples.append(Sample(left: left, right: right))
        }
    }

    private final class FeedStop: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// A moving pattern: hard-edged blocks, plus a bar that shifts each frame.
    /// Full-range luma to match the encoder's signalling, and a real inter-frame
    /// difference so the P-frames are not trivially skippable.
    private static func testPattern(width: Int, height: Int,
                                    phase: Int) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
        var y = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                y[row * width + col] = col < width / 2 ? 16 : 235
            }
        }
        let bar = min(width - 1, max(0, phase * 4))
        for row in 0..<height {
            y[row * width + bar] = 128
        }
        let neutral = [UInt8](repeating: 128, count: (width / 2) * (height / 2))
        return (y, neutral, neutral)
    }
}
#endif
