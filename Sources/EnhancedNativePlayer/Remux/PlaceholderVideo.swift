import EPLibavcodec
import EPLibavformat
import EPLibavutil
import Foundation

/// The HLS video rendition of a file whose video the player decodes and draws itself.
///
/// AVPlayer still has to play a video track: it is what the system controls, scrubbing, the
/// display mode switch and the screensaver all follow, and what the audio and subtitles are
/// timed against. So the rendition carries one tiny black frame, repeated at the source's frame
/// rate and cut on the same plan as the audio, and the real frames are drawn above it.
///
/// The frames were encoded once, 64×64 and tagged like the source: H.264 Rec. 709 for SDR,
/// HEVC Main 10 BT.2020 with PQ or HLG for HDR, so the master's `VIDEO-RANGE` and the stream
/// agree and the display switches to HDR for an HDR file. An HDR file's `master_sdr.m3u8`
/// carries the SDR stream; the frames drawn above it are the same either way.
enum PlaceholderVideo {
    struct Stream: Sendable {
        var codec: VideoCodec
        /// `avcC` / `hvcC`.
        var record: [UInt8]
        /// One IDR access unit, length-prefixed.
        var sample: [UInt8]
        var profile: Int32
        var level: Int32
        var primaries: AVColorPrimaries
        var transfer: AVColorTransferCharacteristic
        var matrix: AVColorSpace
    }

    static let width = 64
    static let height = 64

    static func stream(for range: VideoRange) -> Stream {
        switch range {
        case .sdr: sdr
        case .pq: pq
        case .hlg: hlg
        }
    }

    /// x264, Constrained Baseline level 1.0, BT.709.
    static let sdr = Stream(
        codec: .h264,
        record: [
            0x01, 0x42, 0xC0, 0x0A, 0xFF, 0xE1, 0x00, 0x19, 0x67, 0x42, 0xC0, 0x0A, 0xD9, 0x04, 0x26, 0xC0,
            0x5A, 0x80, 0x80, 0x80, 0xA0, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x06, 0x01, 0xE2, 0x44,
            0xC9, 0x01, 0x00, 0x05, 0x68, 0xCB, 0x83, 0xCB, 0x20,
        ],
        sample: [
            0x00, 0x00, 0x00, 0x16, 0x65, 0x88, 0x84, 0x0A, 0xF2, 0x62, 0x80, 0x00, 0xA7, 0xBC, 0x9C, 0x9C,
            0x9D, 0x75, 0xD7, 0x5D, 0x75, 0xD7, 0x5D, 0x75, 0xD7, 0x5E,
        ],
        profile: 66,
        level: 10,
        primaries: AVCOL_PRI_BT709,
        transfer: AVCOL_TRC_BT709,
        matrix: AVCOL_SPC_BT709
    )

    /// x265, Main 10 level 1, BT.2020 with PQ.
    static let pq = hevc(transferByte: 0x20, transfer: AVCOL_TRC_SMPTE2084)

    /// The same with HLG: only the SPS's transfer characteristics differ.
    static let hlg = hevc(transferByte: 0x24, transfer: AVCOL_TRC_ARIB_STD_B67)

    private static func hevc(transferByte: UInt8, transfer: AVColorTransferCharacteristic) -> Stream {
        Stream(
            codec: .hevc,
            record: [
                0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1E, 0xF0, 0x00, 0xFC,
                0xFD, 0xFA, 0xFA, 0x00, 0x00, 0x0F, 0x03, 0xA0, 0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0C, 0x01,
                0xFF, 0xFF, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
                0x1E, 0x95, 0x98, 0x09, 0xA1, 0x00, 0x01, 0x00, 0x2D, 0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00,
                0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x1E, 0xA0, 0x20, 0x81, 0x04, 0xD9,
                0x65, 0x66, 0x92, 0x4C, 0xAF, 0x01, 0x6A, 0x12, transferByte, 0x12, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08,
                0x00, 0x00, 0x03, 0x00, 0xC0, 0x40, 0xA2, 0x00, 0x01, 0x00, 0x07, 0x44, 0x01, 0xC1, 0x72, 0xB4,
                0x22, 0x40,
            ],
            sample: [
                0x00, 0x00, 0x00, 0x0E, 0x28, 0x01, 0xAF, 0x1D, 0x80, 0xF7, 0x01, 0x5B, 0xFF, 0xF2, 0x4E, 0xFE,
                0xCC, 0xF0,
            ],
            profile: 2,
            level: 30,
            primaries: AVCOL_PRI_BT2020,
            transfer: transfer,
            matrix: AVCOL_SPC_BT2020_NCL
        )
    }

    /// The placeholder's stream on an fMP4 output, in the source video's time base.
    static func configure(_ output: UnsafeMutablePointer<AVStream>, video: VideoTrack) throws {
        let stream = stream(for: video.range)
        let par = output.codecpar
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = stream.codec == .h264 ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC
        par.pointee.codec_tag = FF.tag(stream.codec == .h264 ? "avc1" : "hvc1")
        par.pointee.width = Int32(width)
        par.pointee.height = Int32(height)
        par.pointee.profile = stream.profile
        par.pointee.level = stream.level
        par.pointee.color_primaries = stream.primaries
        par.pointee.color_trc = stream.transfer
        par.pointee.color_space = stream.matrix
        par.pointee.color_range = AVCOL_RANGE_MPEG
        par.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        guard let extradata = av_mallocz(stream.record.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self) else {
            throw EnhancedPlayerError.ffmpeg(operation: "av_mallocz", code: -ENOMEM, message: "out of memory")
        }
        extradata.update(from: stream.record, count: stream.record.count)
        par.pointee.extradata = extradata
        par.pointee.extradata_size = Int32(stream.record.count)
        output.pointee.time_base = video.timeBase.av
    }

    /// One placeholder frame, a sync sample.
    static func packet(for video: VideoTrack) throws -> Packet {
        let sample = stream(for: video.range).sample
        let packet = Packet()
        try FF.check(av_new_packet(packet.pointer, Int32(sample.count)), "av_new_packet")
        packet.pointer.pointee.data.update(from: sample, count: sample.count)
        packet.pointer.pointee.flags |= AV_PKT_FLAG_KEY
        return packet
    }

    /// `init_video.mp4` (`init_video_sdr.mp4` with `sdr`): the moov movenc writes for the
    /// placeholder's first frame.
    static func initSegment(_ context: RemuxContext, sdr: Bool = false) throws -> Data {
        let video = sdr ? context.media.video.sdrVariant : context.media.video
        let writer = try FragmentedMP4Writer { try configure($0, video: video) }
        let packet = try packet(for: video)
        packet.pts = 0
        packet.dts = 0
        packet.duration = 1
        try writer.write(packet)
        return try writer.flush()
    }

    /// Presentation times of the frames in `segment`, in the video time base: its start, then
    /// one per frame of the source's rate up to the next segment's start. They only depend on
    /// the plan, so a run that starts at any segment writes the same bytes for it.
    static func frameTimes(_ context: RemuxContext, segment: Int) -> [Int64] {
        let plan = context.plan
        let start = context.presentationStart(of: segment)
        let end = segment + 1 < plan.count ? context.presentationStart(of: segment + 1) : plan.segments[segment].end + (start - plan.segments[segment].start)
        let step = frameStep(context.media.video)
        var times: [Int64] = []
        var n = 0.0
        while true {
            let time = start + Int64((n * step).rounded())
            guard time < end else { break }
            if times.last.map({ time > $0 }) ?? true { times.append(time) }
            n += 1
        }
        return times.isEmpty ? [start] : times
    }

    /// One frame of the source's rate in its time base; 24 fps when the rate is unknown.
    private static func frameStep(_ video: VideoTrack) -> Double {
        let rate = video.frameRate.flatMap { $0 > 1 && $0 < 1000 ? $0 : nil } ?? 24
        return 1 / rate / video.timeBase.doubleValue
    }
}

/// Writes `video_{n}.mp4` for a file whose video the player draws: placeholder frames on the
/// plan's cuts, on the same output clock as the audio. Nothing is read from the file.
struct PlaceholderVideoProducer: SegmentProducer {
    let context: RemuxContext
    /// Set for the `video_sdr_{n}.mp4` rendition.
    var sdr = false

    func produce(_ run: RemuxRun) throws {
        let video = sdr ? context.media.video.sdrVariant : context.media.video
        let writer = try FragmentedMP4Writer { try PlaceholderVideo.configure($0, video: video) }
        let emitter = SegmentEmitter(writer: writer, run: run, segmentCount: context.plan.count)
        let inTB = video.timeBase
        let outTB = emitter.timeBase
        let offset = context.timeline.offset(in: inTB)
        let frame = try PlaceholderVideo.packet(for: video)
        for segment in run.startSegment..<context.plan.count {
            try run.token.throwIfCancelled()
            for time in PlaceholderVideo.frameTimes(context, segment: segment) {
                let packet = frame.clone()
                packet.pts = inTB.rescale(time + offset, to: outTB)
                packet.dts = packet.pts
                packet.duration = 0
                try emitter.push(packet, segment: segment)
            }
        }
        try emitter.finish(fallbackDuration: inTB.rescale(video.frameDuration, to: outTB))
    }
}
