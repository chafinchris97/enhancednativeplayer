import Foundation

/// The output clock shared by video and audio.
///
/// Every packet keeps its source timestamp and is moved by one constant, so each
/// segment's `tfdt` is the same no matter which run produced it, and video and
/// audio renditions stay in sync across independent restarts. The first keyframe
/// lands at 10 s, the lead-in Apple's own segmenter uses, which keeps the decode
/// times of reordered frames and of audio that starts early above zero.
struct Timeline: Sendable {
    static let leadInMicroseconds: Int64 = 10_000_000

    let videoTimeBase: Rational
    /// Presentation time of the first keyframe, video time base.
    let originPresentation: Int64

    /// Amount added to a timestamp in `timeBase` to put it on the output clock.
    func offset(in timeBase: Rational) -> Int64 {
        Rational.microseconds.rescaleNearest(Self.leadInMicroseconds, to: timeBase)
            - videoTimeBase.rescaleNearest(originPresentation, to: timeBase)
    }
}

/// Everything a remux run needs, fixed for the session.
final class RemuxContext: Sendable {
    let file: RemoteFile
    let media: MediaInfo
    let plan: SegmentPlan
    let subtitleGrid: SubtitleGrid
    let timeline: Timeline
    let token: CancellationToken
    /// Set when the video is HDR and can be relabeled for `master_sdr.m3u8`.
    let sdrRewriter: SDRBitstreamRewriter?

    init(file: RemoteFile, media: MediaInfo, plan: SegmentPlan, token: CancellationToken) {
        self.file = file
        self.media = media
        self.plan = plan
        self.subtitleGrid = SubtitleGrid(totalTicks: plan.timeBase.rescaleNearest(plan.segments.last!.end - plan.origin, to: .ticks))
        self.token = token
        // Rendered video has no bitstream in the playlist to relabel.
        self.sdrRewriter = media.video.isHDR && media.video.rendered == nil ? SDRBitstreamRewriter(codec: media.video.codec, extradata: media.video.extradata) : nil
        self.timeline = Timeline(videoTimeBase: media.keyframes.timeBase, originPresentation: plan.origin + presentationShift(media))
    }

    /// Where the playlist timeline starts in the file's timeline, in 100 ns ticks. A time in
    /// the file minus this is the same moment in the playlist, which is what AVPlayer reports.
    var originTicks: Int64 {
        timeline.videoTimeBase.rescaleNearest(timeline.originPresentation, to: .ticks)
    }

    /// Every keyframe's presentation time on the playlist timeline, 100 ns ticks: the same value
    /// a decoded keyframe's start gets.
    var keyframeTicks: [Int64] {
        let shift = presentationShift(media)
        let tb = media.keyframes.timeBase
        return media.keyframes.timestamps.map { tb.rescaleNearest($0 + shift, to: .ticks) - originTicks }
    }

    /// Presentation time (video time base) at which segment `index` starts.
    func presentationStart(of index: Int) -> Int64 {
        plan.segments[index].start + presentationShift(media)
    }
}

private func presentationShift(_ media: MediaInfo) -> Int64 {
    media.keyframes.usesDecodeTimestamps ? media.keyframes.presentationOffset : 0
}
