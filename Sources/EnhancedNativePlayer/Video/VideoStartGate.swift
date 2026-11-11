import Foundation
import Logging

/// Holds the first video segment of each run of requests until the player has decoded the frame
/// AVPlayer will start on, for video the player draws itself.
///
/// AVPlayer decodes its own picture before it starts its clock, but not ours, so after a seek it
/// would start the audio while the decoder still works from the keyframe before the target. It
/// does wait for the seek's segment, though: it asks for it right after the seek, reports the
/// seek's target as its current time about 50 ms later, and moves its clock only once that segment
/// is complete. So the server holds that segment until the frame at the target is queued, and
/// AVPlayer waits the way it waits for any slow segment, with picture and sound then starting
/// together. A load's first segment is held the same way.
///
/// This only works for the segments AVPlayer asks for: a seek inside what it has already loaded
/// asks for nothing, and the decoder catches up after it instead.
final class VideoStartGate: @unchecked Sendable {
    /// What the renderer tells the gate. Every closure can be called from any thread.
    struct Source: Sendable {
        /// AVPlayer's current time on the playlist timeline, 100 ns ticks; nil without an item.
        var reportedTicks: @Sendable () async -> Int64?
        /// Starts decoding for a time before AVPlayer's clock gets there.
        var decode: @Sendable (Int64) -> Void
        /// Whether the frame on screen at a time is queued.
        var covers: @Sendable (Int64) -> Bool
        /// Frames decoded so far.
        var progress: @Sendable () -> Int
    }

    /// The longest a segment is held.
    static let timeout: Duration = .seconds(5)
    /// A decoder that has started and then decodes nothing for this long is not waited for any more.
    static let stall: Duration = .seconds(2)
    /// How long AVPlayer gets to report the seek's target, which it does about 50 ms after asking.
    static let reportWait: Duration = .milliseconds(250)
    /// How long a load's first segment waits for the renderer to be there at all.
    static let sourceWait: Duration = .milliseconds(1500)
    /// A reported time this far before a segment still starts in it (the frame AVPlayer shows first).
    static let earlyTicks: Int64 = 10_000_000

    private let lock = NSLock()
    private var source: Source?
    private var lastRequested: Int?

    /// The renderer's view of things, or nil when it goes away.
    func attach(_ source: Source?) {
        lock.withLock { self.source = source }
    }

    /// Whether a request for video segment `index` starts a new run: the first one, or any other
    /// than the one after the last. Such a request is most likely a seek's, and is given time
    /// for AVPlayer to report the seek's target.
    func startsRun(_ index: Int) -> Bool {
        lock.withLock {
            let starts = lastRequested.map { index != $0 + 1 } ?? true
            lastRequested = index
            return starts
        }
    }

    /// Waits until the frame AVPlayer starts on in the segment covering `range` (playlist ticks)
    /// is queued, or until it is clear that waiting won't get it. Nothing is held unless AVPlayer
    /// reports a time in the segment: anything else is AVPlayer filling its buffer ahead.
    /// `startsRun` gives AVPlayer `reportWait` to report it; any other request is looked at once.
    func hold(segment index: Int, range: Range<Int64>, startsRun: Bool, logger: Logger) async {
        let began = ContinuousClock.now
        var source = lock.withLock { self.source }
        while source == nil, startsRun, ContinuousClock.now - began < Self.sourceWait {
            try? await Task.sleep(for: .milliseconds(20))
            source = lock.withLock { self.source }
        }
        guard let source, !Task.isCancelled else { return }

        // AVPlayer reports a seek's target shortly after asking for its segment.
        var target: Int64?
        let asked = ContinuousClock.now
        repeat {
            if let reported = await source.reportedTicks(), reported >= range.lowerBound - Self.earlyTicks, reported < range.upperBound {
                target = max(reported, range.lowerBound)
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        } while startsRun && ContinuousClock.now - asked < Self.reportWait
        guard let landing = target, !source.covers(landing) else { return }
        source.decode(landing)

        // Opening a decoder and fetching its first data can take a while: until it has decoded
        // something, only the overall timeout applies.
        var progress = source.progress()
        var progressed: ContinuousClock.Instant?
        while !Task.isCancelled {
            if source.covers(landing) {
                logger.info("video_\(index).mp4 held \(ContinuousClock.now - began) until the frame at \(String(format: "%.3f", Double(landing) / 1e7)) s was decoded")
                return
            }
            let now = ContinuousClock.now
            if now - began >= Self.timeout {
                logger.warning("video_\(index).mp4: the frame at \(String(format: "%.3f", Double(landing) / 1e7)) s wasn't decoded within \(Self.timeout); serving it anyway")
                return
            }
            let current = source.progress()
            if current != progress {
                progress = current
                progressed = now
            } else if let progressed, now - progressed >= Self.stall {
                logger.warning("video_\(index).mp4: the decoder made no progress for \(Self.stall); serving it anyway")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
