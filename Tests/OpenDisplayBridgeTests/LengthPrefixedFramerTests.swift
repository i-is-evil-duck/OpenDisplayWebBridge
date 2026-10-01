import XCTest
@testable import OpenDisplayBridge

/// PROTOCOL.md s.3 framing: `[4-byte big-endian length][payload]`, with no
/// message boundaries from TCP — a frame may arrive split across reads or
/// packed together with others in one read.
final class LengthPrefixedFramerTests: XCTestCase {

    func testRoundTrip() throws {
        var f = LengthPrefixedFramer()
        let payloads = [Data(#"{"type":"hello"}"#.utf8), Data("x".utf8), Data()]
        let wire = payloads.dropLast().reduce(into: Data()) { $0.append(LengthPrefixedFramer.frame($1)) }
        let frames = try f.append(wire)
        XCTAssertEqual(frames, [payloads[0], payloads[1]])
    }

    /// A frame split across reads must be buffered, not parsed from a partial
    /// header or body.
    func testFrameSplitAcrossReads() throws {
        var f = LengthPrefixedFramer()
        let payload = Data("hello world".utf8)
        let wire = LengthPrefixedFramer.frame(payload)

        for byte in wire.dropLast() {
            XCTAssertTrue(try f.append(Data([byte])).isEmpty, "must not emit a partial frame")
        }
        XCTAssertEqual(try f.append(Data(wire.suffix(1))), [payload])
    }

    /// The regression this framer is written to avoid: two frames in one read
    /// leave the buffer sliced with a non-zero startIndex after the first
    /// removeFirst. Indexing that as 0-based traps.
    func testTwoFramesInOneRead() throws {
        var f = LengthPrefixedFramer()
        let a = Data(#"{"type":"ping","t":1}"#.utf8)
        let b = Data(String(repeating: "v", count: 5000).utf8)   // video-ish size
        var wire = LengthPrefixedFramer.frame(a)
        wire.append(LengthPrefixedFramer.frame(b))
        XCTAssertEqual(try f.append(wire), [a, b])
    }

    func testThreeFramesCoalescedThenSplitMidSecond() throws {
        var f = LengthPrefixedFramer()
        let frames = (0..<3).map { Data(String(repeating: "\($0)", count: 100 + $0).utf8) }
        var wire = Data()
        frames.forEach { wire.append(LengthPrefixedFramer.frame($0)) }
        let split = wire.count - 10
        XCTAssertEqual(try f.append(Data(wire.prefix(split))).count, 2)
        XCTAssertEqual(try f.append(Data(wire.suffix(from: split))), [frames[2]])
    }

    func testHeaderOnlyYieldsNothing() throws {
        var f = LengthPrefixedFramer()
        XCTAssertTrue(try f.append(Data([0, 0, 0])).isEmpty, "3 bytes is not a header")
    }

    /// Length 0 is illegal (PROTOCOL.md s.3: payloads are 1..2^20-1), and an
    /// absurd length must not be trusted into a huge allocation.
    func testRejectsZeroLength() {
        var f = LengthPrefixedFramer()
        XCTAssertThrowsError(try f.append(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? LengthPrefixedFramer.DeframeError,
                           .badLength(0))
        }
    }

    func testRejectsOversizedLength() {
        var f = LengthPrefixedFramer(maxFrameBytes: 1024)
        // Claims 0xFFFFFFFF bytes.
        XCTAssertThrowsError(try f.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? LengthPrefixedFramer.DeframeError,
                           .badLength(0xFFFF_FFFF))
        }
    }

    func testLengthIsBigEndian() {
        let wire = LengthPrefixedFramer.frame(Data(repeating: 0x41, count: 0x0102))
        XCTAssertEqual(Array(wire.prefix(4)), [0x00, 0x00, 0x01, 0x02],
                       "length must be big-endian, not little")
    }

    /// Big-endian matters: 0x0102 == 258 little-endian would be 256 frames off.
    func testMultiByteLengthIsCorrect() throws {
        var f = LengthPrefixedFramer()
        let payload = Data(repeating: 0x42, count: 258)
        XCTAssertEqual(try f.append(LengthPrefixedFramer.frame(payload)), [payload])
    }
}
