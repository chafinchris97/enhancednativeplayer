@preconcurrency import AVFoundation
import Foundation
import Logging

/// Keeps a sample buffer renderer supplied with decoded frames a little ahead of its timebase,
/// on a thread of its own.
///
/// The renderer's layer runs on the player item's timebase, so which frame shows when is the
/// layer's business, against the clock the audio plays on: pauses, rate changes and stalls need
/// nothing here. What does is a jump: a seek anywhere but forward inside the frames already
/// queued flushes the renderer (keeping the image on screen) and decodes from the keyframe
/// before the new time.
///
/// After a jump the decoder may be behind the clock for a while. Until it is back on it, frames
/// that would end before the clock are dropped undrawn and the image on screen stays, rather than
/// stuttering; while playing, frames nothing else refers to aren't decoded at all meanwhile,
/// which shortens the catch-up. Once on the clock, a frame that comes late is dropped too, but
/// one is still shown every quarter second, so a decoder that can't keep up shows a slower
/// picture rather than a frozen one.
///
/// The server can name a seek's target before AVPlayer's clock gets there (`decode(at:)`): AVPlayer
/// moves its clock only once the seek's first segment is in, and the server holds that segment
/// until `covers(_:)` says the frame at the target is queued. Until the clock arrives, the target
/// stands in for it.
final class RenderedVideoFeeder: @unchecked Sendable {
    /// How far ahead of the clock frames are queued.
    static let leadTicks: Int64 = 5_000_000
    /// Memory the queued frames may take.
    static let queueBytes = 160 << 20
    /// A catch-up after a seek longer than this is logged: the image has been still that long.
    static let slowCatchUp = Duration.seconds(2)
    /// A clock this close to a target the server named has reached it.
    static let arrivedTicks: Int64 = 10_000_000

    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let token: CancellationToken
    private let maxQueued: Int
    private let makeDecoder: @Sendable () throws -> RenderedVideoDecoder
    private let logger: Logger

    private let condition = NSCondition()
    private var stopped = false
    /// The latest jump, playlist ticks, not yet handled.
    private var jump: Int64?
    /// A target the server named that the clock hasn't reached yet.
    private var pendingTarget: Int64?
    /// The span the queued frames cover, and how many frames have been decoded, for the server.
    private var queuedSpan: Range<Int64>?
    private var decodedFrames = 0

    /// - Parameters:
    ///   - startTicks: Where the clock is now, on the playlist timeline.
    ///   - frameBytes: Size of one converted frame, which limits how many are queued.
    init(renderer: AVSampleBufferVideoRenderer, timebase: CMTimebase, startTicks: Int64, frameBytes: Int, token: CancellationToken, logger: Logger, makeDecoder: @escaping @Sendable () throws -> RenderedVideoDecoder) {
        self.renderer = renderer
        self.logger = logger
        self.timebase = timebase
        self.token = token
        self.maxQueued = min(48, max(4, Self.queueBytes / max(1, frameBytes)))
        self.makeDecoder = makeDecoder
        jump = startTicks
        let thread = Thread { [self] in run() }
        thread.name = "ENP.video"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// The clock moved discontinuously, to `ticks`.
    func timeJumped(to ticks: Int64) {
        condition.lock()
        jump = ticks
        pendingTarget = nil
        condition.signal()
        condition.unlock()
    }

    /// Decodes for `ticks` ahead of the clock getting there: a seek's target, while the server holds
    /// the segment AVPlayer needs to move its clock.
    func decode(at ticks: Int64) {
        condition.lock()
        jump = ticks
        pendingTarget = ticks
        condition.signal()
        condition.unlock()
    }

    /// Whether the frame on screen at `ticks` is queued.
    func covers(_ ticks: Int64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return queuedSpan?.contains(ticks) ?? false
    }

    /// Frames decoded so far, so a waiter can tell a decoder that has stopped making progress.
    var progress: Int {
        condition.lock()
        defer { condition.unlock() }
        return decodedFrames
    }

    /// Ends the thread. The renderer keeps what it shows until its layer goes.
    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
        token.cancel()
    }

    private var timebaseTicks: Int64 {
        CMTimeConvertScale(CMTimebaseGetTime(timebase), timescale: 10_000_000, method: .roundTowardNegativeInfinity).value
    }

    /// The clock, or the server's target while the clock hasn't reached it.
    private var now: Int64 {
        let clock = timebaseTicks
        condition.lock()
        defer { condition.unlock() }
        guard let target = pendingTarget else { return clock }
        if abs(clock - target) < Self.arrivedTicks {
            pendingTarget = nil
            return clock
        }
        return target
    }

    private func publish(_ queued: [(start: Int64, end: Int64)]) {
        condition.lock()
        queuedSpan = queued.first.map { first in first.start..<max(first.start + 1, queued.last!.end) }
        condition.unlock()
    }

    private func run() {
        let decoder: RenderedVideoDecoder
        do {
            decoder = try makeDecoder()
        } catch {
            if !token.isCancelled { logger.error("Video decoder not opened: \(error)") }
            return
        }
        decoder.onFrameDecoded = { [unowned self] in
            condition.lock()
            decodedFrames += 1
            condition.unlock()
        }
        /// Start and end of every frame enqueued and not yet past the clock.
        var queued: [(start: Int64, end: Int64)] = []
        var atEnd = false
        var lastShown = ContinuousClock.now
        /// Set from a seek until a frame is enqueued in time.
        var catchingUp = false
        var caughtUpFrom: ContinuousClock.Instant?
        /// Whether this catch-up has been reported as taking too long.
        var warnedSlowCatchUp = false
        /// The target of the seek under way, until its first frame is enqueued.
        var seekingTo: Int64?
        var stats = Stats()

        while true {
            condition.lock()
            if stopped {
                condition.unlock()
                break
            }
            let jumped = jump
            jump = nil
            condition.unlock()

            let clock = now
            queued.removeAll { $0.end <= clock }
            var seekTarget: Int64?
            if let jumped {
                // Forward inside the queue: the renderer already holds the frames from there on.
                let covered = queued.first.map { $0.start <= jumped } == true && queued.last.map { jumped < $0.end } == true
                // The same target again (the server's, then AVPlayer's): the decoder is already on its way.
                if !covered, jumped != seekingTo { seekTarget = jumped }
            }
            if renderer.status == .failed {
                logger.warning("Video renderer failed: \(String(describing: renderer.error)); restarting at the clock")
                seekTarget = clock
            } else if renderer.requiresFlushToResumeDecoding {
                seekTarget = clock
            }
            if let target = seekTarget {
                logger.info("Video: decoding from the keyframe before \(String(format: "%.3f", Double(target) / 1e7)) s (clock at \(String(format: "%.3f", Double(timebaseTicks) / 1e7)) s)")
                renderer.flush(removingDisplayedImage: false, completionHandler: nil)
                queued = []
                publish(queued)
                atEnd = false
                catchingUp = true
                caughtUpFrom = .now
                warnedSlowCatchUp = false
                seekingTo = target
                do {
                    try decoder.seek(toTicks: target)
                } catch {
                    if token.isCancelled { break }
                    logger.error("Video seek to \(target / 10_000) ms failed: \(error)")
                    atEnd = true
                }
                continue
            }
            publish(queued)

            let ahead = (queued.last?.end ?? clock) - clock
            let enough = atEnd || queued.count >= maxQueued || ahead >= Self.leadTicks
            if enough || !renderer.isReadyForMoreMediaData {
                let waiting = ContinuousClock.now
                condition.lock()
                if !stopped, jump == nil { condition.wait(until: Date(timeIntervalSinceNow: 0.01)) }
                condition.unlock()
                if enough {
                    stats.waitAhead += ContinuousClock.now - waiting
                } else {
                    stats.waitRenderer += ContinuousClock.now - waiting
                }
                continue
            }

            do {
                let started = ContinuousClock.now
                // A seek's first frame takes everything from its keyframe on: not one frame's cost.
                let timesOneFrame = !catchingUp
                // Catching up while the clock runs: frames nothing refers to can go undecoded. Paused,
                // the frame at the target must be the exact one.
                decoder.skipsUnreferencedFrames = catchingUp && CMTimebaseGetRate(timebase) > 0
                let decoded = try decoder.next(skip: { end in
                    guard end <= self.now else { return false }
                    if catchingUp {
                        stats.catchUpDrops += 1
                        return true
                    }
                    if ContinuousClock.now - lastShown >= .milliseconds(250) {
                        stats.forcedShows += 1
                        return false
                    }
                    stats.lateDrops += 1
                    return true
                }, interrupted: { [unowned self] in
                    condition.lock()
                    defer { condition.unlock() }
                    return stopped || jump != nil
                })
                stats.add(decoder.takeStageTimes())
                // Frames are dropped until one is in time, so a decoder slower than playback never
                // gets back on the clock and the image stays where the seek left it.
                if catchingUp, let from = caughtUpFrom, ContinuousClock.now - from > Self.slowCatchUp {
                    stats.slowCatchUp = true
                    if !warnedSlowCatchUp {
                        warnedSlowCatchUp = true
                        logger.warning("Video: still not on the clock \((ContinuousClock.now - from).formatted(.units(allowed: [.milliseconds]))) after the seek; the image stays frozen until a frame is decoded in time")
                    }
                }
                guard let decoded else {
                    atEnd = true
                    continue
                }
                let enqueueing = ContinuousClock.now
                renderer.enqueue(decoded.sample)
                stats.enqueue += ContinuousClock.now - enqueueing
                stats.shown += 1
                if timesOneFrame { stats.worstFrame = max(stats.worstFrame, ContinuousClock.now - started) }
                queued.append((decoded.start, decoded.end))
                publish(queued)
                seekingTo = nil
                lastShown = ContinuousClock.now
                // The frame that ends a catch-up is late by design; only frames on the clock count.
                if timesOneFrame { stats.record(lead: decoded.start - now) }
                if catchingUp, decoded.end > now {
                    catchingUp = false
                    decoder.skipsUnreferencedFrames = false
                    if let from = caughtUpFrom {
                        logger.info("Video: on the clock \((ContinuousClock.now - from).formatted(.units(allowed: [.milliseconds]))) after the seek")
                    }
                    caughtUpFrom = nil
                }
            } catch is RenderedVideoDecoder.Interrupted {
                // A jump or a stop: the loop takes it from here.
                stats.add(decoder.takeStageTimes())
                continue
            } catch {
                if token.isCancelled { break }
                logger.error("Video decoding stopped: \(error)")
                atEnd = true
            }
            // Every 30 s while all is well, every 5 s while frames come late or are dropped.
            let age = ContinuousClock.now - stats.since
            if age > .seconds(30) || (age > .seconds(5) && stats.isDegraded) {
                stats.report(codec: decoder.codecName, frameRate: decoder.frameRate, logger: logger)
                stats = Stats()
            }
        }
        // What the last window saw, so the end of a session isn't missing from the log.
        stats.add(decoder.takeStageTimes())
        stats.report(codec: decoder.codecName, frameRate: decoder.frameRate, logger: logger)
    }
}

/// What the video thread did over a window of playback, for the log: where its time went (reading
/// packets, decoding, converting, enqueueing, and waiting, either with enough queued or on a
/// renderer that takes no more), how far ahead of the clock frames reached the renderer, how many
/// came after their start (and so showed late), and how many were dropped.
private struct Stats {
    let since = ContinuousClock.now
    /// Frames enqueued. While catching up they can still come too late to be seen.
    var shown = 0
    /// How far ahead of the clock each frame on the clock was enqueued.
    var leads: [Int64] = []
    var late = 0
    /// Dropped undrawn on the way back to the clock after a seek: expected.
    var catchUpDrops = 0
    /// Dropped once on the clock because they came too late: the decoder fell behind.
    var lateDrops = 0
    /// Late frames shown anyway because none had been for 250 ms.
    var forcedShows = 0
    var stages = RenderedVideoDecoder.StageTimes()
    var enqueue = Duration.zero
    /// Waiting with the lead or the queue full, or at the end: nothing to do.
    var waitAhead = Duration.zero
    /// Waiting on the renderer, which wasn't ready for more.
    var waitRenderer = Duration.zero
    /// The most one frame took, from asking the decoder to having it enqueued.
    var worstFrame = Duration.zero

    /// A catch-up in this window went on past `slowCatchUp`.
    var slowCatchUp = false

    var dropped: Int { catchUpDrops + lateDrops }
    var isDegraded: Bool { late > 0 || lateDrops > 0 || forcedShows > 0 || slowCatchUp }

    /// A frame this far past its start when enqueued shows visibly late: more than half a 60 Hz refresh.
    static let lateTicks: Int64 = 100_000

    mutating func record(lead: Int64) {
        leads.append(lead)
        if lead < -Self.lateTicks { late += 1 }
    }

    mutating func add(_ times: RenderedVideoDecoder.StageTimes) {
        stages.read += times.read
        stages.decode += times.decode
        stages.convert += times.convert
        stages.packets += times.packets
        stages.decoded += times.decoded
        stages.converted += times.converted
    }

    /// One line, e.g.
    /// `Video mpeg4 at 24.000 fps: 720 enqueued, 0 dropped late, 0 forced, 12 dropped catching up in 30.0 s;
    /// per frame read 0.4 ms, decode 9.1 ms, convert 2.3 ms, enqueue 0.1 ms = 11.9 ms of 41.7 ms (worst 25.3 ms),
    /// can decode 84 fps; thread busy 29%, waiting 71% ahead, 0% on the renderer; lead min 120 ms, median 480 ms;
    /// 0 enqueued over 10 ms after their start; thermal nominal`
    func report(codec: String, frameRate: Double, logger: Logger) {
        guard shown > 0 || dropped > 0 else { return }
        let elapsed = ContinuousClock.now - since
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        func perFrame(_ duration: Duration, _ count: Int) -> String { count > 0 ? String(format: "%.1f ms", ms(duration) / Double(count)) : "–" }
        func share(_ duration: Duration) -> String { String(format: "%.0f%%", 100 * ms(duration) / max(1, ms(elapsed))) }
        let decoded = max(1, stages.decoded)
        let converted = max(1, stages.converted)
        let work = stages.read + stages.decode + stages.convert + enqueue
        // What one shown frame costs: reading and decoding are paid for every decoded frame, the
        // conversion and enqueue for the converted and shown ones.
        let costMs = ms(stages.read + stages.decode) / Double(decoded) + ms(stages.convert) / Double(converted) + (shown > 0 ? ms(enqueue) / Double(shown) : 0)
        let budgetMs = 1000 / frameRate
        let capacity = costMs > 0 ? String(format: "%.0f fps", 1000 / costMs) : "–"
        let sorted = leads.sorted()
        func leadMs(_ ticks: Int64) -> String { String(format: "%.0f ms", Double(ticks) / 10_000) }
        let lead = sorted.isEmpty ? "–" : "min \(leadMs(sorted[0])), median \(leadMs(sorted[sorted.count / 2]))"
        let text = "Video \(codec) at \(String(format: "%.3f", frameRate)) fps: \(shown) enqueued, \(lateDrops) dropped late, \(forcedShows) forced, \(catchUpDrops) dropped catching up in \(String(format: "%.1f", ms(elapsed) / 1000)) s; "
            + "per frame read \(perFrame(stages.read, decoded)), decode \(perFrame(stages.decode, decoded)), convert \(perFrame(stages.convert, converted)), enqueue \(perFrame(enqueue, shown)) = \(String(format: "%.1f", costMs)) ms of \(String(format: "%.1f", budgetMs)) ms (worst \(String(format: "%.1f", ms(worstFrame))) ms), can decode \(capacity); "
            + "thread busy \(share(work)), waiting \(share(waitAhead)) ahead, \(share(waitRenderer)) on the renderer; "
            + "lead \(lead); \(late) enqueued over 10 ms after their start; thermal \(ProcessInfo.processInfo.thermalState.logName)"
        if isDegraded {
            logger.warning("\(text)")
        } else {
            logger.info("\(text)")
        }
    }
}
