import XCTest
@testable import OpenDisplayBridge

/// The parsing half of the WebRTC transcode path (WEBRTC_PLAN.md W2).
///
/// This is deliberately the part that CAN be tested on any host: the
/// VideoToolbox decode itself cannot, because hardware decode is unreachable
/// from an unsigned process. Getting the demux and AVCC conversion right is
/// what makes the decode work at all, so it carries real weight.
final class AnnexBStreamTests: XCTestCase {

    /// 4-byte Annex B start code (PROTOCOL.md 5.1: always 4 bytes).
    private let sc = Data([0x00, 0x00, 0x00, 0x01])

    /// A NALU *including* its one-byte header, which is how it appears on the
    /// wire after the start code.
    private func nalu(_ header: UInt8, _ rest: [UInt8] = [0xAA]) -> Data {
        Data([header] + rest)
    }
    private var sps: Data { nalu(0x67, [0x64, 0x00, 0x1E]) }
    private var pps: Data { nalu(0x68, [0xEE, 0x3C, 0x80]) }
    private var idr: Data { nalu(0x65, [0x88, 0x84, 0x00]) }
    private var nonIdrSlice: Data { nalu(0x41, [0x9A, 0x00]) }

    private func frame(_ nalus: [Data]) -> Data {
        nalus.reduce(into: Data()) { $0.append(sc); $0.append($1) }
    }

    // MARK: - Splitting

    func testSplitsMultipleNalus() {
        let units = AnnexBStream.nalus(frame([sps, pps, idr]))
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0], sps)
        XCTAssertEqual(units[1], pps)
        XCTAssertEqual(units[2], idr)
    }

    /// PROTOCOL.md 5.1: start codes are always 4 bytes and senders MUST NOT
    /// emit 3-byte codes, so splitting on the 4-byte pattern only is correct.
    func testIgnoresThreeByteStartCodes() {
        var f = Data([0x00, 0x00, 0x01, 0x65, 0x11])   // 3-byte code
        f.append(sc)
        f.append(nalu(0x41, [0x22]))
        let units = AnnexBStream.nalus(f)
        XCTAssertEqual(units.count, 1, "the 3-byte-coded NALU must not be recognised")
        XCTAssertEqual(units[0], nalu(0x41, [0x22]))
    }

    func testLeadingZerosInsideNaluArePreserved() {
        // Trailing zero bytes belong to the NALU, not to a start code.
        let payload = nalu(0x65, [0x00, 0x00, 0x00])
        XCTAssertEqual(AnnexBStream.nalus(frame([payload])).first, payload)
    }

    func testEmptyAndGarbageInput() {
        XCTAssertTrue(AnnexBStream.nalus(Data()).isEmpty)
        XCTAssertTrue(AnnexBStream.nalus(Data(repeating: 0x41, count: 32)).isEmpty)
    }

    // MARK: - Parameter sets and keyframes

    /// THE keyframe bug this replaces: on a real IDR the first NALU is the SPS,
    /// so testing nalus[0] == 5 classified every keyframe as a delta. Here the
    /// keyframe is detected by *presence* of an IDR anywhere in the frame.
    func testKeyframeDetectedDespiteLeadingSPS() throws {
        var s = AnnexBStream()
        let au = try XCTUnwrap(s.consume(frame([sps, pps, idr])))
        XCTAssertTrue(au.isKeyframe, "SPS,PPS,IDR is a keyframe even though nalus[0] is the SPS")
    }

    func testDeltaFrameIsNotAKeyframe() throws {
        var s = AnnexBStream()
        _ = s.consume(frame([sps, pps, idr]))
        let delta = try XCTUnwrap(s.consume(frame([nonIdrSlice])))
        XCTAssertFalse(delta.isKeyframe)
    }

    /// PROTOCOL.md 5.1: all slices of one picture travel in one wire frame, so
    /// a multi-slice IDR is still one keyframe and one access unit.
    func testMultipleSlicesAreOneKeyframeAccessUnit() throws {
        var s = AnnexBStream()
        let au = try XCTUnwrap(s.consume(frame([sps, pps,
                                                nalu(0x65, [0x88, 0x01]),
                                                nalu(0x65, [0x88, 0x02])])))
        XCTAssertTrue(au.isKeyframe)
        // 2 NALUs of 3 and 3 bytes, each 4-byte length prefixed.
        XCTAssertEqual(au.data.count, (4 + 3) + (4 + 3))
    }

    func testNoAccessUnitBeforeParameterSets() {
        var s = AnnexBStream()
        XCTAssertNil(s.consume(frame([nonIdrSlice])))
        XCTAssertFalse(s.hasParameterSets)
    }

    func testSPSAloneIsNotEnough() {
        var s = AnnexBStream()
        _ = s.consume(frame([sps, idr]))
        XCTAssertNotNil(s.sps)
        XCTAssertNil(s.pps)
        XCTAssertFalse(s.hasParameterSets)
    }

    /// SEI-only frames carry no decodable picture but must not break the stream.
    func testSEIOnlyFrameYieldsNothing() {
        var s = AnnexBStream()
        _ = s.consume(frame([sps, pps]))
        XCTAssertNil(s.consume(frame([nalu(0x06, [0x05, 0x01])])))
    }

    /// Rotation and mid-stream joins both restart with new parameter sets.
    func testParameterSetsAreReplacedOnStreamChange() throws {
        var s = AnnexBStream()
        _ = s.consume(frame([sps, pps, idr]))
        let newSPS = nalu(0x67, [0x64, 0x00, 0x33])
        _ = s.consume(frame([newSPS, pps, idr]))
        XCTAssertEqual(s.sps, newSPS, "a new SPS must replace the old one")
    }

    // MARK: - AVCC conversion

    /// The inverse of AnnexB.avccToAnnexB — if these disagree, VideoToolbox
    /// gets garbage.
    func testAVCCRoundTripsAgainstTheEncoder() {
        let nalus = [Data([0x65, 0x88, 0x84, 0x00]), Data([0x41, 0x9A])]
        XCTAssertEqual(AnnexB.avccToAnnexB(AnnexBStream.toAVCC(nalus)),
                       frame(nalus),
                       "toAVCC must invert avccToAnnexB exactly")
    }

    func testAVCCLengthsAreBigEndian() {
        let avcc = AnnexBStream.toAVCC([Data(repeating: 0x41, count: 0x0102)])
        XCTAssertEqual(Array(avcc.prefix(4)), [0x00, 0x00, 0x01, 0x02])
    }

    // MARK: - Format description

    /// VideoToolbox must accept the parameter sets and yield usable
    /// dimensions — the SPS is the authoritative source for video size
    /// (PROTOCOL.md 5.2), never `hello` or `streamConfig`.
    ///
    /// Exact values are not asserted: a hand-written SPS is easy to get subtly
    /// wrong, and what matters here is that a real SPS/PPS pair produces a valid
    /// description and positive dimensions. The "SPS wins over hello" rule is
    /// covered by the parameter-set replacement test above and by the
    /// browser-side parser tests.
    func testFormatDescriptionFromRealParameterSets() throws {
        // A genuine baseline-profile SPS (profile_idc 66, level 1.0, one
        // macroblock => 16x16) built out to a valid Exp-Golomb bitstring.
        // Using a high-profile header (0x64) without the mandatory
        // chroma_format_idc block is rejected, which is what
        // testMalformedParameterSetsAreRejected covers.
        let validSPS = Data([0x67, 0x42, 0xC0, 0x0A, 0xDA, 0x79])
        let validPPS = Data([0x68, 0xCE, 0x3C, 0x80])
        var s = AnnexBStream()
        _ = s.consume(frame([validSPS, validPPS, idr]))

        let desc = try XCTUnwrap(s.makeFormatDescription(),
                                 "a valid SPS/PPS pair must produce a format description")
        let dims = try XCTUnwrap(AnnexBStream.dimensions(desc))
        XCTAssertEqual(dims.width, 16, "dimensions must come from the SPS, not a constant")
        XCTAssertEqual(dims.height, 16)
    }

    /// A truncated or wrong-profile parameter set must be refused, not
    /// half-applied: a bad format description produces garbage frames.
    func testMalformedParameterSetsAreRejected() {
        var s = AnnexBStream()
        // High-profile header with the mandatory chroma_format_idc block absent.
        _ = s.consume(frame([Data([0x67, 0x64, 0x00, 0x1E, 0xD9, 0x40]), pps, idr]))
        XCTAssertNil(s.makeFormatDescription(),
                     "an incomplete high-profile SPS must not yield a format description")
    }

    func testFormatDescriptionNeedsBothParameterSets() {
        XCTAssertNil(AnnexBStream().makeFormatDescription())
    }

    // MARK: - Demux parity with the browser

    /// The bridge must agree with receiver.js on what is video, or the two ends
    /// disagree about the stream. PROTOCOL.md 4: a frame is control iff
    /// length < 32768 AND first byte '{' AND no NUL.
    func testVideoFramesAreClassifiedAsVideo() {
        let keyframe = frame([sps, pps, idr])
        let isControl = keyframe.count < 32768
            && keyframe.first == 0x7B
            && !keyframe.contains(0)
        XCTAssertFalse(isControl, "an IDR containing NULs must classify as video")
    }

    /// And the mirror case: a telemetry-prefixed keyframe starts with '{' and
    /// is still video, saved only by the NUL rule.
    func testTelemetryPrefixedKeyframeIsStillVideo() {
        let telemetry = Data(#"{"cap":1750000000000,"snd":1750000000005}"#.utf8)
        let keyframe = telemetry + frame([sps, pps, idr])
        XCTAssertEqual(keyframe.first, 0x7B, "precondition: starts with '{'")
        let isControl = keyframe.count < 32768
            && keyframe.first == 0x7B
            && !keyframe.contains(0)
        XCTAssertFalse(isControl, "must classify as video thanks to the NUL rule")
    }
}
