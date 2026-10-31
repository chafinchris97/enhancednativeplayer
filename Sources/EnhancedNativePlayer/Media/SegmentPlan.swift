import Foundation

/// The segment layout of the whole file, computed once from the keyframe list.
///
/// The cut rule is libavformat's `hlsenc.c` (`hls_write_packet`) verbatim: with
/// `start_pts` the first packet's timestamp and `number` starting at 1, a segment
/// ends at the first keyframe whose `pts - start_pts >= hls_time * number` (an exact
/// `av_compare_ts`) and which lies after the previous cut; `number` then advances
/// by one. The targets therefore sit on a fixed grid from `start_pts`, they do not
/// restart from each cut, so a long GOP is followed by short segments catching up.
///
/// The plan is the single source of truth for every remux run. A run started at
/// segment k cuts exactly at these timestamps instead of re-deriving cuts from its
/// own start, which is why segment k has the same boundaries (and the same bytes)
/// whether the run started at 0 or at k.
struct SegmentPlan: Sendable {
    struct Segment: Sendable, Equatable {
        var index: Int
        /// First keyframe of the segment, in index timestamps (video time base).
        var start: Int64
        /// First keyframe of the next segment, or the stream end for the last one.
        var end: Int64
        var duration: Double
        /// Position in the playlist timeline in 100 ns ticks.
        var runtimeTicks: Int64
    }

    let timeBase: Rational
    let segments: [Segment]
    /// `start_pts`: the first keyframe.
    let origin: Int64

    init(keyframes: [Int64], timeBase: Rational, hlsTime: Double, end: Int64) {
        precondition(!keyframes.isEmpty)
        self.timeBase = timeBase
        // hls_time is an AV_OPT_TYPE_DURATION, i.e. microseconds.
        let hlsTimeMicroseconds = Int64((hlsTime * 1_000_000).rounded())
        let start = keyframes[0]
        var cuts = [start]
        var number: Int64 = 1
        var lastCut = start
        for keyframe in keyframes.dropFirst() where keyframe - lastCut > 0 {
            // av_compare_ts(pkt->pts - start_pts, st->time_base, end_pts, AV_TIME_BASE_Q) >= 0
            if Self.compare(keyframe - start, timeBase, hlsTimeMicroseconds * number, .microseconds) >= 0 {
                cuts.append(keyframe)
                lastCut = keyframe
                number += 1
            }
        }
        let streamEnd = max(end, cuts.last! + 1)
        var segments: [Segment] = []
        segments.reserveCapacity(cuts.count)
        for (i, cut) in cuts.enumerated() {
            let next = i + 1 < cuts.count ? cuts[i + 1] : streamEnd
            segments.append(Segment(
                index: i,
                start: cut,
                end: next,
                duration: timeBase.seconds(next - cut),
                runtimeTicks: Self.rescale(cut - start, timeBase, .ticks)
            ))
        }
        self.segments = segments
        self.origin = start
    }

    var count: Int { segments.count }

    /// `EXT-X-TARGETDURATION` the way hlsenc computes it: `lrint` of the longest segment.
    var targetDuration: Int {
        Int(segments.map(\.duration).max()!.rounded(.toNearestOrEven))
    }

    /// The segment whose start is at or before `ticks`.
    func segmentIndex(forRuntimeTicks ticks: Int64) -> Int {
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].runtimeTicks <= ticks { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: - Exact arithmetic

    /// Sign of `a·tbA − b·tbB`, without overflow.
    static func compare(_ a: Int64, _ tbA: Rational, _ b: Int64, _ tbB: Rational) -> Int {
        let lhs = Int64(tbA.num) * Int64(tbB.den)
        let rhs = Int64(tbB.num) * Int64(tbA.den)
        let left = a.multipliedFullWidth(by: lhs)
        let right = b.multipliedFullWidth(by: rhs)
        if left.high != right.high { return left.high < right.high ? -1 : 1 }
        if left.low != right.low { return left.low < right.low ? -1 : 1 }
        return 0
    }

    /// `ts` converted from `from` to `to`, rounded to nearest.
    static func rescale(_ ts: Int64, _ from: Rational, _ to: Rational) -> Int64 {
        let numerator = Int64(from.num) * Int64(to.den)
        let denominator = Int64(from.den) * Int64(to.num)
        let product = ts.multipliedFullWidth(by: numerator)
        let (quotient, remainder) = denominator.dividingFullWidth(product)
        if remainder.magnitude * 2 >= denominator.magnitude {
            return quotient + ((ts < 0) != (denominator < 0) ? -1 : 1)
        }
        return quotient
    }
}
