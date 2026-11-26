import EPLibavcodec
import EPLibavformat
import EPLibavutil
import Compression
import Foundation

/// Reads and keeps what each requested subtitle segment holds. Reads don't wait on one
/// another, so a seek starts right away even while the segment it abandoned is still being read.
actor SubtitleSegmentCache<Value: Sendable> {
    private struct Key: Hashable {
        let track: Int
        let segment: Int
    }

    private var loaded: [Key: Value] = [:]
    private var loading: [Key: Task<Value, Error>] = [:]

    func value(track: Int, segment: Int, read: @escaping @Sendable () throws -> Value) async throws -> Value {
        let key = Key(track: track, segment: segment)
        if let value = loaded[key] { return value }
        if let task = loading[key] { return try await task.value }
        let task = Task {
            try await runBlocking(label: "ENP.subtitle", read)
        }
        loading[key] = task
        defer { loading[key] = nil }
        let value = try await task.value
        loaded[key] = value
        return value
    }

    /// Forgets all but `segments` of `track`.
    func retain(track: Int, segments: ClosedRange<Int>) {
        loaded = loaded.filter { $0.key.track == track && segments.contains($0.key.segment) }
    }
}

/// Finds a segment's packets the way a remux run finds its own: seek on the video's
/// keyframe index, then read forward over just that stretch of the file. A packet belongs
/// to the segment its start lands in, wherever it ends.
enum SubtitlePacketReader {
    /// Muxers place a cue near its time, not exactly on it, so the read overlaps the
    /// segment by this much on both sides.
    private static let marginTicks: Int64 = 10_000_000

    /// Calls `body` with each of the segment's packets and its position in the playlist timeline.
    /// Where the read walks the video too (Matroska), `videoFrame` gets the position of each
    /// video frame that starts in the segment, in demux order.
    static func forEachPacket(context: RemuxContext, track: SubtitleTrack, segment: Int, videoFrame: ((Int64) -> Void)? = nil, body: (Packet, Int64) throws -> Void) throws {
        let grid = context.subtitleGrid
        let start = grid.startTicks(of: segment)
        let end = grid.endTicks(of: segment)
        let stop = end + marginTicks
        let video = context.media.video
        let originTicks = video.timeBase.rescaleNearest(context.timeline.originPresentation, to: .ticks)

        // MP4 sample tables jump straight from one cue to the next. Matroska has to walk
        // the clusters, and a sparse track could have no next cue for most of the file,
        // so the video stays on there: its packets say when the segment has been passed.
        let demuxer = try Demuxer(file: context.file, token: context.token, findStreamInfo: false, role: .subtitles)
        let walksFile = !context.media.keyframes.usesDecodeTimestamps
        demuxer.discardAll(except: walksFile ? [track.streamIndex, video.streamIndex] : [track.streamIndex])
        if segment > 0 {
            let target = Rational.ticks.rescaleNearest(originTicks + start - marginTicks, to: video.timeBase)
            try demuxer.seek(stream: video.streamIndex, timestamp: max(context.timeline.originPresentation, target))
        }

        let packet = Packet()
        while try demuxer.read(into: packet) {
            let ts = packet.pts != FF.noPTS ? packet.pts : packet.dts
            guard ts != FF.noPTS else { continue }
            if packet.streamIndex == video.streamIndex {
                let position = video.timeBase.rescaleNearest(ts, to: .ticks) - originTicks
                if position >= stop { break }
                if position >= start, position < end { videoFrame?(position) }
                continue
            }
            guard packet.streamIndex == track.streamIndex else { continue }
            let position = track.timeBase.rescaleNearest(ts, to: .ticks) - originTicks
            if position >= stop { break }
            // Cues from before the first keyframe count toward the first segment.
            guard position < end, position >= start || segment == 0 else { continue }
            try body(packet, position)
        }
    }
}

extension Packet {
    var subtitlePayload: [UInt8] {
        MatroskaCompression.inflated(Array(UnsafeBufferPointer(start: pointer.pointee.data, count: Int(pointer.pointee.size))))
    }
}

/// mkvmerge zlib-compresses PGS tracks by default, and this FFmpeg build has no zlib: the
/// demuxer logs "Unsupported encoding type" and hands over the blocks still compressed.
/// libavformat doesn't say which tracks those are, so the payload itself has to.
enum MatroskaCompression {
    private static let maxInflatedBytes = 64 << 20

    /// The inflated bytes of a zlib stream, or `payload` as it is if it isn't one.
    static func inflated(_ payload: [UInt8]) -> [UInt8] {
        // CMF says deflate, and CMF and FLG together are a multiple of 31. No preset dictionary.
        guard payload.count > 2, payload[0] & 0x0F == 8, (Int(payload[0]) << 8 | Int(payload[1])) % 31 == 0, payload[1] & 0x20 == 0 else { return payload }
        var capacity = max(payload.count * 8, 64 << 10)
        while capacity <= maxInflatedBytes {
            var output = [UInt8](repeating: 0, count: capacity)
            // COMPRESSION_ZLIB is raw deflate, without the two-byte header.
            let count = payload.withUnsafeBufferPointer { input in
                compression_decode_buffer(&output, capacity, input.baseAddress! + 2, input.count - 2, nil, COMPRESSION_ZLIB)
            }
            if count == 0 { return payload }
            if count < capacity { return Array(output[..<count]) }
            capacity *= 2
        }
        return payload
    }
}

/// Reads a segment's cues straight from its packets, without a decoder.
enum SubtitleCueReader {
    /// For a packet with no duration.
    private static let fallbackDurationTicks: Int64 = 30_000_000

    static func read(context: RemuxContext, track: SubtitleTrack, format: SubtitleTextFormat, segment: Int) throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        try SubtitlePacketReader.forEachPacket(context: context, track: track, segment: segment) { packet, position in
            guard let text = WebVTT.cueText(payload: packet.subtitlePayload, format: format) else { return }
            let duration = packet.duration > 0 ? track.timeBase.rescaleNearest(packet.duration, to: .ticks) : fallbackDurationTicks
            let cueEnd = position + duration
            guard cueEnd > 0 else { return }
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

/// Turns a PGS track into frames around the playhead. Unlike cues, a segment's frames
/// can't stand alone and its bitmaps aren't small, so earlier segments are read as needed
/// and only the ones near the playhead are kept.
final class PGSFrameStore: Sendable {
    /// How far back, in segments, a read looks for what is on screen as a segment starts
    /// and for the objects its display sets lean on.
    static let lookback = 3

    private let context: RemuxContext
    private let cache = SubtitleSegmentCache<[PGSDisplaySet]>()

    init(context: RemuxContext) {
        self.context = context
    }

    /// Every frame known to matter from the start of `segment` to its end, in order. The
    /// last one at or before a time in the segment is what shows then.
    func frames(track: SubtitleTrack, segment: Int) async throws -> [PGSFrame] {
        let first = max(0, segment - Self.lookback)
        await cache.retain(track: track.index, segments: first...(segment + 1))
        let segmentStart = context.subtitleGrid.startTicks(of: segment)
        var sets = try await displaySets(track: track, segment: segment)
        var earliest = segment
        while earliest > first {
            let hasEarlierState = sets.first.map { $0.startTicks <= segmentStart } ?? false
            if hasEarlierState, PGSCompositor.replay(sets).isComplete { break }
            earliest -= 1
            sets = try await displaySets(track: track, segment: earliest) + sets
        }
        return PGSCompositor.replay(sets).frames
    }

    private func displaySets(track: SubtitleTrack, segment: Int) async throws -> [PGSDisplaySet] {
        let context = context
        return try await cache.value(track: track.index, segment: segment) {
            var parser = PGSParser()
            try SubtitlePacketReader.forEachPacket(context: context, track: track, segment: segment) { packet, position in
                parser.append(payload: packet.subtitlePayload, ticks: position)
            }
            return parser.finish()
        }
    }
}
