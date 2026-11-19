import EPLibavcodec
import EPLibavutil

/// Whether AVPlayer plays a file's video from fMP4 HLS itself, or the player decodes it and
/// draws the frames (`RenderedVideoSource`).
enum VideoRoute: Equatable, Sendable {
    /// Stream copy into the HLS video rendition.
    case copy(VideoCodec)
    /// Decoded by libavcodec and drawn above a placeholder rendition.
    case render
    /// Neither: AVPlayer can't decode it, and the decoder or its pixel format isn't available here.
    case unsupported

    /// H.264 and HEVC go to AVPlayer as they always have, except 10-bit H.264 (High 10), which
    /// AVPlayer doesn't decode. Anything else libavcodec decodes to 4:2:0 at 8 or 10 bits is drawn
    /// by the player: AV1, VC-1, MPEG-4 Part 2 (DivX, Xvid), MPEG-2 and VP9 among them.
    ///
    /// `pixelFormat` is what the probe's decoder reported, `AV_PIX_FMT_NONE` when it reported
    /// nothing; then the profile decides for H.264, and the codec alone for the rest.
    static func route(codecID: AVCodecID, pixelFormat: AVPixelFormat, profile: Int32, decoderAvailable: Bool) -> VideoRoute {
        let known = pixelFormat != AV_PIX_FMT_NONE
        switch codecID {
        case AV_CODEC_ID_H264:
            let highTen = known ? pixelFormat == AV_PIX_FMT_YUV420P10LE : profile & ~AV_PROFILE_H264_INTRA == AV_PROFILE_H264_HIGH_10
            guard highTen, decoderAvailable else { return .copy(.h264) }
            return .render
        case AV_CODEC_ID_HEVC:
            return .copy(.hevc)
        default:
            guard decoderAvailable, !known || renderable.contains(pixelFormat) else { return .unsupported }
            return .render
        }
    }

    /// The decoder for a rendered codec. AV1 goes to dav1d: libavcodec's own AV1 decoder
    /// only drives hardware.
    static func decoder(for codecID: AVCodecID) -> UnsafePointer<AVCodec>? {
        if codecID == AV_CODEC_ID_AV1 { return avcodec_find_decoder_by_name("libdav1d") }
        return avcodec_find_decoder(codecID)
    }

    /// Pixel formats `PixelBufferConverter` turns into a CoreVideo buffer.
    static let renderable: [AVPixelFormat] = [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUV420P10LE]
}
