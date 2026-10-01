import CoreMedia
import Foundation

/// Splits an OpenDisplay video frame (PROTOCOL.md s.5) into H.264 parameter sets
/// and access units suitable for `VTDecompressionSession`.
///
/// The bridge is a relay, so this is what stands between "H.264 bytes arriving
/// from the sender" and "CVPixelBuffer out to a WebRTC encoder".
///
/// Pure parsing, deliberately separated from VideoToolbox so it can be unit
/// tested on any host — the decoder itself cannot, since hardware decode is
/// unreachable from an unsigned process.
struct AnnexBStream {
    enum NALType: UInt8 {
        case slice = 1
        case idrSlice = 5
        case sei = 6
        case sps = 7
        case pps = 8
    }

    /// Latest parameter sets, keyed by NAL type.
    private(set) var sps: Data?
    private(set) var pps: Data?

    /// True once both parameter sets have been seen, so a format description
    /// can be built.
    var hasParameterSets: Bool { sps != nil && pps != nil }

    /// One access unit. Carried in several shapes because the decoders want
    /// different ones, and keeping the conversions here means the demux stays
    /// the single place that knows the wire format.
    struct AccessUnit {
        /// AVCC: each NALU prefixed with its 4-byte big-endian length. What
        /// VideoToolbox wants — the format description already carries SPS/PPS,
        /// so they are not repeated here.
        var data: Data
        /// Annex B: slices only, as the wire carries them (PROTOCOL.md 5.1).
        var annexB: Data
        /// Annex B prefixed with the most recent SPS and PPS.
        ///
        /// PROTOCOL.md 5.2 puts parameter sets on every IDR, so a receiver
        /// normally sees them often. But a stream joined mid-GOP, or one whose
        /// frames are not all IDRs, has slices with no parameter sets attached,
        /// and a self-contained parser then reports `dsNoParamSets` and decodes
        /// nothing. Prefixing the current parameter sets makes each access unit
        /// independently decodable, which is what the software backend needs.
        /// Only used when both parameter sets are known.
        var annexBWithParameterSets: Data?
        var isKeyframe: Bool
    }

    /// Splits an Annex B buffer into NALUs, each WITHOUT its start code.
    static func nalus(_ data: Data) -> [Data] {
        var out: [Data] = []
        var i = data.startIndex
        let end = data.endIndex
        while i < end {
            // PROTOCOL.md 5.1: start codes are always 4 bytes, so split on the
            // 4-byte pattern only. A 3-byte code would be missed by design.
            if i + 4 <= end,
               data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                var next = end
                var k = i + 4
                while k + 4 <= end {
                    if data[k] == 0, data[k + 1] == 0, data[k + 2] == 0, data[k + 3] == 1 {
                        next = k
                        break
                    }
                    k += 1
                }
                out.append(Data(data[(i + 4)..<next]))
                i = next
            } else {
                i += 1
            }
        }
        return out
    }

    static func type(of nalu: Data) -> UInt8? {
        guard let first = nalu.first else { return nil }
        return first & 0x1F
    }

    /// Feeds one wire frame. Returns an access unit to decode, or nil if the
    /// frame carried nothing decodable (SEI-only, or parameter sets still
    /// incomplete).
    ///
    /// Parameter sets are absorbed as they arrive — PROTOCOL.md 5.1 puts SPS and
    /// PPS on every IDR, which is exactly what makes mid-stream joins and
    /// rotation recoverable.
    mutating func consume(_ frame: Data) -> AccessUnit? {
        let units = Self.nalus(frame)
        guard !units.isEmpty else { return nil }

        var slices: [Data] = []
        var isKey = false

        for unit in units {
            guard let t = Self.type(of: unit) else { continue }
            switch NALType(rawValue: t) {
            case .sps:
                sps = unit
            case .pps:
                pps = unit
            case .idrSlice:
                isKey = true
                slices.append(unit)
            case .slice:
                slices.append(unit)
            case .sei:
                continue   // receivers MAY skip SEI (PROTOCOL.md 5.1)
            default:
                continue
            }
        }

        guard hasParameterSets, !slices.isEmpty else { return nil }
        let annexB = Self.toAnnexB(slices)
        return AccessUnit(
            data: Self.toAVCC(slices),
            annexB: annexB,
            annexBWithParameterSets: Self.toAnnexB([sps, pps].compactMap { $0 } + slices),
            isKeyframe: isKey)
    }

    /// AVCC (4-byte length-prefixed) is what VideoToolbox wants; the wire is
    /// Annex B. The inverse of `AnnexB.avccToAnnexB`.
    static func toAVCC(_ nalus: [Data]) -> Data {
        var out = Data()
        for nalu in nalus {
            let len = UInt32(nalu.count)
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(nalu)
        }
        return out
    }

    /// Annex B, as the wire carries it: a 4-byte start code before each NALU.
    /// The inverse of `AnnexB.annexBToAVCC`.
    static func toAnnexB(_ nalus: [Data]) -> Data {
        var out = Data()
        for nalu in nalus {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(nalu)
        }
        return out
    }

    /// Builds a format description from the current parameter sets. VideoToolbox
    /// needs this to configure the decoder and to size output pixel buffers.
    func makeFormatDescription() -> CMVideoFormatDescription? {
        guard let sps, let pps else { return nil }
        var desc: CMVideoFormatDescription?
        // 4-byte NAL length headers, matching `toAVCC`.
        let status = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                // Swift imports the pointer array as [UnsafePointer<UInt8>].
                var parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                var parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        guard status == noErr else { return nil }
        return desc
    }

    /// Builds the AVCDecoderConfigurationRecord ("avcC") for the current
    /// parameter sets.
    ///
    /// Needed by libwebrtc's H.264 decoder, which takes its configuration as a
    /// codec-specific-info blob rather than a `CMVideoFormatDescription`.
    /// Layout (ISO 14496-15):
    ///
    ///     0       configurationVersion = 1
    ///     1..3    profile / compatibility / level, copied from the SPS
    ///     4       0xFF  (6 reserved bits + lengthSizeMinusOne = 3)
    ///     5       0xE1  (3 reserved bits + numOfSequenceParameterSets = 1)
    ///     6..7    SPS length, big-endian
    ///     ...     SPS
    ///     then the same shape for PPS
    ///
    /// Byte 5 and its PPS twin are `0xE1`, not `1`: the count is 5 bits wide and
    /// sits behind 3 reserved bits, so a bare `1` declares *zero* parameter
    /// sets. `Web/receiver.js` had exactly that bug in its own avcC builder.
    func avcCRecord() -> Data? {
        guard let sps, let pps, sps.count >= 4 else { return nil }
        var out = Data()
        out.append(0x01)                       // configurationVersion
        out.append(sps[sps.startIndex + 1])    // profile_idc
        out.append(sps[sps.startIndex + 2])    // constraint flags
        out.append(sps[sps.startIndex + 3])    // level_idc
        out.append(0xFF)                       // reserved + lengthSizeMinusOne = 3
        out.append(0xE1)                       // reserved + numOfSPS = 1
        out.append(UInt8((sps.count >> 8) & 0xFF))
        out.append(UInt8(sps.count & 0xFF))
        out.append(sps)
        out.append(0xE1)                       // reserved + numOfPPS = 1
        out.append(UInt8((pps.count >> 8) & 0xFF))
        out.append(UInt8(pps.count & 0xFF))
        out.append(pps)
        return out
    }

    /// Display size from the SPS, which PROTOCOL.md 5.2 makes authoritative.
    /// VideoToolbox is the authority here; parsed from the format description
    /// rather than from `hello` or `streamConfig`.
    static func dimensions(_ desc: CMVideoFormatDescription) -> (width: Int, height: Int)? {
        // Returns the struct by value; there is no error code to check.
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return (Int(dimensions.width), Int(dimensions.height))
    }
}
