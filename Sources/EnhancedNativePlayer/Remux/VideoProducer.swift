import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Lossless video remux into `video_{n}.mp4` segments cut at the planned keyframes.
struct VideoProducer: SegmentProducer {
    let context: RemuxContext
    /// Set for the `video_sdr_{n}.mp4` rendition.
    var rewriter: SDRBitstreamRewriter?

    func produce(_ run: RemuxRun) throws {
        let media = context.media
        let plan = context.plan
        let video = rewriter == nil ? media.video : media.video.sdrVariant
        let usesDTS = media.keyframes.usesDecodeTimestamps

        let demuxer = try Demuxer(file: context.file, token: run.token, findStreamInfo: false)
        let input = demuxer.stream(video.streamIndex)
        demuxer.discardAll(except: [video.streamIndex])

        let start = run.startSegment
        let target = plan.segments[start].start
        if start > 0 {
            // Seek straight to the segment's keyframe as listed in the index. The
            // demuxer lands on the index entry at or before it, never after, and the
            // loop below drops anything earlier, so no nudge past the keyframe is
            // needed (and none could land on the following keyframe instead).
            try demuxer.seek(stream: video.streamIndex, timestamp: target)
        }

        let writer = try FragmentedMP4Writer { try Self.configure($0, from: input, video: video, rewriter: rewriter) }
        let emitter = SegmentEmitter(writer: writer, run: run)
        let inTB = video.timeBase
        let outTB = emitter.timeBase
        let offset = context.timeline.offset(in: inTB)

        // Matroska stores presentation times only; decode times are assigned per segment.
        let assigner: DecodeTimestampAssigner? = usesDTS ? nil : DecodeTimestampAssigner(shift: Int64(max(video.reorderDepth, 2)) * video.frameDuration)

        func emit(_ packet: Packet, segment: Int) throws {
            if packet.pts != FF.noPTS { packet.pts = inTB.rescale(packet.pts + offset, to: outTB) }
            if packet.dts != FF.noPTS { packet.dts = inTB.rescale(packet.dts + offset, to: outTB) }
            packet.duration = 0
            try emitter.push(packet, segment: segment)
        }

        let packet = Packet()
        var current = start
        var started = false
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == video.streamIndex else { continue }
            let ts = usesDTS ? packet.dts : packet.pts
            if !started {
                guard ts != FF.noPTS, packet.isKeyframe, ts >= target else { continue }
                started = true
            } else if packet.isKeyframe, ts != FF.noPTS {
                while current + 1 < plan.count, ts >= plan.segments[current + 1].start {
                    current += 1
                }
            }
            let copy = packet.clone()
            if let rewriter { try copy.rewrite(with: rewriter) }
            if let assigner {
                for (assigned, segment) in assigner.push(copy, segment: current) {
                    try emit(assigned, segment: segment)
                }
            } else {
                try emit(copy, segment: current)
            }
        }
        if let assigner {
            for (assigned, segment) in assigner.drain() {
                try emit(assigned, segment: segment)
            }
        }
        try emitter.finish(fallbackDuration: inTB.rescale(video.frameDuration, to: outTB))
    }

    /// Stream copy with the sample entry AVPlayer needs: `hvc1` for HEVC, `dvh1` for
    /// Dolby Vision profiles 5 and 8 (with their dvcC/dvvC). Profile 7, and Dolby
    /// Vision on H.264, lose the configuration record and play as the base layer.
    /// With a rewriter the track also leaves here labeled as Rec. 709, without HDR metadata.
    static func configure(_ output: UnsafeMutablePointer<AVStream>, from input: UnsafeMutablePointer<AVStream>, video: VideoTrack, rewriter: SDRBitstreamRewriter? = nil) throws {
        try FF.check(avcodec_parameters_copy(output.codecpar, input.codecpar), "avcodec_parameters_copy")
        output.codecpar.pointee.codec_tag = FF.tag(video.sampleEntry)
        if !video.emitsDolbyVision {
            av_packet_side_data_remove(output.codecpar.pointee.coded_side_data, &output.codecpar.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
        }
        if let rewriter {
            let par = output.codecpar
            for type in [AV_PKT_DATA_MASTERING_DISPLAY_METADATA, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT] {
                av_packet_side_data_remove(par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, type)
            }
            par.pointee.color_primaries = AVCOL_PRI_BT709
            par.pointee.color_trc = AVCOL_TRC_BT709
            par.pointee.color_space = AVCOL_SPC_BT709
        }
        // The probe's record, not the container's, which may lack the parameter sets.
        let record = rewriter?.extradata ?? video.extradata
        let par = output.codecpar
        av_freep(&par.pointee.extradata)
        guard let extradata = av_mallocz(record.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self) else {
            par.pointee.extradata_size = 0
            throw EnhancedPlayerError.ffmpeg(operation: "av_mallocz", code: -ENOMEM, message: "out of memory")
        }
        extradata.update(from: record, count: record.count)
        par.pointee.extradata = extradata
        par.pointee.extradata_size = Int32(record.count)
        output.pointee.time_base = input.pointee.time_base
    }
}

/// Gives a pts-only stream (Matroska) decode timestamps that depend on nothing but the
/// segment's own packets: the i-th packet of a segment in decode order gets the i-th
/// smallest pts of that segment, minus a fixed reorder shift. This is the dts the
/// encoder had, and it is the same whether a run reached the segment from the start
/// of the file or seeked to it.
final class DecodeTimestampAssigner {
    private let shift: Int64
    private let window = 32
    private var queue: [(Packet, Int)] = []
    private var sortedPTS: [Int64] = []

    init(shift: Int64) {
        self.shift = shift
    }

    func push(_ packet: Packet, segment: Int) -> [(Packet, Int)] {
        var out: [(Packet, Int)] = []
        if let last = queue.last, last.1 != segment {
            out = drain()
        }
        queue.append((packet, segment))
        insert(packet.pts == FF.noPTS ? (sortedPTS.last ?? 0) : packet.pts)
        while queue.count > window {
            out.append(popHead())
        }
        return out
    }

    func drain() -> [(Packet, Int)] {
        var out: [(Packet, Int)] = []
        while !queue.isEmpty { out.append(popHead()) }
        return out
    }

    private func popHead() -> (Packet, Int) {
        let (packet, segment) = queue.removeFirst()
        packet.dts = sortedPTS.removeFirst() - shift
        if packet.pts == FF.noPTS { packet.pts = packet.dts + shift }
        return (packet, segment)
    }

    private func insert(_ value: Int64) {
        var low = 0
        var high = sortedPTS.count
        while low < high {
            let mid = (low + high) / 2
            if sortedPTS[mid] <= value { low = mid + 1 } else { high = mid }
        }
        sortedPTS.insert(value, at: low)
    }
}
