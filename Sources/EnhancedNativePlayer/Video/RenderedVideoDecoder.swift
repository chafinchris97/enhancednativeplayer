import EPLibavcodec
import EPLibavformat
import EPLibavutil
import CoreMedia
import Foundation
import Logging

/// Decodes a file's video for the player to draw, when AVPlayer can't decode it itself.
///
/// It reads the file through the session's `RemoteFile`, so the blocks the audio remux fetches
/// serve it too, and turns frames into sample buffers timed on the playlist timeline: a frame's
/// presentation time in the file minus the timeline's origin, the clock `AVPlayerItem` runs on.
/// Each frame lasts until the next one starts.
///
/// Not thread-safe: one thread uses it at a time.
final class RenderedVideoDecoder {
    struct DecodedFrame {
        var sample: CMSampleBuffer
        /// Playlist timeline, 100 ns ticks.
        var start: Int64
        var end: Int64
    }

    private let demuxer: Demuxer
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private let streamIndex: Int32
    private let timeBase: Rational
    private let originTicks: Int64
    /// Index timestamps are decode times in MP4; this moves a presentation time onto them.
    private let indexShift: Int64
    private let frameTicks: Int64
    private let converter: PixelBufferConverter
    private let packet = Packet()
    /// The latest decoded frame, held until the next one says when it ends.
    private var pending: (frame: UnsafeMutablePointer<AVFrame>, start: Int64)?
    /// After a seek: frames that end at or before this (playlist ticks) are skipped undrawn.
    private var seekTarget: Int64?
    private var lastStart = Int64.min
    private var draining = false

    /// The codec, for logs.
    let codecName: String
    /// The stream's frame rate, or the one its average frame duration gives; for logs.
    let frameRate: Double

    /// Where the decoding thread's time went since the last `takeStageTimes()`, for the log.
    struct StageTimes {
        /// Reading packets: the demuxer, and the block cache waiting on the network.
        var read = Duration.zero
        /// `avcodec_send_packet` and `avcodec_receive_frame`, which wait on the codec's threads.
        var decode = Duration.zero
        /// Turning frames into NV12 / P010 sample buffers.
        var convert = Duration.zero
        var packets = 0
        /// Frames out of the decoder, those skipped on the way to a seek's target or dropped late included.
        var decoded = 0
        var converted = 0
    }

    private var stageTimes = StageTimes()

    /// The times since the last call, and starts counting anew.
    func takeStageTimes() -> StageTimes {
        defer { stageTimes = StageTimes() }
        return stageTimes
    }
    private let logger: Logger
    /// A damaged stream fails every packet or frame alike.
    private let throttle = LogThrottle()

    /// Called for every frame the decoder puts out, those skipped on the way to a seek's target
    /// included, on the decoding thread.
    var onFrameDecoded: (() -> Void)?

    /// Leaves frames no other frame refers to undecoded (`AVDISCARD_NONREF`), for catching up
    /// with the clock. dav1d reads the setting only when it opens, so AV1 decodes them regardless.
    var skipsUnreferencedFrames = false {
        didSet {
            guard skipsUnreferencedFrames != oldValue, let codec else { return }
            codec.pointee.skip_frame = skipsUnreferencedFrames ? AVDISCARD_NONREF : AVDISCARD_DEFAULT
        }
    }

    init(file: RemoteFile, media: MediaInfo, originTicks: Int64, token: CancellationToken, logger: Logger) throws {
        self.logger = logger
        let video = media.video
        guard let source = video.rendered else { throw EnhancedPlayerError.unsupportedVideoCodec("none") }
        codecName = source.codecName
        demuxer = try Demuxer(file: file, token: token, findStreamInfo: false)
        demuxer.discardAll(except: [video.streamIndex])
        streamIndex = video.streamIndex
        timeBase = video.timeBase
        self.originTicks = originTicks
        indexShift = media.keyframes.usesDecodeTimestamps ? media.keyframes.presentationOffset : 0
        frameTicks = max(1, video.timeBase.rescale(video.frameDuration, to: .ticks))
        frameRate = video.frameRate ?? 10_000_000 / Double(frameTicks)
        converter = PixelBufferConverter(source: source)

        let stream = demuxer.stream(video.streamIndex)
        guard let decoder = VideoRoute.decoder(for: AVCodecID(source.codecID)) else {
            throw EnhancedPlayerError.unsupportedVideoCodec(source.codecName)
        }
        var ctx = avcodec_alloc_context3(decoder)
        guard let context = ctx else { throw EnhancedPlayerError.ffmpeg(operation: "avcodec_alloc_context3", code: -ENOMEM, message: "out of memory") }
        do {
            try FF.check(avcodec_parameters_to_context(context, stream.codecpar), "avcodec_parameters_to_context")
            context.pointee.pkt_timebase = stream.pointee.time_base
            // Every core: frame threads for throughput, slices where the codec has them.
            context.pointee.thread_count = 0
            context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
            try FF.check(avcodec_open2(context, decoder, nil), "avcodec_open2(\(String(cString: decoder.pointee.name)))")
        } catch {
            avcodec_free_context(&ctx)
            throw error
        }
        codec = context
        // libavcodec's own decoders report the threads they started; dav1d picks its own and leaves 0.
        let active = context.pointee.active_thread_type
        let kind = [active & FF_THREAD_FRAME != 0 ? "frame" : nil, active & FF_THREAD_SLICE != 0 ? "slice" : nil].compactMap { $0 }.joined(separator: "+")
        let threads = context.pointee.thread_count > 0 ? "\(context.pointee.thread_count) \(kind.isEmpty ? "" : kind + " ")threads" : "threads of its own choosing"
        logger.notice("Decoding \(source.codecName) video with \(String(cString: decoder.pointee.name)), \(threads), \(ProcessInfo.processInfo.activeProcessorCount) cores")
    }

    deinit {
        dropPending()
        avcodec_free_context(&codec)
    }

    /// Positions the decoder so the next frame is the one on screen at `ticks` (playlist timeline).
    func seek(toTicks ticks: Int64) throws {
        dropPending()
        avcodec_flush_buffers(codec)
        draining = false
        lastStart = .min
        seekTarget = ticks
        let target = Rational.ticks.rescale(max(0, ticks + originTicks), to: timeBase) - indexShift
        try demuxer.seek(stream: streamIndex, timestamp: target)
    }

    /// Thrown by `next` when `interrupted` says the caller has something else to do.
    struct Interrupted: Error {}

    /// The next frame, or nil at the end of the stream. A frame for which `skip` returns true
    /// (given its end) is decoded but not converted, the way a player drops a late frame.
    /// `interrupted` is asked after every frame decoded, those on the way to a seek's target
    /// too, and ends the call by throwing `Interrupted`: getting to a frame can take seconds.
    func next(skip: (Int64) -> Bool = { _ in false }, interrupted: () -> Bool = { false }) throws -> DecodedFrame? {
        while true {
            if interrupted() { throw Interrupted() }
            guard let (frame, start) = try decodeNext() else {
                guard let (last, lastFrameStart) = pending else { return nil }
                pending = nil
                defer { free(last) }
                return sample(last, start: lastFrameStart, end: lastFrameStart + frameTicks)
            }
            guard let (previous, previousStart) = pending else {
                pending = (frame, start)
                continue
            }
            pending = (frame, start)
            defer { free(previous) }
            var shownFrom = previousStart
            if let target = seekTarget {
                // The previous frame ends before the target: the new one is on screen at it, or later.
                if start <= target { continue }
                seekTarget = nil
                // A stream whose first frame starts a little late shows it from the target, not black.
                shownFrom = min(previousStart, target)
            }
            if skip(start) { continue }
            if let decoded = sample(previous, start: shownFrom, end: start) { return decoded }
        }
    }

    private func sample(_ frame: UnsafeMutablePointer<AVFrame>, start: Int64, end: Int64) -> DecodedFrame? {
        let started = ContinuousClock.now
        let converted = converter.sample(for: frame, start: start, end: end)
        stageTimes.convert += ContinuousClock.now - started
        stageTimes.converted += 1
        guard let sample = converted else {
            throttle.log(logger, .warning, key: "convert") { "Video frame in pixel format \(frame.pointee.format) not converted" }
            return nil
        }
        return DecodedFrame(sample: sample, start: start, end: end)
    }

    /// Receives the next frame, feeding packets as the decoder asks for them.
    private func decodeNext() throws -> (UnsafeMutablePointer<AVFrame>, Int64)? {
        guard let codec else { return nil }
        while true {
            guard let frame = av_frame_alloc() else { throw EnhancedPlayerError.ffmpeg(operation: "av_frame_alloc", code: -ENOMEM, message: "out of memory") }
            let receiving = ContinuousClock.now
            let received = avcodec_receive_frame(codec, frame)
            stageTimes.decode += ContinuousClock.now - receiving
            if received == 0 {
                stageTimes.decoded += 1
                onFrameDecoded?()
                let ts = frame.pointee.best_effort_timestamp
                var start = ts == FF.noPTS ? (lastStart == .min ? 0 : lastStart + frameTicks) : timeBase.rescale(ts, to: .ticks) - originTicks
                if lastStart != .min, start <= lastStart { start = lastStart + 1 }
                lastStart = start
                return (frame, start)
            }
            free(frame)
            if received == FF.errorEOF { return nil }
            guard received == FF.errorEAGAIN else {
                throw EnhancedPlayerError.ffmpeg(operation: "avcodec_receive_frame", code: received, message: FF.errorString(received))
            }
            if draining { return nil }
            let reading = ContinuousClock.now
            let read = try demuxer.read(into: packet)
            stageTimes.read += ContinuousClock.now - reading
            if read {
                guard packet.streamIndex == streamIndex else { continue }
                stageTimes.packets += 1
                let sending = ContinuousClock.now
                let sent = avcodec_send_packet(codec, packet.pointer)
                stageTimes.decode += ContinuousClock.now - sending
                // A damaged packet costs a frame, not the stream.
                if sent < 0, sent != FF.errorEAGAIN {
                    throttle.log(logger, .warning, key: "packet") { "Video packet not decoded: \(FF.errorString(sent))" }
                }
            } else {
                draining = true
                avcodec_send_packet(codec, nil)
            }
        }
    }

    private func dropPending() {
        if let (frame, _) = pending { free(frame) }
        pending = nil
    }

    private func free(_ frame: UnsafeMutablePointer<AVFrame>) {
        var pointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&pointer)
    }
}
