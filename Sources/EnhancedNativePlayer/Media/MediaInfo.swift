import Foundation

enum VideoRange: String, Sendable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

struct DolbyVisionConfiguration: Sendable, Equatable {
    var profile: Int
    var level: Int
    var rpuPresent: Bool
    var enhancementLayerPresent: Bool
    var baseLayerPresent: Bool
    var compatibilityID: Int
}

enum VideoCodec: Sendable {
    case h264
    case hevc
}

/// The file's own video when AVPlayer can't decode it (AV1, VC-1, MPEG-4 Part 2, …). The player
/// decodes it and draws the frames itself; the HLS video rendition is a black placeholder that
/// gives AVPlayer a timeline, and `VideoTrack` then describes that placeholder's stream.
struct RenderedVideoSource: Sendable, Equatable {
    var codecID: UInt32
    var codecName: String
    /// The decoder's output `AVPixelFormat`, `AV_PIX_FMT_NONE` (-1) when the probe didn't learn it.
    var pixelFormat: Int32
    /// Width over height of one pixel, 1:1 when the file doesn't say.
    var sampleAspect: Rational
    /// `AVColorPrimaries`, `AVColorTransferCharacteristic`, `AVColorSpace` and `AVColorRange`.
    var colorPrimaries: Int32
    var colorTransfer: Int32
    var colorSpace: Int32
    var colorRange: Int32
}

struct VideoTrack: Sendable {
    var streamIndex: Int32
    /// For rendered video, the placeholder's codec.
    var codec: VideoCodec
    var timeBase: Rational
    var width: Int
    var height: Int
    var frameRate: Double?
    /// Average frame duration in the stream time base, for the last packet of the file.
    var frameDuration: Int64
    /// Frames of reordering (B-frame depth) the decoder reports.
    var reorderDepth: Int
    var bitRate: Int64?
    var range: VideoRange
    var dolbyVision: DolbyVisionConfiguration?
    var extradata: [UInt8]
    var profile: Int32
    var level: Int32
    /// Set when the player draws the video itself; see `RenderedVideoSource`.
    var rendered: RenderedVideoSource? = nil
    /// HEVC PQ video carrying HDR10+ SEI, which the master announces with the `cdm4` brand.
    var hdr10Plus = false
    /// The container's mastering display and content light level, for tone mapping the
    /// SDR master's video.
    var hdrMetadata: HDRStaticMetadata? = nil

    /// Dolby Vision profiles 5 and 8, which AVPlayer decodes natively. Profile 7 is dual-layer and unsupported, so it rides `hvc1` as plain HDR10.
    var emitsDolbyVision: Bool {
        guard codec == .hevc, let dolbyVision else { return false }
        return dolbyVision.profile == 5 || dolbyVision.profile == 8
    }

    /// True for anything a display would treat as HDR, including Dolby Vision on an SDR base layer.
    var isHDR: Bool { range != .sdr || emitsDolbyVision }

    /// The same track as it is described once `SDRBitstreamRewriter` has relabeled it.
    /// `hvcC` / `avcC` keep their profile and level fields, so `extradata` still gives
    /// the right `CODECS` string. For rendered video, the SDR placeholder's stream.
    var sdrVariant: VideoTrack {
        var track = self
        track.range = .sdr
        track.dolbyVision = nil
        track.hdr10Plus = false
        if rendered != nil {
            let placeholder = PlaceholderVideo.sdr
            track.codec = placeholder.codec
            track.extradata = placeholder.record
            track.profile = placeholder.profile
            track.level = placeholder.level
        }
        return track
    }

    /// `dvh1` only for profile 5, which has no compatible base layer. Profile 8 is `hvc1`
    /// with its dvcC / dvvC, the backward-compatible signaling Apple's HLS spec asks for.
    var sampleEntry: String {
        switch codec {
        case .h264: "avc1"
        case .hevc: emitsDolbyVision && dolbyVision?.profile == 5 ? "dvh1" : "hvc1"
        }
    }
}

enum AudioDelivery: Sendable, Equatable {
    /// Stream copy. The codec is one AVPlayer plays from fMP4 HLS.
    case copy
    /// Decoded and re-encoded losslessly as FLAC.
    case flac
}

struct AudioTrack: Sendable {
    /// Position among the file's audio tracks, the `{index}` in `audio_{index}.m3u8`.
    var index: Int
    var streamIndex: Int32
    var codecID: UInt32
    var codecName: String
    var profile: Int32
    /// libavcodec's profile name, e.g. "DTS-HD MA".
    var profileName: String?
    var timeBase: Rational
    /// First timestamp of the track (time base above), 0 when unknown.
    var startTime: Int64
    var sampleRate: Int
    var channels: Int
    var bitsPerRawSample: Int
    var language: String?
    var title: String?
    var bitRate: Int64?
    var isDefault: Bool
    var isAtmos: Bool
    var delivery: AudioDelivery
    var extradata: [UInt8]

    /// FLAC carries at most eight channels; wider layouts are downmixed to 7.1.
    var deliveredChannels: Int { delivery == .flac ? min(channels, 8) : channels }
}

/// How a subtitle codec's packets turn into WebVTT cue text.
enum SubtitleTextFormat: Sendable, Equatable {
    case subRip
    case plainText
    case movText
    case webVTT
}

struct SubtitleTrack: Sendable {
    /// Position in the subtitle menu, the `{index}` in `subtitle_{index}.m3u8`: external
    /// tracks first, then the file's own.
    var index: Int
    /// -1 for an external track.
    var streamIndex: Int32
    var codecName: String
    var timeBase: Rational
    var language: String?
    var title: String?
    var isDefault: Bool
    var isForced: Bool
    /// Nil for ASS and bitmap subtitles, whose segments stay empty.
    var textFormat: SubtitleTextFormat?
    /// The codec private data. For ASS this is the script header: script info and styles.
    var extradata: [UInt8] = []
    /// Set for a track from a separate file, whose whole content is already in memory.
    var external: ExternalSubtitleContent?

    var isExternal: Bool { external != nil }

    /// Drawn by `PGSSubtitleRenderer` instead of going through the playlist.
    var isPGS: Bool { codecName == "hdmv_pgs_subtitle" }

    /// Drawn by `ASSSubtitleRenderer` with libass instead of going through the playlist.
    var isASS: Bool { codecName == "ass" || codecName == "ssa" }
}

/// Every video keyframe of the file, read from the container index.
struct KeyframeIndex: Sendable {
    /// Keyframe timestamps in the video time base, ascending.
    /// These are PTS for Matroska (cue times) and DTS for MP4 (the mov demuxer
    /// indexes samples by decode time); `usesDecodeTimestamps` says which,
    /// and packets are matched against the same field.
    var timestamps: [Int64]
    /// Byte offset of each keyframe (cluster position for Matroska), -1 when unknown.
    var positions: [Int64]
    var timeBase: Rational
    var usesDecodeTimestamps: Bool
    /// pts − dts of the first keyframe, so index timestamps convert to presentation time.
    var presentationOffset: Int64
}

struct MediaInfo: Sendable {
    var formatName: String
    var fileSize: Int64
    var durationSeconds: Double
    var bitRate: Int64?
    var video: VideoTrack
    var audio: [AudioTrack]
    var subtitles: [SubtitleTrack]
    var keyframes: KeyframeIndex
    /// End of the video stream in index timestamps.
    var videoEndTimestamp: Int64
    /// The container's chapters, in seconds of the file's timeline.
    var chapters: [Chapter] = []
}
