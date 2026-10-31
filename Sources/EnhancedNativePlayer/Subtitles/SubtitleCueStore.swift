import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Reads and keeps the cues of each requested subtitle segment. Cues are small, so a
/// segment is read once per session. Reads don't wait on one another, so a seek starts
/// right away even while the segment it abandoned is still being read.
actor SubtitleCueStore {
    private struct Key: Hashable {
        let track: Int
        let segment: Int
    }

    private let context: RemuxContext
    private var loaded: [Key: [SubtitleCue]] = [:]
    private var loading: [Key: Task<[SubtitleCue], Error>] = [:]

    init(context: RemuxContext) {
        self.context = context
    }

    func cues(track: SubtitleTrack, format: SubtitleTextFormat, segment: Int) async throws -> [SubtitleCue] {
        let key = Key(track: track.index, segment: segment)
        if let cues = loaded[key] { return cues }
        if let task = loading[key] { return try await task.value }
        let context = context
        let task = Task {
            try await runBlocking(label: "ENP.subtitle") {
                try SubtitleCueReader.read(context: context, track: track, format: format, segment: segment)
            }
        }
        loading[key] = task
        defer { loading[key] = nil }
        let cues = try await task.value
        loaded[key] = cues
        return cues
    }
}

/// Finds a segment's cues the way a remux run finds its packets: seek on the video's
/// keyframe index, then read forward over just that stretch of the file. A cue belongs
/// to the segment its start lands in, wherever it ends.
enum SubtitleCueReader {
    /// Muxers place a cue near its time, not exactly on it, so the read overlaps the
    /// segment by this much on both sides.
    private static let marginTicks: Int64 = 10_000_000
    /// For a packet with no duration.
    private static let fallbackDurationTicks: Int64 = 30_000_000

    static func read(context: RemuxContext, track: SubtitleTrack, format: SubtitleTextFormat, segment: Int) throws -> [SubtitleCue] {
        let grid = context.subtitleGrid
        let start = grid.startTicks(of: segment)
        let end = grid.endTicks(of: segment)
        let stop = end + marginTicks
        let video = context.media.video
        let originTicks = video.timeBase.rescaleNearest(context.timeline.originPresentation, to: .ticks)

        // MP4 sample tables jump straight from one cue to the next. Matroska has to walk
        // the clusters, and a sparse track could have no next cue for most of the file,
        // so the video stays on there: its packets say when the segment has been passed.
        let demuxer = try Demuxer(file: context.file, token: context.token, findStreamInfo: false)
        let walksFile = !context.media.keyframes.usesDecodeTimestamps
        demuxer.discardAll(except: walksFile ? [track.streamIndex, video.streamIndex] : [track.streamIndex])
        if segment > 0 {
            let target = Rational.ticks.rescaleNearest(originTicks + start - marginTicks, to: video.timeBase)
            try demuxer.seek(stream: video.streamIndex, timestamp: max(context.timeline.originPresentation, target))
        }

        var cues: [SubtitleCue] = []
        let packet = Packet()
        while try demuxer.read(into: packet) {
            let ts = packet.pts != FF.noPTS ? packet.pts : packet.dts
            guard ts != FF.noPTS else { continue }
            if packet.streamIndex == video.streamIndex {
                if video.timeBase.rescaleNearest(ts, to: .ticks) - originTicks >= stop { break }
                continue
            }
            guard packet.streamIndex == track.streamIndex else { continue }
            let position = track.timeBase.rescaleNearest(ts, to: .ticks) - originTicks
            if position >= stop { break }
            // Cues from before the first keyframe count toward the first segment.
            guard position < end, position >= start || segment == 0 else { continue }

            let payload = Array(UnsafeBufferPointer(start: packet.pointer.pointee.data, count: Int(packet.pointer.pointee.size)))
            guard let text = WebVTT.cueText(payload: payload, format: format) else { continue }
            let duration = packet.duration > 0 ? track.timeBase.rescaleNearest(packet.duration, to: .ticks) : fallbackDurationTicks
            let cueEnd = position + duration
            guard cueEnd > 0 else { continue }
            cues.append(SubtitleCue(
                startTicks: max(0, position),
                endTicks: cueEnd,
                text: text,
                settings: format == .webVTT ? settings(of: packet) : nil
            ))
        }
        return cues.sorted { $0.startTicks < $1.startTicks }
    }

    private static func settings(of packet: Packet) -> String? {
        var size = 0
        guard let data = av_packet_get_side_data(packet.pointer, AV_PKT_DATA_WEBVTT_SETTINGS, &size), size > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: data, count: size), as: UTF8.self)
    }
}
