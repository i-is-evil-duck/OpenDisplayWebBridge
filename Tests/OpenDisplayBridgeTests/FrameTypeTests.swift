import XCTest
@testable import OpenDisplayBridge

/// The binding is binary-only. These pin the rule that a receiver->sender
/// control message must travel as a BINARY frame, because the scaffold's
/// `receiver.js` used `ws.send(string)` — a TEXT frame — and the server
/// silently discarded every one of them. The receiver then sat in a
/// connect/watchdog/reconnect loop with a live cookie and no visible error.
///
/// A test cannot drive a real browser, so this covers the Swift half (the
/// server's accept/reject decision) and documents the JS half. The end-to-end
/// check for the JS side is `tools/smoke-test.sh`, which must be run against a
/// real browser session, not just websocat.
final class FrameTypeTests: XCTestCase {

    /// A frame the server accepts as an OD control message.
    private func binaryControlFrame(_ json: String) -> Data {
        var payload = Array(json.utf8)
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var f = Data([0x82, 0x80 | UInt8(payload.count)])   // FIN + binary, masked
        f.append(contentsOf: mask)
        for (i, b) in payload.enumerated() { f.append(b ^ mask[i % 4]) }
        return f
    }

    /// The same payload as a TEXT frame (opcode 0x1) — what `ws.send(string)`
    /// produces.
    private func textControlFrame(_ json: String) -> Data {
        var f = binaryControlFrame(json)
        f[0] = 0x81                                     // FIN + text
        return f
    }

    func testBinaryFrameCarriesControlMessage() throws {
        var buffer = binaryControlFrame(#"{"type":"hello","pv":3}"#)
        let frame = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(frame.opcode, 0x2, "control messages must travel as binary")
        let msg = try XCTUnwrap(ODControl.parse(frame.payload))
        XCTAssertEqual(msg["type"] as? String, "hello")
    }

    /// The decoder does not reject text frames — the TRANSPORT drops them.
    /// This test documents that the drop happens in WebSocketTransport, which
    /// is the only place that knows about the binding's binary-only rule.
    func testTextFrameIsDecodedButMustBeDroppedByTransport() throws {
        var buffer = textControlFrame(#"{"type":"hello"}"#)
        let frame = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(frame.opcode, 0x1)

        // Mirror the transport's dispatch rule.
        let delivered: Data?
        switch frame.opcode {
        case 0x2: delivered = frame.payload          // binary: delivered
        default:  delivered = nil                    // text/other: dropped
        }
        XCTAssertNil(delivered, "text frames must not reach the pipeline")
    }

    /// Guard the actual dispatch in WebSocketTransport via the Bridge seam.
    func testTransportDropsTextFrames() {
        var built: [RecordingPipeline] = []
        let bridge = Bridge {
            let p = RecordingPipeline(); built.append(p); return p
        }
        let conn = FakeConnection()
        bridge.adoptPairedConnection(conn)

        let hello = Data(#"{"type":"hello","pixelsWide":1170}"#.utf8)
        conn.emit(.binary(hello))
        conn.emit(.text(#"{"type":"hello","pixelsWide":1170}"#))

        XCTAssertEqual(built[0].receivedFrames, [hello],
                       "only the binary frame may reach the pipeline")
    }
}
