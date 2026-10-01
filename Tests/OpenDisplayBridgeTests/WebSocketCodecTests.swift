import XCTest
@testable import OpenDisplayBridge

/// Regression tests for bugs that shipped in the scaffold and were only
/// reachable at runtime. Each one corresponds to a real crash or silent
/// failure, so keep them: they are cheap and they are the reason `swift test`
/// is now part of the loop.
final class WebSocketCodecTests: XCTestCase {

    /// Builds a client->server frame: always masked, per RFC 6455 5.3.
    private func clientFrame(opcode: UInt8, payload: Data,
                             mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]) -> Data {
        var f = Data()
        f.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            f.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            f.append(0x80 | 126)
            f.append(UInt8(n >> 8))
            f.append(UInt8(n & 0xFF))
        } else {
            f.append(0x80 | 127)
            for i in (0..<8).reversed() {
                f.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF))
            }
        }
        f.append(contentsOf: mask)
        for (i, b) in payload.enumerated() { f.append(b ^ mask[i % 4]) }
        return f
    }

    /// THE regression test. Two frames delivered in one TCP read left the
    /// buffer with a non-zero `startIndex` after the first `removeFirst`, and
    /// the old 0-based indexing trapped on `buffer[0]` — SIGTRAP, process
    /// dead. Any browser sending hello + ping back-to-back hit it.
    func testCoalescedFramesInOneBuffer() throws {
        let a = clientFrame(opcode: 0x2, payload: Data(#"{"type":"hello"}"#.utf8))
        let b = clientFrame(opcode: 0x2, payload: Data(#"{"type":"ping","t":1}"#.utf8))
        var buffer = a + b

        let first = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(String(decoding: first.payload, as: UTF8.self), #"{"type":"hello"}"#)
        XCTAssertGreaterThan(buffer.startIndex, 0, "expected a sliced buffer after consuming a frame")

        // Would trap before the fix.
        let second = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(String(decoding: second.payload, as: UTF8.self), #"{"type":"ping","t":1}"#)
        XCTAssertEqual(buffer.count, 0)
    }

    /// Same hazard, but the frames arrive in separate reads and the buffer is
    /// appended to in between.
    func testFramesAcrossSeparateReads() throws {
        let a = clientFrame(opcode: 0x2, payload: Data("first".utf8))
        let b = clientFrame(opcode: 0x2, payload: Data("second".utf8))

        var buffer = Data()
        buffer.append(a)
        let first = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(String(decoding: first.payload, as: UTF8.self), "first")

        buffer.append(b)
        let second = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(String(decoding: second.payload, as: UTF8.self), "second")
    }

    /// A frame split across two reads must not be parsed from a partial buffer.
    func testPartialFrameIsDeferred() throws {
        let f = clientFrame(opcode: 0x2, payload: Data("hello world".utf8))
        var buffer = Data(f.prefix(6))
        XCTAssertNil(try WebSocketCodec.consume(from: &buffer), "partial frame must wait for more bytes")

        buffer.append(Data(f.suffix(from: 6)))
        let frame = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "hello world")
    }

    /// Masking must be undone, or payloads arrive as ciphertext.
    func testMaskingIsUndone() throws {
        let payload = Data(#"{"type":"hello","pixelsWide":1170}"#.utf8)
        var buffer = clientFrame(opcode: 0x2, payload: payload, mask: [0xDE, 0xAD, 0xBE, 0xEF])
        let frame = try XCTUnwrap(WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(frame.payload, payload)
    }

    /// 126/127 extended length encodings.
    func testExtendedLengthEncodings() throws {
        for size in [126, 300, 70_000] {
            let payload = Data(repeating: 0x41, count: size)
            var buffer = clientFrame(opcode: 0x2, payload: payload)
            let frame = try XCTUnwrap(WebSocketCodec.consume(from: &buffer), "size \(size)")
            XCTAssertEqual(frame.payload.count, size)
            XCTAssertEqual(frame.payload, payload, "size \(size)")
        }
    }

    /// RFC 6455 5.3: a client MUST mask. Unmasked frames are a protocol error.
    func testUnmaskedClientFrameIsRejected() {
        var buffer = Data([0x82, 0x03, 0x61, 0x62, 0x63])   // binary, len 3, no mask
        XCTAssertThrowsError(try WebSocketCodec.consume(from: &buffer)) { error in
            XCTAssertEqual(error as? WebSocketError, .protocolError)
        }
    }

    /// The 4 MB cap from the binding rules.
    func testOversizedFrameIsRejected() {
        var f = Data([0x82, 0xFF])
        f.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])   // 2^64-1
        var buffer = f
        XCTAssertThrowsError(try WebSocketCodec.consume(from: &buffer)) { error in
            XCTAssertEqual(error as? WebSocketError, .frameTooLarge)
        }
    }

    /// Server frames are never masked, and must round-trip at 127-byte length.
    func testBuildRoundTrip() {
        for size in [0, 125, 126, 65_535, 65_536] {
            let payload = Data(repeating: 0x5A, count: size)
            let built = WebSocketCodec.build(fin: true, opcode: 0x2, payload: payload)
            XCTAssertEqual(built.count, size + headerLength(for: size), "size \(size)")
            // Server frames are unmasked, so decode by hand.
            XCTAssertEqual(built[1] & 0x80, 0, "server frames must not be masked")
        }
    }

    private func headerLength(for payloadSize: Int) -> Int {
        if payloadSize <= 125 { return 2 }
        if payloadSize <= 65_535 { return 4 }
        return 10
    }

    /// The handshake accept key is fixed by RFC 6455 1.3.
    func testHandshakeAcceptKey() {
        XCTAssertEqual(WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
                       "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    // MARK: - RFC 6455 5.2 / 5.5

    /// Builds a client frame with explicit RSV bits, so the extension check can
    /// be exercised without disturbing anything else about the frame.
    private func clientFrameWithRSV(rsv: UInt8, opcode: UInt8,
                                    payload: Data = Data([0x01])) -> Data {
        var f = Data()
        f.append(0x80 | (rsv << 4) | opcode)   // 0x40 RSV1, 0x20 RSV2, 0x10 RSV3
        f.append(0x80 | UInt8(payload.count))  // masked, 7-bit length
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        f.append(contentsOf: mask)
        for (i, b) in payload.enumerated() { f.append(b ^ mask[i % 4]) }
        return f
    }

    /// RSV1 is the bit permessage-deflate sets, and this server negotiates no
    /// extension at all — it declines by omission. So an RSV bit set means the
    /// client believes a compression extension is in force when it is not, and
    /// the payload is compressed data that this server would read as raw H.264.
    ///
    /// That is the dangerous shape of the bug: not a rejected connection, but
    /// silently mis-decoded video, which then looks like a sender fault.
    func testReservedBitsAreRejected() {
        for rsv in [0b100, 0b010, 0b001, 0b111] {
            var buffer = clientFrameWithRSV(rsv: UInt8(rsv), opcode: 0x2)
            XCTAssertThrowsError(try WebSocketCodec.consume(from: &buffer),
                                 "RSV bits \(String(rsv, radix: 2)) must be refused") { error in
                XCTAssertEqual(error as? WebSocketError, .protocolError)
            }
        }
    }

    /// RSV clear is the normal case and must keep working, or the check above is
    /// simply "reject everything".
    func testClearReservedBitsAreAccepted() throws {
        var buffer = clientFrameWithRSV(rsv: 0, opcode: 0x2)
        let frame = try XCTUnwrap(try WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(frame.opcode, 0x2)
        XCTAssertEqual(frame.payload, Data([0x01]))
    }

    /// RFC 6455 5.5: a control frame must be unfragmented and at most 125 bytes.
    ///
    /// `WebSocketConnection` answers a ping inline from whatever payload arrived,
    /// so an oversized control frame would be acted on twice — once per fragment
    /// — and a 200-byte "ping" is a protocol error, not a large ping.
    func testOversizedControlFrameIsRejected() {
        // 126-byte ping: over the 125-byte limit, and the length needs the 16-bit
        // form. Masked, per RFC 6455 5.3.
        var f = Data()
        f.append(0x80 | 0x9)                    // FIN + ping
        f.append(0x80 | 126)
        f.append(UInt8(126 >> 8))
        f.append(UInt8(126 & 0xFF))
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        f.append(contentsOf: mask)
        for i in 0..<126 { f.append(UInt8(i & 0xFF) ^ mask[i % 4]) }

        var buffer = f
        XCTAssertThrowsError(try WebSocketCodec.consume(from: &buffer)) { error in
            XCTAssertEqual(error as? WebSocketError, .protocolError)
        }
    }

    /// A fragmented control frame is the same error by a different route, and is
    /// the one that actually double-fires the handler.
    func testFragmentedControlFrameIsRejected() {
        var f = Data()
        f.append(0x00 | 0x9)                    // FIN clear + ping
        f.append(0x80 | 0)                      // masked, zero length
        f.append(contentsOf: [0x12, 0x34, 0x56, 0x78])

        var buffer = f
        XCTAssertThrowsError(try WebSocketCodec.consume(from: &buffer)) { error in
            XCTAssertEqual(error as? WebSocketError, .protocolError)
        }
    }

    /// A control frame at exactly 125 bytes is the boundary and must be allowed,
    /// so the limit is a limit and not "reject all control frames".
    func testMaximumSizedControlFrameIsAccepted() throws {
        var buffer = clientFrame(opcode: 0x9, payload: Data(repeating: 0x5A, count: 125))
        let frame = try XCTUnwrap(try WebSocketCodec.consume(from: &buffer))
        XCTAssertEqual(frame.opcode, 0x9)
        XCTAssertEqual(frame.payload.count, 125)
    }
}
