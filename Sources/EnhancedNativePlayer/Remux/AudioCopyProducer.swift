import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Opens a demuxer for one audio track, positioned so that segment `start` can be
/// produced: a second before the segment's start, so the packet (or decoded sample)
/// straddling the boundary is read, and decoders are warmed up by the time they
/// reach it. Anything before the boundary is dropped by the caller.
func openAudioDemuxer(context: RemuxContext, track: AudioTrack, start: Int, token: CancellationToken) throws -> Demuxer {
    let demuxer = try Demuxer(file: context.file, token: token, findStreamInfo: false)
    demuxer.discardAll(except: [track.streamIndex])
    if start > 0 {
        let video = context.media.video
        let first = context.presentationStart(of: 0)
        let boundary = context.presentationStart(of: start)
        let target = max(first, boundary - Rational.microseconds.rescale(1_000_000, to: video.timeBase))
        // Seek on the video stream by name, since its index is the keyframe index. Stream
        // -1 would pick this demuxer's only undiscarded stream, the audio, which has no
        // Matroska Cues, and libavformat would then read the file from the start to get there.
        try demuxer.seek(stream: video.streamIndex, timestamp: target)
    }
    return demuxer
}

/// Segment index for an audio timestamp: the segment whose video start is the last one
/// at or before it. Audio is cut at the video cuts, so an audio segment begins with the
/// first audio frame starting at or after the video segment's first keyframe.
struct AudioSegmentClock {
    let context: RemuxContext
    let timeBase: Rational
    private let boundaries: [Int64]
    private let videoTB: Rational

    init(context: RemuxContext, timeBase: Rational) {
        self.context = context
        self.timeBase = timeBase
        self.videoTB = context.media.video.timeBase
        self.boundaries = (0..<context.plan.count).map { context.presentationStart(of: $0) }
    }

    func isBefore(_ ts: Int64, segment: Int) -> Bool {
        compareTimestamps(ts, timeBase, boundaries[segment], videoTB) < 0
    }

    func advance(_ current: Int, for ts: Int64) -> Int {
        var segment = current
        while segment + 1 < boundaries.count, !isBefore(ts, segment: segment + 1) {
            segment += 1
        }
        return segment
    }
}

/// Stream copy for AAC, AC-3, E-AC-3 (including Atmos JOC) and FLAC.
struct AudioCopyProducer: SegmentProducer {
    let context: RemuxContext
    let track: AudioTrack

    func produce(_ run: RemuxRun) throws {
        let start = run.startSegment
        let demuxer = try openAudioDemuxer(context: context, track: track, start: start, token: run.token)
        let input = demuxer.stream(track.streamIndex)
        let writer = try FragmentedMP4Writer { try Self.configure($0, from: input) }
        let emitter = SegmentEmitter(writer: writer, run: run, segmentCount: context.plan.count)
        let inTB = track.timeBase
        let outTB = emitter.timeBase
        let offset = context.timeline.offset(in: inTB)
        let clock = AudioSegmentClock(context: context, timeBase: inTB)

        let packet = Packet()
        var current = start
        var lastDuration: Int64 = 0
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == track.streamIndex else { continue }
            let ts = packet.pts != FF.noPTS ? packet.pts : packet.dts
            guard ts != FF.noPTS else { continue }
            if start > 0, clock.isBefore(ts, segment: start) { continue }
            current = clock.advance(current, for: ts)

            let copy = packet.clone()
            copy.pts = inTB.rescale(ts + offset, to: outTB)
            copy.dts = copy.pts
            lastDuration = inTB.rescale(packet.duration, to: outTB)
            copy.duration = 0
            try emitter.push(copy, segment: current)
        }
        try emitter.finish(fallbackDuration: lastDuration)
    }

    static func configure(_ output: UnsafeMutablePointer<AVStream>, from input: UnsafeMutablePointer<AVStream>) throws {
        try FF.check(avcodec_parameters_copy(output.codecpar, input.codecpar), "avcodec_parameters_copy")
        output.codecpar.pointee.codec_tag = 0
        output.pointee.time_base = input.pointee.time_base
    }
}
