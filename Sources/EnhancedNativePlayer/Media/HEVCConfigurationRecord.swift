import Foundation

/// Some HEVC files (Netflix WEB-DLs muxed by mkvmerge among them) have an `hvcC` with no
/// parameter sets at all, and repeat VPS / SPS / PPS in-band at every keyframe. `hvc1` and
/// `dvh1` need them in the sample entry: without them AVPlayer fails with CoreMedia -19601.
enum HEVCConfigurationRecord {
    /// `record` with its arrays taken from a length-prefixed sample, or nil if it already
    /// has arrays, is not an `hvcC`, or the sample lacks a VPS, an SPS or a PPS.
    /// `array_completeness` stays 0, because the sets also stay in-band.
    static func filling(_ record: [UInt8], from sample: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        guard record.count >= 23, record[0] == 1, record[22] == 0 else { return nil }
        let lengthSize = Int(record[21] & 3) + 1
        let types: [UInt8] = [32, 33, 34]
        var sets: [UInt8: [ArraySlice<UInt8>]] = [:]
        var offset = 0
        while offset + lengthSize <= sample.count {
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(sample[offset + i]) }
            let start = offset + lengthSize
            guard length <= sample.count - start else { return nil }
            if length > 0, length <= Int(UInt16.max) {
                let type = (sample[start] >> 1) & 0x3F
                if types.contains(type) { sets[type, default: []].append(Array(sample[start..<start + length])[...]) }
            }
            offset = start + length
        }
        guard types.allSatisfy({ sets[$0] != nil }) else { return nil }

        var out = Array(record[0..<22])
        out.append(UInt8(types.count))
        for type in types {
            let nals = sets[type]!
            out += [type, UInt8(nals.count >> 8), UInt8(truncatingIfNeeded: nals.count)]
            for nal in nals {
                out += [UInt8(nal.count >> 8), UInt8(truncatingIfNeeded: nal.count)]
                out += nal
            }
        }
        return out
    }
}
