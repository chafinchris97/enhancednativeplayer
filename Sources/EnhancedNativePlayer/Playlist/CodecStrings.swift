import Foundation

/// RFC 6381 `CODECS` values for the master playlist.
enum CodecStrings {
    /// `CODECS`: Dolby Vision itself for profile 5, else the codec of the sample entry,
    /// which for profile 8 is its HEVC base layer.
    static func video(_ track: VideoTrack) -> String {
        if track.emitsDolbyVision, let dv = track.dolbyVision, dv.profile == 5 {
            return dolbyVision(dv)
        }
        switch track.codec {
        case .h264: return avc(track)
        case .hevc: return hevc(track, entry: "hvc1")
        }
    }

    /// `SUPPLEMENTAL-CODECS`. Dolby Vision profile 8: the profile and level, then the brand
    /// of the base layer it is compatible with. HDR10+: the HEVC string again with the
    /// `cdm4` brand. Dolby Vision wins when a file has both. Nil for everything else.
    static func supplemental(_ track: VideoTrack) -> String? {
        guard track.emitsDolbyVision, let dv = track.dolbyVision, dv.profile == 8 else {
            if track.hdr10Plus, !track.emitsDolbyVision, track.codec == .hevc {
                return hevc(track, entry: "hvc1") + "/cdm4"
            }
            return nil
        }
        let brand: String
        switch dv.compatibilityID {
        case 1: brand = "db1p"
        case 2: brand = "db2g"
        case 4: brand = "db4h"
        default: return dolbyVision(dv)
        }
        return dolbyVision(dv) + "/" + brand
    }

    static func dolbyVision(_ dv: DolbyVisionConfiguration) -> String {
        String(format: "dvh1.%02d.%02d", dv.profile, dv.level)
    }

    static func avc(_ track: VideoTrack) -> String {
        let x = track.extradata
        if x.count >= 4, x[0] == 1 {
            return String(format: "avc1.%02X%02X%02X", x[1], x[2], x[3])
        }
        let profile = track.profile > 0 ? Int(track.profile) : 100
        let level = track.level > 0 ? Int(track.level) : 40
        return String(format: "avc1.%02X00%02X", profile, level)
    }

    /// ISO/IEC 14496-15 Annex E, from the `hvcC` record.
    static func hevc(_ track: VideoTrack, entry: String) -> String {
        let x = track.extradata
        guard x.count >= 13, x[0] == 1 else {
            let profile = track.profile > 0 ? Int(track.profile) : 2
            let level = track.level > 0 ? Int(track.level) : 120
            return "\(entry).\(profile).\(profile == 1 ? 6 : 4).L\(level).B0"
        }
        let space = Int(x[1] >> 6)
        let tier = (x[1] >> 5) & 1
        let profile = Int(x[1] & 0x1F)
        let compatibility = UInt32(x[2]) << 24 | UInt32(x[3]) << 16 | UInt32(x[4]) << 8 | UInt32(x[5])
        let level = Int(x[12])
        var constraints = Array(x[6..<12])
        while let last = constraints.last, last == 0 { constraints.removeLast() }

        var result = entry + "."
        if space > 0 { result += ["", "A", "B", "C"][space] }
        result += "\(profile)."
        result += String(compatibility.bitReversed, radix: 16, uppercase: true)
        result += ".\(tier == 1 ? "H" : "L")\(level)"
        for byte in constraints { result += String(format: ".%02X", byte) }
        return result
    }

    static func audio(_ track: AudioTrack) -> String {
        if track.delivery == .flac { return "fLaC" }
        switch track.codecName {
        case "aac": return "mp4a.40.\(aacObjectType(track))"
        case "ac3": return "ac-3"
        case "eac3": return "ec-3"
        case "flac": return "fLaC"
        default: return track.codecName
        }
    }

    private static func aacObjectType(_ track: AudioTrack) -> Int {
        let x = track.extradata
        if x.count >= 2 {
            let type = Int(x[0] >> 3)
            return type == 31 ? 32 + (Int(x[0] & 7) << 3 | Int(x[1] >> 5)) : type
        }
        // AV_PROFILE_AAC_* is the object type minus one.
        return track.profile >= 0 ? Int(track.profile) + 1 : 2
    }
}

private extension UInt32 {
    var bitReversed: UInt32 {
        var value = self
        var result: UInt32 = 0
        for _ in 0..<32 {
            result = result << 1 | value & 1
            value >>= 1
        }
        return result
    }
}
