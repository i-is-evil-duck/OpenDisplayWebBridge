import Foundation

/// The sender half of the seam, paired with `ODTransport`.
///
/// `Bridge` owns exactly one pipeline at a time and drives its whole lifetime:
/// `attach` when a receiver is adopted, `detach` when it is replaced or dropped.
/// `DemoSender` is the reference implementation; the real OpenDisplay sender
/// session conforms here in its place.
protocol SenderPipeline: AnyObject {
    /// A transport is now live. Wire up `onFrame` / `onClose` and start sending.
    func attach(_ transport: ODTransport)
    /// Tear down every task, timer and encoder. Must be idempotent.
    func detach()
}

/// Annex B helpers shared by any H.264 sender implementation.
enum AnnexB {
    static let startCode = Data([0x00, 0x00, 0x00, 0x01])
    static let nalHeaderLength = 4   // avcC nalUnitHeaderLength used by VideoToolbox

    /// Splits an Annex B buffer into NALUs (each without its start code).
    static func nalus(_ data: Data) -> [Data] {
        var out: [Data] = []
        var i = 0
        while i + 4 <= data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                let j = i + 4
                var next = data.count
                var k = j
                while k + 4 <= data.count {
                    if data[k] == 0, data[k + 1] == 0, data[k + 2] == 0, data[k + 3] == 1 { next = k; break }
                    k += 1
                }
                out.append(data.subdata(in: j..<next))
                i = next
            } else {
                i += 1
            }
        }
        return out
    }

    static func nalType(_ nalu: Data) -> UInt8 { nalu.isEmpty ? 0 : nalu[0] & 0x1F }

    /// Converts an AVCC (length-prefixed) buffer from VideoToolbox into Annex B.
    static func avccToAnnexB(_ data: Data) -> Data {
        var out = Data()
        var i = 0
        while i + nalHeaderLength <= data.count {
            var len = 0
            for b in data[i..<(i + nalHeaderLength)] { len = (len << 8) | Int(b) }
            i += nalHeaderLength
            guard len > 0, i + len <= data.count else { break }
            out.append(startCode)
            out.append(data.subdata(in: i..<(i + len)))
            i += len
        }
        return out
    }
}
