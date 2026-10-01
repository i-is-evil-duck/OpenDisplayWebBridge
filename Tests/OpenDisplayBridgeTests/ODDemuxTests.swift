import XCTest
@testable import OpenDisplayBridge

/// PROTOCOL.md s.4 demux, applied bridge-side.
///
/// This is load-bearing on the WebRTC path: control messages must keep flowing
/// over the socket while video goes out over WebRTC, or the receiver's liveness
/// watchdog (§8.2) fires and the session reconnects forever.
final class ODDemuxTests: XCTestCase {

    func testControlIsDetected() {
        XCTAssertTrue(ODDemux.isControl(Data(#"{"type":"ping","t":1}"#.utf8)))
        XCTAssertTrue(ODDemux.isControl(Data(#"{"type":"welcome","pv":3,"min":1}"#.utf8)))
    }

    func testVideoIsNotControl() {
        let annexB = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x00])
        XCTAssertFalse(ODDemux.isControl(annexB))
    }

    /// The case the spec calls out: a keyframe with the telemetry prefix starts
    /// with '{' and is still video, saved only by the NUL rule.
    func testTelemetryPrefixedKeyframeIsVideo() {
        var frame = Data(#"{"cap":1750000000000,"snd":1750000000005}"#.utf8)
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        XCTAssertEqual(frame.first, 0x7B, "precondition: starts with '{'")
        XCTAssertFalse(ODDemux.isControl(frame))
    }

    func testBoundaryIsStrictlyBelow32768() {
        // 32767 is control; 32768 is not (the rule is "< 32768").
        let under = Data(#"{"a":""#.utf8) + Data(repeating: 0x41, count: 32767 - 6 - 1) + Data([0x7D])
        XCTAssertEqual(under.count, 32767)
        XCTAssertTrue(ODDemux.isControl(under))

        let at = Data(#"{"a":""#.utf8) + Data(repeating: 0x41, count: 32768 - 6 - 1) + Data([0x7D])
        XCTAssertEqual(at.count, 32768)
        XCTAssertFalse(ODDemux.isControl(at))
    }

    func testEmptyIsNotControl() {
        XCTAssertFalse(ODDemux.isControl(Data()))
    }

    func testNonBraceFirstByteIsNotControl() {
        XCTAssertFalse(ODDemux.isControl(Data("plain text without braces".utf8)))
    }

    func testNulAnywhereDisqualifies() {
        var d = Data(#"{"a":1}"#.utf8)
        d.append(0)
        XCTAssertFalse(ODDemux.isControl(d))
    }

    /// Index-relative, like the rest of the codebase: a `Data` handed in as a
    /// slice must not trap on `first` and must still demux correctly.
    func testWorksOnASlicedBuffer() {
        let json = Data(#"{"type":"ping"}"#.utf8)
        var backing = Data([0xFF, 0xFF])      // prefix the slice must skip
        backing.append(json)
        let slice = backing.suffix(json.count)
        XCTAssertEqual(slice.startIndex, 2, "precondition: a genuinely offset slice")
        XCTAssertTrue(ODDemux.isControl(slice))
    }
}
