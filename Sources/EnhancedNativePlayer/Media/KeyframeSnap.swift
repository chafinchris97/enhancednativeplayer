import Foundation

/// Where a seek in the system controls lands when the player decodes AV1 itself: on a nearby
/// keyframe instead of exactly where it was aimed.
///
/// The decoder starts every seek at the keyframe before the target, and AV1 keyframes are often
/// 5 to 10 s apart, so an exact seek can mean seconds of 4K frames decoded before anything new is
/// shown. Landing on the keyframe itself needs one. Other codecs decode fast enough to stay exact.
enum KeyframeSnap {
    /// The furthest a seek is moved.
    static let reach: Int64 = 100_000_000

    /// The keyframe nearest `target` (playlist ticks) among `keyframes` (ascending), or nil to keep
    /// the seek exact. Nil when no keyframe lies at or after the target (the index may end early),
    /// when the nearest is further than `reach` or than half the seek's own distance (a short skip
    /// stays a skip), and when it lies on the other side of `current` from the target (a forward
    /// seek never lands behind where it started, a backward one never ahead).
    static func landing(target: Int64, current: Int64, keyframes: [Int64], reach: Int64 = reach) -> Int64? {
        guard !keyframes.isEmpty else { return nil }
        let reach = min(reach, abs(target - current) / 2)
        var low = 0
        var high = keyframes.count
        while low < high {
            let mid = (low + high) / 2
            if keyframes[mid] < target { low = mid + 1 } else { high = mid }
        }
        guard low < keyframes.count else { return nil }
        let candidates = [low - 1, low].filter(keyframes.indices.contains).map { keyframes[$0] }
        guard let nearest = candidates.min(by: { abs($0 - target) < abs($1 - target) }), abs(nearest - target) <= reach else { return nil }
        guard target > current ? nearest > current : nearest < current else { return nil }
        return nearest
    }
}
