import XCTest
@testable import OpenDisplayBridge

/// The avcC record handed to libwebrtc's H.264 decoder (WEBRTC_PLAN.md W2).
///
/// This is the same structure `Web/receiver.js` builds for the browser, and it
/// carries the same trap: the parameter-set counts sit behind reserved bits, so
/// `1` means *zero* parameter sets, not one. That bug shipped in the JS builder
/// and is pinned here so it cannot ship again.
final class AVCCRecordTests: XCTestCase {

    private let sc = Data([0x00, 0x00, 0x00, 0x01])
    private var sps: Data { Data([0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x00]) }
    private var pps: Data { Data([0x68, 0xCE, 0x3C, 0x80]) }

    private func stream() -> AnnexBStream {
        var s = AnnexBStream()
        s.consume(sc + sps + sc + pps + sc + Data([0x65, 0x88]))
        return s
    }

    func testHeaderBytes() throws {
        let rec = try XCTUnwrap(stream().avcCRecord())
        XCTAssertEqual(rec[0], 0x01, "configurationVersion")
        XCTAssertEqual(rec[1], 0x42, "profile_idc copied from the SPS")
        XCTAssertEqual(rec[2], 0xC0, "constraint flags copied from the SPS")
        XCTAssertEqual(rec[3], 0x1E, "level_idc copied from the SPS")
        XCTAssertEqual(rec[4], 0xFF, "6 reserved bits + lengthSizeMinusOne = 3")
    }

    /// THE trap: a bare 1 declares zero parameter sets.
    func testParameterSetCountsSetReservedBits() throws {
        let rec = try XCTUnwrap(stream().avcCRecord())
        XCTAssertEqual(rec[5], 0xE1, "numOfSPS: 3 reserved bits set, then count 1")
        XCTAssertEqual(rec[5] & 0b1110_0000, 0b1110_0000, "reserved bits must be 1s")
        XCTAssertEqual(rec[5] & 0b0001_1111, 1, "count of SPS must be 1")
    }

    func testLengthsAreBigEndianAndPrecedeTheirPayload() throws {
        let rec = try XCTUnwrap(stream().avcCRecord())
        let spsLen = Int(rec[6]) << 8 | Int(rec[7])
        XCTAssertEqual(spsLen, sps.count)
        XCTAssertEqual(Data(rec[8..<(8 + spsLen)]), sps)

        let ppsCountIndex = 8 + spsLen
        XCTAssertEqual(rec[ppsCountIndex], 0xE1, "numOfPPS: 0xE1, not 1")
        let ppsLenIndex = ppsCountIndex + 1
        let ppsLen = Int(rec[ppsLenIndex]) << 8 | Int(rec[ppsLenIndex + 1])
        XCTAssertEqual(ppsLen, pps.count)
        XCTAssertEqual(Data(rec[(ppsLenIndex + 2)...]), pps)
    }

    func testTotalLength() throws {
        let rec = try XCTUnwrap(stream().avcCRecord())
        XCTAssertEqual(rec.count, 8 + sps.count + 3 + pps.count)
    }

    func testNeedsBothParameterSets() {
        var s = AnnexBStream()
        s.consume(sc + sps)
        XCTAssertNil(s.avcCRecord(), "SPS alone is not an avcC record")
        XCTAssertNil(AnnexBStream().avcCRecord())
    }

    /// A too-short SPS cannot yield profile/level bytes.
    func testRejectsTruncatedSPS() {
        var s = AnnexBStream()
        s.consume(sc + Data([0x67, 0x42]) + sc + pps)
        XCTAssertNil(s.avcCRecord(), "need at least 4 SPS bytes for profile/level")
    }

    /// Long parameter sets must not truncate their length fields.
    func testLargeParameterSetLength() throws {
        let bigSPS = Data([0x67, 0x4D, 0x40, 0x1E] + [UInt8](repeating: 0x11, count: 700))
        var s = AnnexBStream()
        s.consume(sc + bigSPS + sc + pps)
        let rec = try XCTUnwrap(s.avcCRecord())
        let spsLen = Int(rec[6]) << 8 | Int(rec[7])
        XCTAssertEqual(spsLen, 704, "needs two length bytes")
    }
}
