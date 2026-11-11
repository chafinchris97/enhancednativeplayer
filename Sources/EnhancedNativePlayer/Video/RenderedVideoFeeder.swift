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
    /// A clock this close to a target the server named has reached it.
    static let arrivedTicks: Int64 = 10_000_000

    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let token: CancellationToken
    private let maxQueued: Int
    private let makeDecoder: @Sendable () throws -> RenderedVideoDecoder

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
    init(renderer: AVSampleBufferVideoRenderer, timebase: CMTimebase, startTicks: Int64, frameBytes: Int, token: CancellationToken, makeDecoder: @escaping @Sendable () throws -> RenderedVideoDecoder) {
        self.renderer = renderer
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
            if !token.isCancelled { Logger.player.error("Video decoder not opened: \(error)") }
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
                Logger.player.warning("Video renderer failed: \(String(describing: renderer.error)); restarting at the clock")
                seekTarget = clock
            } else if renderer.requiresFlushToResumeDecoding {
                seekTarget = clock
            }
            if let target = seekTarget {
                Logger.player.info("Video: decoding from the keyframe before \(String(format: "%.3f", Double(target) / 1e7)) s (clock at \(String(format: "%.3f", Double(timebaseTicks) / 1e7)) s)")
                renderer.flush(removingDisplayedImage: false, completionHandler: nil)
                queued = []
                publish(queued)
                atEnd = false
                catchingUp = true
                caughtUpFrom = .now
                seekingTo = target
                do {
                    try decoder.seek(toTicks: target)
                } catch {
                    if token.isCancelled { break }
                    Logger.player.error("Video seek to \(target / 10_000) ms failed: \(error)")
                    atEnd = true
                }
                continue
            }
            publish(queued)

            let ahead = (queued.last?.end ?? clock) - clock
            if atEnd || queued.count >= maxQueued || ahead >= Self.leadTicks || !renderer.isReadyForMoreMediaData {
                condition.lock()
                if !stopped, jump == nil { condition.wait(until: Date(timeIntervalSinceNow: 0.01)) }
                condition.unlock()
                continue
            }

            do {
                let started = ContinuousClock.now
                // Catching up while the clock runs: frames nothing refers to can go undecoded. Paused,
                // the frame at the target must be the exact one.
                decoder.skipsUnreferencedFrames = catchingUp && CMTimebaseGetRate(timebase) > 0
                let decoded = try decoder.next(skip: { end in
                    guard end <= self.now else { return false }
                    if !catchingUp, ContinuousClock.now - lastShown >= .milliseconds(250) { return false }
                    stats.dropped += 1
                    return true
                }, interrupted: { [unowned self] in
                    condition.lock()
                    defer { condition.unlock() }
                    return stopped || jump != nil
                })
                stats.decodeTime += ContinuousClock.now - started
                guard let decoded else {
                    atEnd = true
                    continue
                }
                renderer.enqueue(decoded.sample)
                queued.append((decoded.start, decoded.end))
                publish(queued)
                seekingTo = nil
                lastShown = ContinuousClock.now
                let lead = decoded.start - now
                stats.record(lead: lead)
                if catchingUp, decoded.end > now {
                    catchingUp = false
                    decoder.skipsUnreferencedFrames = false
                    if let from = caughtUpFrom {
                        Logger.player.info("Video: on the clock \(ContinuousClock.now - from) after the seek")
                    }
                    caughtUpFrom = nil
                }
            } catch is RenderedVideoDecoder.Interrupted {
                // A jump or a stop: the loop takes it from here.
                continue
            } catch {
                if token.isCancelled { break }
                Logger.player.error("Video decoding stopped: \(error)")
                atEnd = true
            }
            if ContinuousClock.now - stats.since > .seconds(5) {
                stats.report(codec: decoder.codecName)
                stats = Stats()
            }
        }
    }
}

/// What the video thread did over a few seconds, for the log: how far ahead of the clock frames
/// reached the renderer, how many came after their start (and so showed late), and how many were
/// dropped.
private struct Stats {
    let since = ContinuousClock.now
    var leads: [Int64] = []
    var late = 0
    var dropped = 0
    var decodeTime = Duration.zero

    mutating func record(lead: Int64) {
        leads.append(lead)
        if lead < 0 { late += 1 }
    }

    func report(codec: String) {
        guard !leads.isEmpty || dropped > 0 else { return }
        let elapsed = ContinuousClock.now - since
        let sorted = leads.sorted()
        func ms(_ ticks: Int64) -> String { String(format: "%.0f", Double(ticks) / 10_000) }
        let frames = leads.count + dropped
        let seconds = Double(decodeTime.components.seconds) + Double(decodeTime.components.attoseconds) / 1e18
        let rate = seconds > 0 ? String(format: "%.0f", Double(frames) / seconds) : "–"
        let lead = sorted.isEmpty ? "–" : "min \(ms(sorted[0])) ms, median \(ms(sorted[sorted.count / 2])) ms"
        let text = "Video \(codec): \(leads.count) frames shown, \(dropped) dropped in \(elapsed); decoding \(rate) fps; lead at enqueue \(lead); \(late) enqueued after their start"
        if late > 0 || dropped > 0 {
            Logger.player.warning("\(text)")
        } else {
            Logger.player.info("\(text)")
        }
    }
}
