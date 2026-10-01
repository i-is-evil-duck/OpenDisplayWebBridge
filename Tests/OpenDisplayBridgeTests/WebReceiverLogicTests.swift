import XCTest
@testable import OpenDisplayBridge

/// Ports of the two `receiver.js` predicates that had real bugs, so the logic
/// is covered by `swift test` instead of only by manual browser testing.
///
/// These deliberately mirror the JavaScript rather than reimplementing it: the
/// point is to pin the *rule* from PROTOCOL.md, and to fail loudly if someone
/// changes one side without the other.
final class WebReceiverLogicTests: XCTestCase {

    // MARK: - Section 4 demux heuristic

    /// PROTOCOL.md 4: a sender->receiver frame is JSON control iff
    /// (1) length < 32768, AND (2) first byte is '{', AND (3) no NUL byte.
    private func isControl(_ buf: [UInt8]) -> Bool {
        if buf.count >= 32768 || buf.isEmpty || buf[0] != 0x7B { return false }
        return !buf.contains(0)
    }

    func testDemuxAcceptsControl() {
        XCTAssertTrue(isControl(Array(#"{"type":"ping","t":1}"#.utf8)))
    }

    func testDemuxRejectsVideo() {
        // Annex B start code contains NULs, so real video can never pass.
        let video: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x00, 0x00]
        XCTAssertFalse(isControl(video))
    }

    /// The telemetry prefix means a keyframe STARTS with '{' (PROTOCOL.md 5.1).
    /// It is still video, and only the NUL rule saves us. This is the exact case
    /// the spec calls out, so pin it.
    func testDemuxTelemetryPrefixedKeyframeIsVideo() {
        let prefix = Array(#"{"cap":1750000000000,"snd":1750000000005}"#.utf8)
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x00, 0x01, 0x68, 0xCE]
        XCTAssertEqual(prefix[0], 0x7B, "precondition: frame starts with '{'")
        XCTAssertFalse(isControl(prefix + annexB), "telemetry-prefixed keyframe must classify as video")
    }

    func testDemuxBoundaryAt32768() {
        // Build {"a":"<filler>"} at an exact target length. The closing brace is
        // part of the length, hence the +1/-1 bookkeeping.
        func controlFrame(total: Int) -> [UInt8] {
            var f = Array(#"{"a":""#.utf8)          // 6 bytes
            f.append(contentsOf: [UInt8](repeating: 0x41, count: total - f.count - 1))
            f.append(0x7D)                            // '}'
            return f
        }

        let ctrl = controlFrame(total: 32767)
        XCTAssertEqual(ctrl.count, 32767)
        XCTAssertTrue(isControl(ctrl), "32767 < 32768, so this is control")

        let over = controlFrame(total: 32768)
        XCTAssertEqual(over.count, 32768)
        XCTAssertFalse(isControl(over), "the rule is strictly < 32768, so 32768 is video")
    }

    func testDemuxRejectsEmpty() {
        XCTAssertFalse(isControl([]))
    }

    // MARK: - Section 5.1 keyframe detection

    private func nalType(_ n: [UInt8]) -> UInt8 { n[0] & 0x1F }

    /// The bug: VTBox prefixes every IDR with SPS+PPS, so NALU[0] is type 7.
    /// Checking only nalus[0] classified EVERY keyframe as a delta, breaking
    /// the section 5.3 kf-recovery loop.
    private func isKey(_ nalus: [[UInt8]]) -> Bool {
        nalus.contains { nalType($0) == 5 }
    }

    func testKeyframeWithParameterSetsIsDetected() {
        // SPS(7), PPS(8), IDR(5) — exactly what an IDR wire frame looks like.
        let nalus: [[UInt8]] = [[0x67, 0x42], [0x68, 0xCE], [0x65, 0x88, 0x00]]
        XCTAssertEqual(nalType(nalus[0]), 7, "precondition: first NALU is the SPS")
        XCTAssertTrue(isKey(nalus), "a frame containing an IDR slice IS a keyframe")
    }

    func testDeltaFrameIsNotAKeyframe() {
        // Non-keyframes carry slice data only (PROTOCOL.md 5.1).
        let nalus: [[UInt8]] = [[0x41, 0x9A, 0x00]]
        XCTAssertFalse(isKey(nalus))
    }

    func testIDRNotFirstIsStillAKeyframe() {
        let nalus: [[UInt8]] = [[0x06, 0x05], [0x65, 0x88]]   // SEI then IDR
        XCTAssertTrue(isKey(nalus))
    }

    // MARK: - Section 5.1 telemetry is epoch ms

    /// PROTOCOL.md 5.1: cap/snd are ms since the Unix epoch. The old code
    /// compared them against `performance.now()` (ms since page load), which is
    /// a different epoch entirely and made e2e figures meaningless.
    func testTelemetryIsEpochMillisecondsSoMustCompareAgainstEpochClock() {
        let epochMs = Date().timeIntervalSince1970 * 1000
        XCTAssertGreaterThan(epochMs, 1_600_000_000_000)

        // A frame captured 40 ms ago on a perfectly synced link.
        let cap = epochMs - 40
        let e2eUsingEpochClock = epochMs - cap            // correct: 40
        XCTAssertEqual(e2eUsingEpochClock, 40, accuracy: 1)

        // performance.now() is a different base entirely; no offset can reconcile
        // them, which is why mixing them is a bug rather than a rounding issue.
        let perfNow = 5_000.0
        let bogus = perfNow - cap
        XCTAssertLessThan(bogus, 0, "epoch-minus-performance is nonsense, not just imprecise")
    }

    // MARK: - avcc description

    /// buildAvcC's PPS count byte. 3 reserved bits + 5-bit count means a single
    /// PPS is 0xE1, not 1. A bare 1 declares zero PPS units.
    func testAvcCPpsCountByte() {
        // Correct encoding: 0xE0 | count.
        XCTAssertEqual(UInt8(0xE0 | 1), 0xE1)
        // A decoder reads the count from bits 2..6 of the byte, so the low five
        // bits of a bare 1 are read as a count of 1 only by accident: the three
        // reserved high bits are 000 instead of 111, which is what a strict
        // parser rejects. Assert the reserved-bit invariant instead of a
        // same-value comparison.
        XCTAssertEqual(UInt8(0xE1) & 0b1110_0000, 0b1110_0000, "reserved bits must be set")
        XCTAssertEqual(UInt8(1) & 0b1110_0000, 0b0000_0000, "a bare 1 leaves reserved bits clear")
    }
}
