import CryptoKit
import Foundation

enum WebSocketError: Error { case frameTooLarge, protocolError }

enum WebSocketHandshake {
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptKey(for clientKey: String) -> String {
        let sha1 = Insecure.SHA1.hash(data: Data((clientKey + magicGUID).utf8))
        return Data(sha1).base64EncodedString()
    }
}

/// RFC 6455 frame codec. Server -> client frames are sent unmasked; client ->
/// server frames MUST be masked (enforced on read).
struct WebSocketFrame {
    var fin: Bool
    var opcode: UInt8      // 0 continuation, 1 text, 2 binary, 8 close, 9 ping, 10 pong
    var payload: Data
}

enum WebSocketCodec {
    static let maxMessageBytes = 4 * 1024 * 1024   // video frames stay in the low MB (PROTOCOL.md §3)

    /// Attempts to consume exactly one frame from `buffer`. Returns nil if more bytes are needed.
    ///
    /// All indexing is relative to `buffer.startIndex`, never to 0. `Data` is
    /// copy-on-write, and slicing operations — notably the `removeFirst` below,
    /// which advances past a consumed frame — leave the result with a NON-ZERO
    /// startIndex. Indexing such a buffer as if it were 0-based traps: the read
    /// loop hands the same buffer back here for every frame in a TCP segment,
    /// so a single read carrying two frames killed the process with SIGTRAP in
    /// `Data.subscript`. Any browser that sends hello + ping back-to-back hits
    /// this, so it is not a theoretical concern.
    static func consume(from buffer: inout Data) throws -> WebSocketFrame? {
        let base = buffer.startIndex
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[base], b1 = buffer[base + 1]
        let fin = b0 & 0x80 != 0
        let opcode = b0 & 0x0F
        let masked = b1 & 0x80 != 0
        var length = UInt64(b1 & 0x7F)
        var offset = 2

        // RFC 6455 5.2: the RSV bits must be 0 unless an extension that defines
        // their meaning has been negotiated. This server negotiates none —
        // permessage-deflate is declined by omission, deliberately — so any RSV
        // bit set is a protocol error. Without this check a client could send
        // RSV1 frames that this server silently misreads as ordinary binary
        // video, and the resulting corruption would look like a sender fault.
        guard b0 & 0x70 == 0 else { throw WebSocketError.protocolError }

        // RFC 6455 5.5: control frames carry at most 125 bytes and must not be
        // fragmented. Both matter because a control frame is acted on inline
        // (`WebSocketConnection` answers a ping immediately), so an oversized or
        // fragmented one would be processed on a partial payload and again on the
        // continuation.
        if opcode & 0x08 != 0 {
            guard fin, length <= 125 else { throw WebSocketError.protocolError }
        }

        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = UInt64(buffer[base + offset]) << 8 | UInt64(buffer[base + offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 { len = (len << 8) | UInt64(buffer[base + offset + i]) }
            length = len
            offset += 8
        }
        guard length <= maxMessageBytes else { throw WebSocketError.frameTooLarge }

        var maskKey = Data()
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = buffer.subdata(in: (base + offset)..<(base + offset + 4))
            offset += 4
        } else {
            // A client sending unmasked frames is a protocol error per RFC 6455 5.3.
            throw WebSocketError.protocolError
        }

        guard buffer.count >= offset + Int(length) else { return nil }
        var payload = buffer.subdata(in: (base + offset)..<(base + offset + Int(length)))
        // k is a COUNT of elements from the front, so `base` must NOT be added:
        // removeFirst already drops from startIndex. The reads above are the
        // part that needed to be startIndex-relative.
        buffer.removeFirst(offset + Int(length))

        if !maskKey.isEmpty {
            for i in payload.indices { payload[i] ^= maskKey[i % 4] }
        }
        return WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }

    /// Builds a server-side (unmasked) frame.
    static func build(fin: Bool, opcode: UInt8, payload: Data) -> Data {
        var out = Data()
        out.append((fin ? 0x80 : 0x00) | opcode)
        switch payload.count {
        case 0...125:
            out.append(UInt8(payload.count))
        case 126...65_535:
            out.append(126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            for i in (0..<8).reversed() {
                out.append(UInt8((UInt64(payload.count) >> (UInt64(i) * 8)) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }
}
