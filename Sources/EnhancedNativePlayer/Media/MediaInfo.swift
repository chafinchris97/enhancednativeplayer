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

struct VideoTrack: Sendable {
    var streamIndex: Int32
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

    /// `dvh1` for Dolby Vision profiles 5 and 8, which AVPlayer decodes natively.
    /// Profile 7 is dual-layer and unsupported, so it rides `hvc1` as plain HDR10.
    var emitsDolbyVision: Bool {
        guard codec == .hevc, let dolbyVision else { return false }
        return dolbyVision.profile == 5 || dolbyVision.profile == 8
    }

    /// True for anything a display would treat as HDR, including Dolby Vision on an SDR base layer.
    var isHDR: Bool { range != .sdr || emitsDolbyVision }

    /// The same track as it is described once `SDRBitstreamRewriter` has relabeled it.
    /// `hvcC` / `avcC` keep their profile and level fields, so `extradata` still gives
    /// the right `CODECS` string.
    var sdrVariant: VideoTrack {
        var track = self
        track.range = .sdr
        track.dolbyVision = nil
        return track
    }

    var sampleEntry: String {
        switch codec {
        case .h264: "avc1"
        case .hevc: emitsDolbyVision ? "dvh1" : "hvc1"
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
    /// Position among the file's subtitle tracks, the `{index}` in `subtitle_{index}.m3u8`.
    var index: Int
    var streamIndex: Int32
    var codecName: String
    var timeBase: Rational
    var language: String?
    var title: String?
    /// Nil for ASS and bitmap subtitles, whose segments stay empty for now.
    var textFormat: SubtitleTextFormat?
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
}
