import Foundation

/// Relabels an HDR H.264 / HEVC stream as Rec. 709 without touching a coded picture.
///
/// - The SPS colour description (primaries, transfer, matrix) is overwritten with 1/1/1,
///   in `hvcC` / `avcC` and in-band. An SPS that declares no colour description stays
///   as it is; the container's `colr` box is then all that describes the colour.
/// - SEI NAL units (mastering display, content light level, HDR10+) and the Dolby Vision
///   RPU and enhancement layer NAL units are dropped.
///
/// The pixels are unchanged, so PQ / HLG video looks washed out. Each packet is rewritten
/// on its own, so restarted runs still produce byte-identical segments.
///
/// FFmpeg's `hevc_metadata` and `filter_units` do the same, but the FFmpegBuild slim
/// build has no such bitstream filters.
struct SDRBitstreamRewriter: Sendable {
    let codec: VideoCodec
    /// The source `hvcC` / `avcC` with the same rewrite applied.
    let extradata: [UInt8]
    private let lengthSize: Int

    /// Fails unless `extradata` is an `hvcC` / `avcC` record, which also means packets
    /// are length-prefixed.
    init?(codec: VideoCodec, extradata: [UInt8]) {
        self.codec = codec
        let rewritten = switch codec {
        case .hevc: Self.rewriteHVCC(extradata)
        case .h264: Self.rewriteAVCC(extradata)
        }
        guard let rewritten else { return nil }
        self.extradata = rewritten.record
        self.lengthSize = rewritten.lengthSize
    }

    /// The packet's new bytes, or nil if it needs no change or cannot be parsed.
    func rewrite(_ packet: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        var out: [UInt8]?
        var offset = 0
        while offset < packet.count {
            guard offset + lengthSize <= packet.count else { return nil }
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(packet[offset + i]) }
            let start = offset + lengthSize
            guard length <= packet.count - start else { return nil }
            let nal = UnsafeBufferPointer(rebasing: packet[start..<start + length])

            if length > 0, Self.isDropped(nal[0], codec: codec) {
                if out == nil { out = Array(packet[0..<offset]) }
            } else if length > 0, Self.isSPS(nal[0], codec: codec) {
                let original = Array(nal)
                let sps = Self.rewriteSPS(original, codec: codec)
                if sps != original, out == nil { out = Array(packet[0..<offset]) }
                if out != nil {
                    for i in (0..<lengthSize).reversed() { out!.append(UInt8(truncatingIfNeeded: sps.count >> (8 * i))) }
                    out!.append(contentsOf: sps)
                }
            } else if out != nil {
                out!.append(contentsOf: packet[offset..<start + length])
            }
            offset = start + length
        }
        guard let out, !out.isEmpty else { return nil }
        return out
    }

    // MARK: NAL types

    private static func isSPS(_ header: UInt8, codec: VideoCodec) -> Bool {
        switch codec {
        case .hevc: (header >> 1) & 0x3F == 33
        case .h264: header & 0x1F == 7
        }
    }

    private static func isDropped(_ header: UInt8, codec: VideoCodec) -> Bool {
        switch codec {
        // Prefix and suffix SEI, Dolby Vision RPU and enhancement layer.
        case .hevc: [39, 40, 62, 63].contains((header >> 1) & 0x3F)
        case .h264: header & 0x1F == 6
        }
    }

    // MARK: Decoder configuration records

    private static func rewriteHVCC(_ x: [UInt8]) -> (record: [UInt8], lengthSize: Int)? {
        guard x.count >= 23, x[0] == 1 else { return nil }
        var out = Array(x[0..<23])
        var offset = 23
        var arrays: UInt8 = 0
        for _ in 0..<x[22] {
            guard offset + 3 <= x.count else { return nil }
            let header = x[offset]
            let count = Int(x[offset + 1]) << 8 | Int(x[offset + 2])
            let type = header & 0x3F
            let dropped = [39, 40, 62, 63].contains(type)
            offset += 3
            if !dropped {
                out.append(contentsOf: x[offset - 3..<offset])
                arrays += 1
            }
            for _ in 0..<count {
                guard offset + 2 <= x.count else { return nil }
                let length = Int(x[offset]) << 8 | Int(x[offset + 1])
                offset += 2
                guard offset + length <= x.count else { return nil }
                let nal = Array(x[offset..<offset + length])
                offset += length
                guard !dropped else { continue }
                let rewritten = type == 33 ? rewriteSPS(nal, codec: .hevc) : nal
                out.append(UInt8(rewritten.count >> 8))
                out.append(UInt8(truncatingIfNeeded: rewritten.count))
                out.append(contentsOf: rewritten)
            }
        }
        out[22] = arrays
        return (out, Int(x[21] & 3) + 1)
    }

    private static func rewriteAVCC(_ x: [UInt8]) -> (record: [UInt8], lengthSize: Int)? {
        guard x.count >= 7, x[0] == 1 else { return nil }
        var out = Array(x[0..<6])
        var offset = 6
        for _ in 0..<(x[5] & 0x1F) {
            guard offset + 2 <= x.count else { return nil }
            let length = Int(x[offset]) << 8 | Int(x[offset + 1])
            offset += 2
            guard offset + length <= x.count else { return nil }
            let rewritten = rewriteSPS(Array(x[offset..<offset + length]), codec: .h264)
            offset += length
            out.append(UInt8(rewritten.count >> 8))
            out.append(UInt8(truncatingIfNeeded: rewritten.count))
            out.append(contentsOf: rewritten)
        }
        out.append(contentsOf: x[offset...])
        return (out, Int(x[4] & 3) + 1)
    }

    // MARK: SPS

    /// The NAL unit with its colour description set to Rec. 709. The three fields are
    /// overwritten in place, so every later bit of the SPS keeps its meaning.
    static func rewriteSPS(_ nal: [UInt8], codec: VideoCodec) -> [UInt8] {
        var rbsp = removeEmulationPrevention(nal)
        var reader = BitReader(rbsp)
        do {
            let found = switch codec {
            case .hevc: try reader.skipToColourDescriptionHEVC()
            case .h264: try reader.skipToColourDescriptionH264()
            }
            guard found, reader.position + 24 <= rbsp.count * 8 else { return nal }
        } catch {
            return nal
        }
        for (field, value) in [UInt8](repeating: 1, count: 3).enumerated() {
            for bit in 0..<8 {
                let position = reader.position + field * 8 + bit
                let mask = UInt8(0x80) >> (position % 8)
                if value & (0x80 >> bit) != 0 {
                    rbsp[position / 8] |= mask
                } else {
                    rbsp[position / 8] &= ~mask
                }
            }
        }
        return addEmulationPrevention(rbsp)
    }

    static func removeEmulationPrevention(_ nal: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func addEmulationPrevention(_ rbsp: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(rbsp.count + 4)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

/// Reads an SPS RBSP up to the VUI colour description.
private struct BitReader {
    struct OutOfData: Error {}

    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func bits(_ count: Int) throws -> Int {
        guard position + count <= bytes.count * 8 else { throw OutOfData() }
        var value = 0
        for _ in 0..<count {
            value = value << 1 | Int(bytes[position / 8] >> (7 - position % 8) & 1)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) throws {
        guard position + count <= bytes.count * 8 else { throw OutOfData() }
        position += count
    }

    mutating func flag() throws -> Bool { try bits(1) == 1 }

    mutating func ue() throws -> Int {
        var zeros = 0
        while try bits(1) == 0 {
            zeros += 1
            guard zeros <= 32 else { throw OutOfData() }
        }
        return (1 << zeros) - 1 + (try bits(zeros))
    }

    mutating func se() throws -> Int {
        let code = try ue()
        return code % 2 == 1 ? (code + 1) / 2 : -(code / 2)
    }

    /// H.265 7.3.2.2 up to E.2.1. True when positioned on `colour_primaries`.
    mutating func skipToColourDescriptionHEVC() throws -> Bool {
        try skip(16 + 4)                    // NAL header, sps_video_parameter_set_id
        let maxSubLayers = try bits(3)
        try skip(1)                         // sps_temporal_id_nesting_flag
        try skip(96)                        // general profile_tier_level
        var present: [(profile: Bool, level: Bool)] = []
        for _ in 0..<maxSubLayers { present.append((try flag(), try flag())) }
        if maxSubLayers > 0 { try skip(2 * (8 - maxSubLayers)) }
        for layer in present {
            if layer.profile { try skip(88) }
            if layer.level { try skip(8) }
        }
        _ = try ue()                        // sps_seq_parameter_set_id
        if try ue() == 3 { try skip(1) }    // chroma_format_idc, separate_colour_plane_flag
        _ = try ue()                        // width
        _ = try ue()                        // height
        if try flag() {                     // conformance window
            for _ in 0..<4 { _ = try ue() }
        }
        _ = try ue()                        // bit_depth_luma_minus8
        _ = try ue()                        // bit_depth_chroma_minus8
        let pocBits = try ue() + 4
        let allSubLayers = try flag()
        for _ in 0..<(allSubLayers ? maxSubLayers + 1 : 1) {
            for _ in 0..<3 { _ = try ue() }
        }
        for _ in 0..<6 { _ = try ue() }     // coding block and transform sizes and depths
        if try flag(), try flag() { try skipScalingListDataHEVC() }
        try skip(2)                         // amp, sao
        if try flag() {                     // pcm
            try skip(8)
            _ = try ue()
            _ = try ue()
            try skip(1)
        }
        let shortTermSets = try ue()
        guard shortTermSets <= 64 else { throw OutOfData() }
        var previousDeltaPOCs = 0
        for index in 0..<shortTermSets {
            previousDeltaPOCs = try skipShortTermRefPicSet(index: index, previousDeltaPOCs: previousDeltaPOCs)
        }
        if try flag() {                     // long_term_ref_pics_present_flag
            let count = try ue()
            guard count <= 32 else { throw OutOfData() }
            try skip(count * (pocBits + 1))
        }
        try skip(2)                         // temporal mvp, strong intra smoothing
        return try skipToColourDescriptionInVUI()
    }

    private mutating func skipScalingListDataHEVC() throws {
        for sizeID in 0..<4 {
            for _ in stride(from: 0, to: 6, by: sizeID == 3 ? 3 : 1) {
                if try flag() {
                    if sizeID > 1 { _ = try se() }
                    for _ in 0..<min(64, 1 << (4 + (sizeID << 1))) { _ = try se() }
                } else {
                    _ = try ue()
                }
            }
        }
    }

    /// Returns NumDeltaPocs of this set, which the syntax of the next set depends on.
    private mutating func skipShortTermRefPicSet(index: Int, previousDeltaPOCs: Int) throws -> Int {
        if index > 0, try flag() {
            try skip(1)                     // delta_rps_sign
            _ = try ue()                    // abs_delta_rps_minus1
            var count = 0
            for _ in 0...previousDeltaPOCs {
                let used = try flag()
                let useDelta = used ? true : try flag()
                if used || useDelta { count += 1 }
            }
            return count
        }
        let negative = try ue()
        let positive = try ue()
        guard negative <= 16, positive <= 16 else { throw OutOfData() }
        for _ in 0..<(negative + positive) {
            _ = try ue()
            try skip(1)
        }
        return negative + positive
    }

    /// H.264 7.3.2.1.1 up to E.1.1. True when positioned on `colour_primaries`.
    mutating func skipToColourDescriptionH264() throws -> Bool {
        try skip(8)                         // NAL header
        let profile = try bits(8)
        try skip(16)                        // constraint flags, level
        _ = try ue()                        // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = try ue()
            if chroma == 3 { try skip(1) }
            _ = try ue()                    // bit_depth_luma_minus8
            _ = try ue()                    // bit_depth_chroma_minus8
            try skip(1)                     // qpprime_y_zero_transform_bypass_flag
            if try flag() {                 // seq_scaling_matrix_present_flag
                for list in 0..<(chroma == 3 ? 12 : 8) where try flag() {
                    try skipScalingListH264(size: list < 6 ? 16 : 64)
                }
            }
        }
        _ = try ue()                        // log2_max_frame_num_minus4
        switch try ue() {                   // pic_order_cnt_type
        case 0:
            _ = try ue()
        case 1:
            try skip(1)
            _ = try se()
            _ = try se()
            let cycle = try ue()
            guard cycle <= 255 else { throw OutOfData() }
            for _ in 0..<cycle { _ = try se() }
        default:
            break
        }
        _ = try ue()                        // max_num_ref_frames
        try skip(1)                         // gaps_in_frame_num_value_allowed_flag
        _ = try ue()                        // width
        _ = try ue()                        // height
        if try !flag() { try skip(1) }      // frame_mbs_only_flag, mb_adaptive_frame_field_flag
        try skip(1)                         // direct_8x8_inference_flag
        if try flag() {                     // frame cropping
            for _ in 0..<4 { _ = try ue() }
        }
        return try skipToColourDescriptionInVUI()
    }

    private mutating func skipScalingListH264(size: Int) throws {
        var last = 8
        var next = 8
        for _ in 0..<size {
            if next != 0 {
                next = (last + (try se()) + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    /// The start of the VUI is the same in both codecs.
    private mutating func skipToColourDescriptionInVUI() throws -> Bool {
        guard try flag() else { return false }      // vui_parameters_present_flag
        if try flag(), try bits(8) == 255 {         // aspect_ratio_idc, Extended_SAR
            try skip(32)
        }
        if try flag() { try skip(1) }               // overscan
        guard try flag() else { return false }      // video_signal_type_present_flag
        try skip(4)                                 // video_format, full range
        return try flag()                           // colour_description_present_flag
    }
}
