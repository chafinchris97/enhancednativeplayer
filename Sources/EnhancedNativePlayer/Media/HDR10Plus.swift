import Foundation

/// Finds HDR10+ (SMPTE ST 2094-40) dynamic metadata in an HEVC sample. It has no
/// configuration record in the container: it rides in-band, as a prefix SEI
/// `user_data_registered_itu_t_t35` message on every frame, which AVPlayer reads as is.
enum HDR10Plus {
    /// True if a length-prefixed HEVC sample has an HDR10+ SEI message. `lengthSize`
    /// comes from the `hvcC` record.
    static func isPresent(in sample: UnsafeBufferPointer<UInt8>, lengthSize: Int) -> Bool {
        var offset = 0
        while offset + lengthSize <= sample.count {
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(sample[offset + i]) }
            let start = offset + lengthSize
            guard length <= sample.count - start else { return false }
            // Prefix SEI, after the two-byte NAL unit header.
            if length > 2, (sample[start] >> 1) & 0x3F == 39,
               seiHasHDR10Plus(unescaped(sample[start + 2..<start + length])) {
                return true
            }
            offset = start + length
        }
        return false
    }

    /// The same for a sample of a track described by an `hvcC` record.
    static func isPresent(in sample: [UInt8], hvcC: [UInt8]) -> Bool {
        guard hvcC.count >= 23, hvcC[0] == 1 else { return false }
        return sample.withUnsafeBufferPointer { isPresent(in: $0, lengthSize: Int(hvcC[21] & 3) + 1) }
    }

    /// The RBSP, without emulation prevention bytes (`00 00 03`).
    private static func unescaped(_ bytes: Slice<UnsafeBufferPointer<UInt8>>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    /// Walks the SEI messages of an SEI RBSP for a T.35 message with HDR10+'s
    /// country code (0xB5), provider code (0x003C), provider-oriented code (0x0001)
    /// and application identifier (4).
    private static func seiHasHDR10Plus(_ rbsp: [UInt8]) -> Bool {
        var i = 0
        // A message needs at least a type and a size byte; 0x80 alone is the trailing bits.
        while i + 1 < rbsp.count, rbsp[i] != 0x80 {
            var type = 0
            while i < rbsp.count, rbsp[i] == 0xFF { type += 255; i += 1 }
            guard i < rbsp.count else { return false }
            type += Int(rbsp[i]); i += 1
            var size = 0
            while i < rbsp.count, rbsp[i] == 0xFF { size += 255; i += 1 }
            guard i < rbsp.count else { return false }
            size += Int(rbsp[i]); i += 1
            guard size <= rbsp.count - i else { return false }
            if type == 4, size >= 6, rbsp[i..<i + 6].elementsEqual([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]) {
                return true
            }
            i += size
        }
        return false
    }
}
