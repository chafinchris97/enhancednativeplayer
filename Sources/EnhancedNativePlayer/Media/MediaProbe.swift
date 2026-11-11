import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Reads stream layout and the full keyframe list without scanning packets.
///
/// Matroska and MP4 both carry a keyframe index in the container: Cues (one
/// CuePoint per video keyframe as written by mkvmerge and libavformat) and the
/// `stss` sync-sample table. libavformat loads either into the stream's index
/// entries, Matroska on the first seek. That costs the header, the index
/// region and the first cluster, a few range requests, instead of the full
/// read an ffprobe keyframe scan does.
enum MediaProbe {
    static func probe(file: RemoteFile, token: CancellationToken) throws -> MediaInfo {
        let demuxer = try Demuxer(file: file, token: token)
        let ctx = demuxer.formatContext
        let formatName = String(cString: ctx.pointee.iformat.pointee.name)

        let videoIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0 else { throw EnhancedPlayerError.noVideoStream }
        let videoStream = demuxer.stream(videoIndex)

        // Matroska parses Cues lazily on the first seek; this also puts us back at the start.
        _ = av_seek_frame(ctx, videoIndex, 0, AVSEEK_FLAG_BACKWARD)
        let usesDTS = formatName.contains("mov")
        var timestamps: [Int64] = []
        var positions: [Int64] = []
        let count = avformat_index_get_entries_count(videoStream)
        timestamps.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(videoStream, i) else { continue }
            let flags = Int32(entry.pointee.flags)
            guard flags & AVINDEX_KEYFRAME != 0, flags & AVINDEX_DISCARD_FRAME == 0 else { continue }
            let ts = entry.pointee.timestamp
            if let last = timestamps.last, ts <= last { continue }
            timestamps.append(ts)
            positions.append(entry.pointee.pos)
        }
        guard !timestamps.isEmpty else { throw EnhancedPlayerError.noKeyframeIndex }

        var audio = audioTracks(demuxer)
        let (presentationOffset, atmos, firstSample) = try scanStart(demuxer: demuxer, videoIndex: videoIndex, audio: audio, usesDTS: usesDTS)
        for i in audio.indices where atmos.contains(audio[i].streamIndex) {
            audio[i].isAtmos = true
        }

        var video = try videoTrack(videoStream, index: videoIndex)
        if video.codec == .hevc, video.rendered == nil, let record = firstSample.withUnsafeBufferPointer({ HEVCConfigurationRecord.filling(video.extradata, from: $0) }) {
            video.extradata = record
        }
        let tb = video.timeBase
        var end: Int64
        if videoStream.pointee.duration != FF.noPTS, videoStream.pointee.duration > 0 {
            let start = videoStream.pointee.start_time == FF.noPTS ? 0 : videoStream.pointee.start_time
            end = start + videoStream.pointee.duration
        } else {
            let start = ctx.pointee.start_time == FF.noPTS ? 0 : ctx.pointee.start_time
            end = Rational.microseconds.rescale(start + max(ctx.pointee.duration, 0), to: tb)
        }
        if usesDTS { end -= presentationOffset }
        end = max(end, timestamps.last! + video.frameDuration)

        return MediaInfo(
            formatName: formatName,
            fileSize: file.length,
            durationSeconds: Double(max(ctx.pointee.duration, 0)) / Double(AV_TIME_BASE),
            bitRate: ctx.pointee.bit_rate > 0 ? ctx.pointee.bit_rate : nil,
            video: video,
            audio: audio,
            subtitles: subtitleTracks(demuxer, usesDTS: usesDTS),
            keyframes: KeyframeIndex(
                timestamps: timestamps,
                positions: positions,
                timeBase: tb,
                usesDecodeTimestamps: usesDTS,
                presentationOffset: presentationOffset
            ),
            videoEndTimestamp: end,
            chapters: chapters(ctx)
        )
    }

    /// Matroska editions and MP4 chapter tracks, as libavformat reads them with the header.
    private static func chapters(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> [Chapter] {
        guard let list = ctx.pointee.chapters else { return [] }
        var chapters: [Chapter] = []
        for i in 0..<Int(ctx.pointee.nb_chapters) {
            guard let chapter = list[i] else { continue }
            let timeBase = Rational(chapter.pointee.time_base)
            guard timeBase.isValid else { continue }
            var title = ""
            if let entry = av_dict_get(chapter.pointee.metadata, "title", nil, 0), let value = entry.pointee.value {
                title = String(cString: value)
            }
            let start = timeBase.doubleValue * Double(chapter.pointee.start)
            let end = chapter.pointee.end > chapter.pointee.start ? timeBase.doubleValue * Double(chapter.pointee.end) : nil
            chapters.append(Chapter(title: title.isEmpty ? "Chapter \(i + 1)" : title, start: start, end: end))
        }
        return chapters.sorted { $0.start < $1.start }
    }

    private static func videoTrack(_ stream: UnsafeMutablePointer<AVStream>, index: Int32) throws -> VideoTrack {
        let par = stream.codecpar
        let codecID = par.pointee.codec_id
        let pixelFormat = AVPixelFormat(rawValue: par.pointee.format)
        let route = VideoRoute.route(codecID: codecID, pixelFormat: pixelFormat, profile: par.pointee.profile, decoderAvailable: VideoRoute.decoder(for: codecID) != nil)
        let codec: VideoCodec
        switch route {
        case .copy(let copied): codec = copied
        case .render: return renderedVideoTrack(stream, index: index)
        case .unsupported: throw EnhancedPlayerError.unsupportedVideoCodec(codecName(codecID))
        }

        var dolbyVision: DolbyVisionConfiguration?
        if let side = par.codedSideData(AV_PKT_DATA_DOVI_CONF) {
            let record = side.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            dolbyVision = DolbyVisionConfiguration(
                profile: Int(record.dv_profile),
                level: Int(record.dv_level),
                rpuPresent: record.rpu_present_flag != 0,
                enhancementLayerPresent: record.el_present_flag != 0,
                baseLayerPresent: record.bl_present_flag != 0,
                compatibilityID: Int(record.dv_bl_signal_compatibility_id)
            )
        }

        var range: VideoRange
        switch transferCharacteristics(par) {
        case AVCOL_TRC_SMPTE2084: range = .pq
        case AVCOL_TRC_ARIB_STD_B67: range = .hlg
        default: range = .sdr
        }
        if let dolbyVision, codec == .hevc {
            switch (dolbyVision.profile, dolbyVision.compatibilityID) {
            case (5, _): range = .pq
            case (8, 1), (7, _): range = .pq
            case (8, 4): range = .hlg
            case (8, 2): range = .sdr
            default: break
            }
        }

        let rate = frameRate(stream)
        let tb = stream.timeBase
        let frameDuration = rate.isValid ? max(1, av_rescale_q(1, AVRational(num: rate.den, den: rate.num), tb.av)) : 1

        return VideoTrack(
            streamIndex: index,
            codec: codec,
            timeBase: tb,
            width: Int(par.pointee.width),
            height: Int(par.pointee.height),
            frameRate: rate.isValid ? rate.doubleValue : nil,
            frameDuration: frameDuration,
            reorderDepth: Int(par.pointee.video_delay),
            bitRate: bitRate(stream),
            range: range,
            dolbyVision: dolbyVision,
            extradata: par.extradataBytes,
            profile: par.pointee.profile,
            level: par.pointee.level
        )
    }

    /// A track the player decodes and draws itself. The HLS rendition is `PlaceholderVideo`,
    /// tagged with the source's dynamic range, and keeps the source's size, rate and clock.
    private static func renderedVideoTrack(_ stream: UnsafeMutablePointer<AVStream>, index: Int32) -> VideoTrack {
        let par = stream.codecpar
        let range: VideoRange
        switch transferCharacteristics(par) {
        case AVCOL_TRC_SMPTE2084: range = .pq
        case AVCOL_TRC_ARIB_STD_B67: range = .hlg
        default: range = .sdr
        }
        let placeholder = PlaceholderVideo.stream(for: range)
        let rate = frameRate(stream)
        let tb = stream.timeBase
        let streamAspect = Rational(stream.pointee.sample_aspect_ratio)
        let codecAspect = Rational(par.pointee.sample_aspect_ratio)
        let source = RenderedVideoSource(
            codecID: par.pointee.codec_id.rawValue,
            codecName: codecName(par.pointee.codec_id),
            pixelFormat: par.pointee.format,
            sampleAspect: streamAspect.isValid ? streamAspect : codecAspect.isValid ? codecAspect : Rational(num: 1, den: 1),
            colorPrimaries: Int32(par.pointee.color_primaries.rawValue),
            colorTransfer: Int32(transferCharacteristics(par).rawValue),
            colorSpace: Int32(par.pointee.color_space.rawValue),
            colorRange: Int32(par.pointee.color_range.rawValue)
        )
        return VideoTrack(
            streamIndex: index,
            codec: placeholder.codec,
            timeBase: tb,
            width: Int(par.pointee.width),
            height: Int(par.pointee.height),
            frameRate: rate.isValid ? rate.doubleValue : nil,
            frameDuration: rate.isValid ? max(1, av_rescale_q(1, AVRational(num: rate.den, den: rate.num), tb.av)) : 1,
            reorderDepth: 0,
            bitRate: bitRate(stream),
            range: range,
            dolbyVision: nil,
            extradata: placeholder.record,
            profile: placeholder.profile,
            level: placeholder.level,
            rendered: source
        )
    }

    private static func frameRate(_ stream: UnsafeMutablePointer<AVStream>) -> Rational {
        Rational(stream.pointee.avg_frame_rate).isValid ? Rational(stream.pointee.avg_frame_rate) : Rational(stream.pointee.r_frame_rate)
    }

    private static func audioTracks(_ demuxer: Demuxer) -> [AudioTrack] {
        var tracks: [AudioTrack] = []
        for i in 0..<demuxer.streamCount {
            let stream = demuxer.stream(i)
            let par = stream.codecpar
            guard par.pointee.codec_type == AVMEDIA_TYPE_AUDIO, par.pointee.sample_rate > 0 else { continue }
            let id = par.pointee.codec_id
            let copyable = [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC].contains(id)
            tracks.append(AudioTrack(
                index: tracks.count,
                streamIndex: i,
                codecID: id.rawValue,
                codecName: codecName(id),
                profile: par.pointee.profile,
                profileName: avcodec_profile_name(id, par.pointee.profile).map { String(cString: $0) },
                timeBase: stream.timeBase,
                startTime: stream.pointee.start_time == FF.noPTS ? 0 : stream.pointee.start_time,
                sampleRate: Int(par.pointee.sample_rate),
                channels: Int(par.pointee.ch_layout.nb_channels),
                bitsPerRawSample: Int(par.pointee.bits_per_raw_sample),
                language: stream.metadata("language").flatMap { $0 == "und" ? nil : $0 },
                title: stream.metadata("title"),
                bitRate: bitRate(stream),
                isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
                isAtmos: id == AV_CODEC_ID_EAC3 && par.pointee.profile == AV_PROFILE_EAC3_DDP_ATMOS,
                delivery: copyable ? .copy : .flac,
                extradata: par.extradataBytes
            ))
        }
        return tracks
    }

    private static func subtitleTracks(_ demuxer: Demuxer, usesDTS: Bool) -> [SubtitleTrack] {
        var tracks: [SubtitleTrack] = []
        for i in 0..<demuxer.streamCount {
            let stream = demuxer.stream(i)
            let par = stream.codecpar
            guard par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            var format: SubtitleTextFormat?
            switch par.pointee.codec_id {
            case AV_CODEC_ID_SUBRIP: format = .subRip
            case AV_CODEC_ID_TEXT: format = .plainText
            case AV_CODEC_ID_MOV_TEXT: format = .movText
            // MP4's WebVTT samples are boxes, not cue text.
            case AV_CODEC_ID_WEBVTT: format = usesDTS ? nil : .webVTT
            default: break
            }
            tracks.append(SubtitleTrack(
                index: tracks.count,
                streamIndex: i,
                codecName: codecName(par.pointee.codec_id),
                timeBase: stream.timeBase,
                language: stream.metadata("language").flatMap { $0 == "und" ? nil : $0 },
                title: stream.metadata("title"),
                isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
                isForced: stream.pointee.disposition & AV_DISPOSITION_FORCED != 0,
                textFormat: format,
                // mkvmerge compresses the header along with the blocks when it compresses a track.
                extradata: MatroskaCompression.inflated(par.extradataBytes)
            ))
        }
        return tracks
    }

    /// Reads the first packets once: the first video packet gives the pts−dts offset
    /// for DTS-indexed files, and decoding one E-AC-3 frame per track reveals Atmos
    /// (JOC), which only the decoder reports. The first video packet's bytes come back too,
    /// for a file whose parameter sets are only in-band.
    private static func scanStart(demuxer: Demuxer, videoIndex: Int32, audio: [AudioTrack], usesDTS: Bool) throws -> (Int64, Set<Int32>, [UInt8]) {
        var pendingEAC3 = Set(audio.filter { $0.codecID == AV_CODEC_ID_EAC3.rawValue && !$0.isAtmos }.map(\.streamIndex))
        var atmos = Set<Int32>()
        var offset: Int64?
        var firstSample: [UInt8] = []
        let packet = Packet()
        var read = 0
        while (offset == nil || !pendingEAC3.isEmpty), read < 2000, try demuxer.read(into: packet) {
            read += 1
            if packet.streamIndex == videoIndex, offset == nil {
                offset = (usesDTS && packet.pts != FF.noPTS && packet.dts != FF.noPTS) ? packet.pts - packet.dts : 0
                firstSample = Array(UnsafeBufferPointer(start: packet.pointer.pointee.data, count: Int(packet.pointer.pointee.size)))
            } else if pendingEAC3.contains(packet.streamIndex) {
                pendingEAC3.remove(packet.streamIndex)
                if decodedProfile(packet, stream: demuxer.stream(packet.streamIndex)) == AV_PROFILE_EAC3_DDP_ATMOS {
                    atmos.insert(packet.streamIndex)
                }
            }
        }
        return (offset ?? 0, atmos, firstSample)
    }

    private static func decodedProfile(_ packet: Packet, stream: UnsafeMutablePointer<AVStream>) -> Int32? {
        guard let decoder = avcodec_find_decoder(stream.codecpar.pointee.codec_id) else { return nil }
        var ctx = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&ctx) }
        guard let ctx, avcodec_parameters_to_context(ctx, stream.codecpar) >= 0, avcodec_open2(ctx, decoder, nil) >= 0 else { return nil }
        let frame = Frame()
        guard avcodec_send_packet(ctx, packet.pointer) >= 0 else { return nil }
        _ = avcodec_receive_frame(ctx, frame.pointer)
        return ctx.pointee.profile
    }

    /// The container's transfer function, or the one in the bitstream's VUI when the
    /// container is silent (x265 output muxed without Matroska Colour elements). The
    /// HEVC decoder exports VUI colour info while parsing hvcC at open, no frame needed.
    private static func transferCharacteristics(_ par: UnsafeMutablePointer<AVCodecParameters>) -> AVColorTransferCharacteristic {
        let declared = par.pointee.color_trc
        guard declared == AVCOL_TRC_UNSPECIFIED || declared == AVCOL_TRC_RESERVED0 || declared == AVCOL_TRC_RESERVED,
              par.pointee.extradata_size > 0,
              let decoder = avcodec_find_decoder(par.pointee.codec_id) else { return declared }
        var ctx = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&ctx) }
        guard let ctx, avcodec_parameters_to_context(ctx, par) >= 0 else { return declared }
        ctx.pointee.thread_count = 1
        guard avcodec_open2(ctx, decoder, nil) >= 0 else { return declared }
        return ctx.pointee.color_trc
    }

    private static func bitRate(_ stream: UnsafeMutablePointer<AVStream>) -> Int64? {
        if stream.codecpar.pointee.bit_rate > 0 { return stream.codecpar.pointee.bit_rate }
        for key in ["BPS", "BPS-eng"] {
            if let value = stream.metadata(key), let bps = Int64(value), bps > 0 { return bps }
        }
        return nil
    }
}
