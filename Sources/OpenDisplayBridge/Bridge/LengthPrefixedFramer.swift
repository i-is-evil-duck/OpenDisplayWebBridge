import Foundation

/// Deframer for the official OpenDisplay wire format: every message in both
/// directions is `[4-byte big-endian length][payload]` (PROTOCOL.md s.3).
///
/// The WebSocket binding elides the length prefix because message boundaries
/// replace stream framing, so this is the piece that puts the prefix back on
/// for the browser and strips it off for the browser.
struct LengthPrefixedFramer {
    enum DeframeError: Error, CustomStringConvertible, Equatable {
        case badLength(Int)
        var description: String {
            switch self {
            case .badLength(let n): return "illegal frame length \(n)"
            }
        }
    }

    static let headerBytes = 4

    /// PROTOCOL.md s.3: receiver->sender payloads are 1..2^20-1. Sender->receiver
    /// has no hard maximum but "video frames SHOULD stay in the low megabytes",
    /// so cap generously rather than not at all.
    let maxFrameBytes: Int

    private var buffer = Data()

    init(maxFrameBytes: Int = 16 * 1024 * 1024) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Feeds bytes in and returns every complete frame now available. A frame
    /// split across reads is buffered until the rest arrives.
    ///
    /// Indexing is relative to `startIndex` throughout: `removeFirst` leaves the
    /// Data sliced with a non-zero start index, and treating that as 0-based
    /// traps (the bug that killed the WebSocket read loop).
    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while true {
            let base = buffer.startIndex
            guard buffer.count >= Self.headerBytes else { break }
            let length = (Int(buffer[base]) << 24)
                        | (Int(buffer[base + 1]) << 16)
                        | (Int(buffer[base + 2]) << 8)
                        |  Int(buffer[base + 3])
            guard length > 0, length <= maxFrameBytes else {
                throw DeframeError.badLength(length)
            }
            guard buffer.count >= Self.headerBytes + length else { break }
            frames.append(buffer.subdata(in: (base + Self.headerBytes)..<(base + Self.headerBytes + length)))
            buffer.removeFirst(Self.headerBytes + length)
        }
        return frames
    }

    /// Prefixes a payload for the wire. This is the inverse of `append`.
    static func frame(_ payload: Data) -> Data {
        var out = Data()
        let n = UInt32(payload.count)
        out.append(UInt8((n >> 24) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))
        out.append(payload)
        return out
    }
}
