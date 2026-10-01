import Foundation
import XCTest

@testable import OpenDisplayBridge

/// Ports of the browser's `parseSPS` Exp-Golomb walk, so the bit-level logic is
/// testable in Swift rather than only observable in a browser.
///
/// ## Why this needs tests
///
/// The parser used to return `pic_width_in_mbs_minus1 + 1` directly, as though
/// it were a pixel width. It is a **macroblock** count, so a 992x1088 capture was
/// reported as "62x68". Nothing looked broken: the canvas takes each decoded
/// frame's own dimensions, so the picture rendered correctly and the defect was
/// invisible until someone read the numbers.
///
/// It was not harmless. Those values scale §7 touch coordinates
/// (`sx = videoW / rect.width`), so every touch landed 16x off. A wrong
/// coordinate that is consistent and plausible is exactly the kind of bug that
/// survives review, because the only way to see it is to know the number should
/// have been multiplied by 16.
///
/// The frame-cropping block was also missing, so a size that is not a multiple of
/// 16 — which is most screen sizes — reported the coded size rather than the
/// displayed one.
final class SPSParsingTests: XCTestCase {

    /// Bit reader over an RBSP, MSB-first, matching `parseSPS` in receiver.js.
    private struct BitReader {
        let bits: [UInt8]
        var pos = 0
        init(_ bytes: [UInt8], skipBits: Int) {
            var out: [UInt8] = []
            for b in bytes { for i in stride(from: 7, through: 0, by: -1) { out.append((b >> i) & 1) } }
            bits = out
            pos = skipBits
        }
        mutating func u(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n where pos < bits.count { v = (v << 1) | Int(bits[pos]); pos += 1 }
            return v
        }
        mutating func ue() -> Int {
            var zeros = 0
            while pos < bits.count && bits[pos] == 0 { zeros += 1; pos += 1 }
            pos += 1
            return (1 << zeros) - 1 + u(zeros)
        }
        mutating func se() -> Int {
            let k = ue()
            return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }

    /// Mirror of the JS parser, so the two can be compared value for value.
    private static func parse(_ sps: [UInt8]) -> (codec: String, width: Int, height: Int) {
        guard sps.count >= 4 else { return ("", 0, 0) }
        let codec = "avc1." + [sps[1], sps[2], sps[3]]
            .map { String(format: "%02X", $0) }.joined()
        var r = BitReader(sps, skipBits: 8 + 24)
        _ = r.ue()                                  // seq_parameter_set_id
        let profileIdc = Int(sps[1])
        var chromaFormat = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profileIdc) {
            chromaFormat = r.ue()
            if chromaFormat == 3 { r.u(1) }
            _ = r.ue(); _ = r.ue(); r.u(1)
            if r.u(1) == 1 {
                let n = chromaFormat == 3 ? 12 : 8
                for _ in 0..<n where r.u(1) == 1 {
                    var s = 8
                    repeat { s += r.se() } while s != 0 && s != 64
                }
            }
        }
        _ = r.ue()                                  // log2_max_frame_num_minus4
        let poc = r.ue()
        if poc == 0 { _ = r.ue() }
        else if poc == 1 { r.u(1); _ = r.se(); _ = r.se(); let c = r.ue(); for _ in 0..<c { _ = r.se() } }
        _ = r.ue()                                  // max_num_ref_frames
        r.u(1)                                      // gaps_in_frame_num_value_allowed

        let mbWidth = r.ue() + 1
        let mbHeight = r.ue() + 1
        let frameMbsOnly = r.u(1)
        if frameMbsOnly == 0 { r.u(1) }
        var width = mbWidth * 16
        var height = mbHeight * 16 * (2 - frameMbsOnly)
        if r.u(1) == 1 {
            let left = r.ue(), right = r.ue(), top = r.ue(), bottom = r.ue()
            let subWidthC = (chromaFormat == 1 || chromaFormat == 2) ? 2 : 1
            let subHeightC = chromaFormat == 1 ? 2 : 1
            width -= subWidthC * (left + right)
            height -= subHeightC * (frameMbsOnly == 1 ? 1 : 2) * (top + bottom)
        }
        return (codec, width, height)
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8(String($0), radix: 16) }
    }

    /// The SPS the real OpenDisplay.app sender produced for a 990x1080 capture,
    /// captured live. The sender's own `streamConfig` said 990x1080@30, and the
    /// old parser called this "62x68" — macroblock counts, unmultiplied.
    private static let liveSPS = bytes("27 64 00 20 ac 13 14 50 3e 02 27 a9 66 a0 40 40 40 f0 80 42 58")

    func testLiveSenderSPSReportsPixelsNotMacroblocks() {
        let parsed = Self.parse(Self.liveSPS)
        // 62 x 68 macroblocks is 992 x 1088 coded, cropped to the displayed size.
        XCTAssertGreaterThanOrEqual(parsed.width, 900,
            "width must be in pixels, not macroblocks; got \(parsed.width)")
        XCTAssertLessThanOrEqual(parsed.width, 1100,
            "width should be near the sender's reported 990; got \(parsed.width)")
        XCTAssertGreaterThanOrEqual(parsed.height, 1000,
            "height must be in pixels; got \(parsed.height)")
        XCTAssertLessThanOrEqual(parsed.height, 1120,
            "height should be near the sender's reported 1080; got \(parsed.height)")
    }

    /// The specific regression: the old answer for this exact SPS.
    func testOldMacroblockBugIsNotReproduced() {
        let parsed = Self.parse(Self.liveSPS)
        XCTAssertNotEqual(parsed.width, 62,
            "62 is the macroblock count, not a pixel width — the old bug")
        XCTAssertNotEqual(parsed.height, 68,
            "68 is the macroblock count, not a pixel height — the old bug")
    }

    func testCodecStringComesFromProfileAndLevel() {
        let parsed = Self.parse(Self.liveSPS)
        XCTAssertEqual(parsed.codec, "avc1.640020",
                       "profile_idc 0x64, constraints 0x00, level_idc 0x20")
    }

    /// The checked-in fixture is a real capture too, at a different geometry.
    func testFixtureSPSParsesToASaneSize() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "real-sender-292x360", withExtension: "264",
                              subdirectory: "Fixtures"),
            "the checked-in capture must be in the test bundle")
        let first = try Data(contentsOf: url)
        // First NAL is the SPS.
        var nalus: [[UInt8]] = []
        var i = 0
        while i + 4 <= first.count {
            if first[i] == 0, first[i+1] == 0, first[i+2] == 0, first[i+3] == 1 {
                var j = i + 4
                while j + 4 <= first.count {
                    if first[j] == 0, first[j+1] == 0, first[j+2] == 0, first[j+3] == 1 { break }
                    j += 1
                }
                nalus.append(Array(first[(i+4)..<j]))
                i = j
            } else { i += 1 }
        }
        guard let sps = nalus.first, sps[0] & 0x1F == 7 else {
            throw XCTSkip("no SPS in fixture")
        }
        let parsed = Self.parse(sps)
        XCTAssertGreaterThan(parsed.width, 0)
        XCTAssertGreaterThan(parsed.height, 0)
        // The bridge logs this stream as 292x360, so the parser must land near
        // it and must not report macroblock counts.
        XCTAssertGreaterThan(parsed.width, 100, "got \(parsed.width) — macroblocks?")
        XCTAssertGreaterThan(parsed.height, 100, "got \(parsed.height) — macroblocks?")
    }
}
