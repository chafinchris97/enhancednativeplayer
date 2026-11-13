import AetherLibavcodec
import AetherLibavutil
import CoreVideo
import Foundation

/// The HDR10 static metadata the container gives: the mastering display (SMPTE ST 2086) and
/// the content light level (MaxCLL / MaxFALL), in the byte layout of the HEVC SEI messages,
/// which is also what CoreVideo's `kCVImageBufferMasteringDisplayColorVolumeKey` and
/// `kCVImageBufferContentLightLevelInfoKey` take. Metadata carried only in-band, in SEI, isn't
/// read.
struct HDRStaticMetadata: Sendable, Equatable {
    /// 24 bytes, big-endian: x and y of the green, blue and red primaries and the white point
    /// in 0.00002 units, then the maximum and minimum luminance in 0.0001 cd/m².
    var masteringDisplay: [UInt8]?
    /// 4 bytes, big-endian: MaxCLL and MaxFALL in cd/m².
    var contentLightLevel: [UInt8]?

    /// Nil when the stream carries neither.
    init?(_ par: UnsafeMutablePointer<AVCodecParameters>) {
        var mastering: AVMasteringDisplayMetadata?
        if let side = par.codedSideData(AV_PKT_DATA_MASTERING_DISPLAY_METADATA), side.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            mastering = UnsafeRawPointer(side.pointee.data).loadUnaligned(as: AVMasteringDisplayMetadata.self)
        }
        var light: AVContentLightMetadata?
        if let side = par.codedSideData(AV_PKT_DATA_CONTENT_LIGHT_LEVEL), side.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
            light = UnsafeRawPointer(side.pointee.data).loadUnaligned(as: AVContentLightMetadata.self)
        }
        self.init(mastering: mastering, light: light)
    }

    init?(mastering: AVMasteringDisplayMetadata?, light: AVContentLightMetadata?) {
        masteringDisplay = mastering.flatMap(Self.masteringDisplayBytes)
        contentLightLevel = light.flatMap(Self.contentLightLevelBytes)
        if masteringDisplay == nil, contentLightLevel == nil { return nil }
    }

    /// Needs both the primaries and the luminance: CoreVideo's value has no way to leave
    /// either out.
    static func masteringDisplayBytes(_ metadata: AVMasteringDisplayMetadata) -> [UInt8]? {
        guard metadata.has_primaries != 0, metadata.has_luminance != 0 else { return nil }
        let p = metadata.display_primaries
        // FFmpeg keeps red, green, blue; the SEI order is green, blue, red.
        let chromaticities = [p.1.0, p.1.1, p.2.0, p.2.1, p.0.0, p.0.1, metadata.white_point.0, metadata.white_point.1]
        var bytes: [UInt8] = []
        for value in chromaticities { bytes += bigEndian(UInt16(clamping: Int((av_q2d(value) * 50_000).rounded()))) }
        bytes += bigEndian(UInt32(clamping: Int((av_q2d(metadata.max_luminance) * 10_000).rounded())))
        bytes += bigEndian(UInt32(clamping: Int((av_q2d(metadata.min_luminance) * 10_000).rounded())))
        return bytes
    }

    static func contentLightLevelBytes(_ metadata: AVContentLightMetadata) -> [UInt8]? {
        guard metadata.MaxCLL > 0 || metadata.MaxFALL > 0 else { return nil }
        return bigEndian(UInt16(clamping: metadata.MaxCLL)) + bigEndian(UInt16(clamping: metadata.MaxFALL))
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

/// What an HDR frame's colour is, as `CVPixelBuffer` attachments: BT.2020 primaries and
/// matrix, the PQ or HLG transfer, and the static metadata when the file has it.
struct SourceHDRColor: Sendable, Equatable {
    var range: VideoRange
    var metadata: HDRStaticMetadata?

    /// Nil for SDR.
    init?(range: VideoRange, metadata: HDRStaticMetadata?) {
        guard range != .sdr else { return nil }
        self.range = range
        self.metadata = metadata
    }

    /// Replaces whatever colour the buffer was tagged with.
    func apply(to buffer: CVPixelBuffer) {
        let transfer = range == .pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        // A colour space derived from the Rec. 709 tags would win over them.
        CVBufferRemoveAttachment(buffer, kCVImageBufferCGColorSpaceKey)
        CVBufferRemoveAttachment(buffer, kCVImageBufferGammaLevelKey)
        if let bytes = metadata?.masteringDisplay {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, Data(bytes) as CFData, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey)
        }
        if let bytes = metadata?.contentLightLevel {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, Data(bytes) as CFData, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey)
        }
    }
}
