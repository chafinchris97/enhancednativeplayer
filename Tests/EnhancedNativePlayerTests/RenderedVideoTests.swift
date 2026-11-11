@preconcurrency import AVFoundation
import AetherLibavcodec
import AetherLibavutil
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Logging
import Testing
@testable import EnhancedNativePlayer

struct VideoRouteTests {
    private func route(_ codec: AVCodecID, _ format: AVPixelFormat = AV_PIX_FMT_NONE, profile: Int32 = AV_PROFILE_UNKNOWN, decoder: Bool = true) -> VideoRoute {
        VideoRoute.route(codecID: codec, pixelFormat: format, profile: profile, decoderAvailable: decoder)
    }

    @Test func avPlayerKeepsH264AndHEVC() {
        #expect(route(AV_CODEC_ID_H264, AV_PIX_FMT_YUV420P) == .copy(.h264))
        #expect(route(AV_CODEC_ID_H264, profile: AV_PROFILE_H264_HIGH) == .copy(.h264))
        #expect(route(AV_CODEC_ID_H264, AV_PIX_FMT_YUV422P) == .copy(.h264))
        #expect(route(AV_CODEC_ID_HEVC, AV_PIX_FMT_YUV420P10LE) == .copy(.hevc))
        #expect(route(AV_CODEC_ID_HEVC, AV_PIX_FMT_YUV444P10LE) == .copy(.hevc))
        #expect(route(AV_CODEC_ID_HEVC, profile: AV_PROFILE_HEVC_MAIN_10) == .copy(.hevc))
    }

    @Test func h264High10IsRendered() {
        #expect(route(AV_CODEC_ID_H264, AV_PIX_FMT_YUV420P10LE) == .render)
        #expect(route(AV_CODEC_ID_H264, profile: AV_PROFILE_H264_HIGH_10) == .render)
        #expect(route(AV_CODEC_ID_H264, profile: AV_PROFILE_H264_HIGH_10 | AV_PROFILE_H264_INTRA) == .render)
        #expect(route(AV_CODEC_ID_H264, AV_PIX_FMT_YUV420P10LE, decoder: false) == .copy(.h264))
    }

    @Test func otherCodecsAreRendered() {
        for codec in [AV_CODEC_ID_AV1, AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V3, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VP9] {
            #expect(route(codec) == .render)
            #expect(route(codec, AV_PIX_FMT_YUV420P) == .render)
            #expect(route(codec, decoder: false) == .unsupported)
        }
        #expect(route(AV_CODEC_ID_AV1, AV_PIX_FMT_YUV420P10LE) == .render)
        #expect(route(AV_CODEC_ID_AV1, AV_PIX_FMT_YUV420P12LE) == .unsupported)
    }

    @Test func theBuildHasTheDecoders() {
        for codec in [AV_CODEC_ID_AV1, AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V3, AV_CODEC_ID_MPEG2VIDEO] {
            #expect(VideoRoute.decoder(for: codec) != nil, "\(codecName(codec))")
        }
        #expect(String(cString: VideoRoute.decoder(for: AV_CODEC_ID_AV1)!.pointee.name) == "libdav1d")
    }
}

/// Opt-in: files whose video the player decodes, served over HTTP with range support.
///
///     ENP_RENDER_URLS=http://127.0.0.1:18931/av1.mkv,http://127.0.0.1:18931/vc1.mkv swift test --filter RenderedVideo
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENP_RENDER_URLS"] != nil))
struct RenderedVideoEndToEndTests {
    static let urls = (ProcessInfo.processInfo.environment["ENP_RENDER_URLS"] ?? "").split(separator: ",").compactMap { URL(string: String($0)) }

    @Test(arguments: urls) func placeholderPlaysInAVPlayer(url: URL) async throws {
        let session = try await EnhancedPlaybackSession.start(url: url)
        defer { Task { await session.stop() } }
        #expect(session.rendersVideo)
        let base = session.masterPlaylistURL.deletingLastPathComponent()
        let master = try String(contentsOf: base.appendingPathComponent("master.m3u8"), encoding: .utf8)
        print(master)
        #expect(master.contains(session.isHDR ? "CODECS=\"hvc1.2.4.L30.90" : "CODECS=\"avc1.42C00A"))

        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(15)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        guard item.status == .readyToPlay else { return }
        #expect(item.presentationSize == CGSize(width: PlaceholderVideo.width, height: PlaceholderVideo.height))
        player.play()
        try await Task.sleep(for: .seconds(2))
        print("\(url.lastPathComponent): AVPlayer at \(item.currentTime().seconds) s after 2 s")
        #expect(item.currentTime().seconds > 1)
        await player.seek(to: CMTime(seconds: 15, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .seconds(1))
        #expect(item.currentTime().seconds > 15.5)
        player.pause()
    }

    @Test(arguments: urls) func framesDecodeOnThePlaylistClock(url: URL) async throws {
        let session = try await EnhancedPlaybackSession.start(url: url)
        defer { Task { await session.stop() } }
        let frameBytes = session.videoFrameBytes
        let size = session.videoSize
        let token = CancellationToken()
        try await runBlocking(label: "test.decode") {
            let decoder = try session.makeVideoDecoder(token: token)
            try decoder.seek(toTicks: 0)
            var frames: [RenderedVideoDecoder.DecodedFrame] = []
            let started = ContinuousClock.now
            while frames.count < 96, let frame = try decoder.next() { frames.append(frame) }
            let took = ContinuousClock.now - started
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
            print("\(url.lastPathComponent): \(frames.count) frames in \(took), \(Int(Double(frames.count) / seconds)) fps; first at \(frames.first.map { $0.start / 10_000 } ?? -1) ms")
            #expect(frames.count == 96)
            #expect(frames.first.map { $0.start < 2_000_000 } == true)
            for (a, b) in zip(frames, frames.dropFirst()) {
                #expect(a.end == b.start)
                #expect(a.start < a.end)
            }
            let buffer = CMSampleBufferGetImageBuffer(frames[0].sample)!
            #expect(CVPixelBufferGetWidth(buffer) == Int(size.width))
            #expect(CVPixelBufferGetHeight(buffer) == Int(size.height))
            #expect(CVPixelBufferGetDataSize(buffer) >= frameBytes * 9 / 10)
            let format = CVPixelBufferGetPixelFormatType(buffer)
            print("pixel format \(String(format: "%08X", format)), transfer \(CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as Any)")

            // A seek lands on the frame on screen at the target.
            let target: Int64 = 15 * 10_000_000 + 1234
            try decoder.seek(toTicks: target)
            let first = try #require(try decoder.next())
            print("seek to \(target / 10_000) ms → frame \(first.start / 10_000)–\(first.end / 10_000) ms")
            #expect(first.start <= target && target < first.end)
        }
    }

    /// The feeder on a real AVPlayer item's clock: after a paused seek, the image on screen is the
    /// frame the decoder gives for that moment, and it keeps showing frames while playing.
    @MainActor @Test(arguments: urls) func feederFollowsThePlayerClock(url: URL) async throws {
        guard #available(macOS 14.4, *) else { return }
        let session = try await EnhancedPlaybackSession.start(url: url)
        defer { Task { await session.stop() } }
        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(15)
        while item.status == .unknown || item.timebase == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let timebase = try #require(item.timebase)
        let layer = AVSampleBufferDisplayLayer()
        layer.controlTimebase = timebase
        // The layer only displays (and reports what it displays) on screen.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        layer.frame = window.contentView!.bounds
        window.contentView?.layer?.addSublayer(layer)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let renderer = layer.sampleBufferRenderer
        let token = CancellationToken()
        let feeder = RenderedVideoFeeder(renderer: renderer, timebase: timebase, startTicks: 0, frameBytes: session.videoFrameBytes, token: token) {
            try session.makeVideoDecoder(token: token)
        }
        defer { feeder.stop() }
        let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { _ in
            let time = item.currentTime()
            if time.isNumeric { feeder.timeJumped(to: CMTimeConvertScale(time, timescale: 10_000_000, method: .roundTowardNegativeInfinity).value) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        player.play()
        try await Task.sleep(for: .seconds(2))
        #expect(renderer.status != .failed, "\(String(describing: renderer.error))")
        let playing = renderer.displayedPixelBuffer()
        #expect(playing != nil, "nothing shown while playing")

        for seconds in [20.0, 7.5] {
            player.pause()
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            let now = CMTimeConvertScale(item.currentTime(), timescale: 10_000_000, method: .roundTowardNegativeInfinity).value
            var shown: CVPixelBuffer?
            let wait = Date().addingTimeInterval(10)
            let expected = try await runBlocking(label: "test.expected") { () -> Data in
                let decoder = try session.makeVideoDecoder(token: CancellationToken())
                try decoder.seek(toTicks: now)
                let frame = try #require(try decoder.next())
                return Self.luma(CMSampleBufferGetImageBuffer(frame.sample)!)
            }
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                shown = renderer.displayedPixelBuffer()
            } while (shown.map { Self.luma($0) != expected } ?? true) && Date() < wait
            #expect(shown.map { Self.luma($0) == expected } == true, "\(url.lastPathComponent): the frame for \(seconds) s is not on screen")
            print("\(url.lastPathComponent): paused seek to \(seconds) s shows its frame")
        }
    }

    /// While playing, which frame is on screen against the item's clock: its start should be at
    /// or just before the clock, never after, and less than a frame behind.
    @MainActor @Test(arguments: urls) func playingFramesMatchTheClock(url: URL) async throws {
        guard #available(macOS 14.4, *) else { return }
        let session = try await EnhancedPlaybackSession.start(url: url)
        defer { Task { await session.stop() } }
        // Every frame of the first 12 s, by its luma.
        let reference = try await runBlocking(label: "test.reference") { () -> [(Data, Int64, Int64)] in
            let decoder = try session.makeVideoDecoder(token: CancellationToken())
            try decoder.seek(toTicks: 0)
            var frames: [(Data, Int64, Int64)] = []
            while let frame = try decoder.next(), frame.start < 120_000_000 {
                frames.append((Self.luma(CMSampleBufferGetImageBuffer(frame.sample)!), frame.start, frame.end))
            }
            return frames
        }
        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(15)
        while item.status == .unknown || item.timebase == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let timebase = try #require(item.timebase)
        let layer = AVSampleBufferDisplayLayer()
        layer.controlTimebase = timebase
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        layer.frame = window.contentView!.bounds
        window.contentView?.layer?.addSublayer(layer)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let token = CancellationToken()
        let feeder = RenderedVideoFeeder(renderer: layer.sampleBufferRenderer, timebase: timebase, startTicks: 0, frameBytes: session.videoFrameBytes, token: token) {
            try session.makeVideoDecoder(token: token)
        }
        defer { feeder.stop() }
        player.play()
        try await Task.sleep(for: .seconds(1))
        var offsets: [Int64] = []
        var unmatched = 0
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(97))
            guard let shown = layer.sampleBufferRenderer.displayedPixelBuffer() else { continue }
            let clock = CMTimeConvertScale(CMTimebaseGetTime(timebase), timescale: 10_000_000, method: .roundTowardNegativeInfinity).value
            let luma = Self.luma(shown)
            // Frames that look alike (a still shot) match several; take the one nearest the clock.
            let matches = reference.filter { $0.0 == luma }
            guard let best = matches.min(by: { abs($0.1 - clock) < abs($1.1 - clock) }) else { unmatched += 1; continue }
            offsets.append(clock - best.1)
        }
        player.pause()
        let sorted = offsets.sorted()
        let frame = reference.count > 1 ? reference[1].1 - reference[0].1 : 417_083
        print("\(url.lastPathComponent): clock − start of the frame on screen, ms: min \(Double(sorted.first ?? 0) / 10_000), median \(Double(sorted[sorted.count / 2]) / 10_000), max \(Double(sorted.last ?? 0) / 10_000); frame \(Double(frame) / 10_000) ms; \(unmatched) unmatched")
        #expect(!sorted.isEmpty)
        #expect(sorted[sorted.count / 2] >= 0 && sorted[sorted.count / 2] < frame)
    }

    private static func luma(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, 0) * (CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / max(1, CVPixelBufferGetWidthOfPlane(buffer, 0)))
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        var data = Data(capacity: rowBytes * height)
        for row in stride(from: 0, to: height, by: max(1, height / 64)) {
            data.append(base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self), count: rowBytes)
        }
        return data
    }

    /// Placeholder segments are cut on the plan and don't depend on where a run started.
    @Test(arguments: urls) func placeholderSegmentsAreRunIndependent(url: URL) async throws {
        let session = try await EnhancedPlaybackSession.start(url: url)
        defer { Task { await session.stop() } }
        let base = session.masterPlaylistURL.deletingLastPathComponent()
        let playlist = try String(contentsOf: base.appendingPathComponent("video.m3u8"), encoding: .utf8)
        let count = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF") }.count
        #expect(count > 2)
        var continuous: [Data] = []
        for i in 0..<count {
            continuous.append(try Data(contentsOf: base.appendingPathComponent("video_\(i).mp4")))
        }
        // Already sent, so this restarts the run at the last segment.
        let restarted = try Data(contentsOf: base.appendingPathComponent("video_\(count - 1).mp4"))
        #expect(restarted == continuous[count - 1])
        print("\(url.lastPathComponent): \(count) placeholder segments, \(continuous.map(\.count).reduce(0, +)) bytes")
    }
}

struct KeyframeSnapTests {
    private let s: Int64 = 10_000_000
    private var keyframes: [Int64] { [0, 10 * s, 20 * s, 30 * s, 100 * s] }

    @Test func landsOnTheNearestKeyframe() {
        // From 2 s: 19 s is 1 s from the keyframe at 20 s, well within half of the 17 s seek.
        #expect(KeyframeSnap.landing(target: 19 * s, current: 2 * s, keyframes: keyframes) == 20 * s)
        #expect(KeyframeSnap.landing(target: 22 * s, current: 2 * s, keyframes: keyframes) == 20 * s)
        // Backward: lands on the nearest keyframe before where it started.
        #expect(KeyframeSnap.landing(target: 11 * s, current: 28 * s, keyframes: keyframes) == 10 * s)
    }

    @Test func aShortSkipStaysASkip() {
        // +3 s from 13 s: the nearest keyframe, 20 s, is 4 s from the target, more than half of 3 s.
        #expect(KeyframeSnap.landing(target: 16 * s, current: 13 * s, keyframes: keyframes) == nil)
    }

    @Test func movesAtMostHalfTheSeek() {
        // 9 s → 12 s allows 1.5 s; the nearest keyframe, 10 s, is 2 s away.
        #expect(KeyframeSnap.landing(target: 12 * s, current: 9 * s, keyframes: keyframes) == nil)
        // 19 s → 40 s allows 10 s; 30 s is exactly that.
        #expect(KeyframeSnap.landing(target: 40 * s, current: 19 * s, keyframes: keyframes) == 30 * s)
        // 25 s → 15 s allows 5 s; 10 s and 20 s are both 5 s away, and the earlier one wins.
        #expect(KeyframeSnap.landing(target: 15 * s, current: 25 * s, keyframes: keyframes) == 10 * s)
    }

    @Test func staysExactWithoutAKeyframeAfterTheTarget() {
        #expect(KeyframeSnap.landing(target: 101 * s, current: 50 * s, keyframes: keyframes) == nil)
        #expect(KeyframeSnap.landing(target: 5 * s, current: 50 * s, keyframes: []) == nil)
    }

    @Test func reachesAtMostTenSeconds() {
        // 60 s from a keyframe on both sides.
        #expect(KeyframeSnap.landing(target: 60 * s, current: 0, keyframes: keyframes) == nil)
    }
}

struct VideoStartGateTests {
    @Test func aRunStartsAtTheFirstRequestAndAtEveryJump() {
        let gate = VideoStartGate()
        #expect(gate.startsRun(0))
        #expect(!gate.startsRun(1))
        #expect(!gate.startsRun(2))
        #expect(gate.startsRun(7))
        #expect(!gate.startsRun(8))
        #expect(gate.startsRun(3))
        #expect(gate.startsRun(3))
    }

    @Test func holdsUntilTheFrameIsQueued() async {
        let gate = VideoStartGate()
        let queued = Mutex<Range<Int64>?>(nil)
        let decodeAsked = Mutex<Int64?>(nil)
        gate.attach(VideoStartGate.Source(
            reportedTicks: { 25_000_000 },
            decode: { target in
                decodeAsked.withLock { $0 = target }
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    queued.withLock { $0 = 24_800_000..<25_200_000 }
                }
            },
            covers: { t in queued.withLock { $0?.contains(t) ?? false } },
            progress: { queued.withLock { $0 == nil ? 0 : 1 } }
        ))
        let started = ContinuousClock.now
        await gate.hold(segment: 3, range: 20_000_000..<30_000_000, startsRun: true, logger: Logger.player)
        let took = ContinuousClock.now - started
        #expect(decodeAsked.withLock { $0 } == 25_000_000)
        #expect(queued.withLock { $0 } != nil)
        #expect(took >= .milliseconds(190) && took < .seconds(2))
    }

    @Test func holdsNothingOutsideThePlayhead() async {
        let gate = VideoStartGate()
        let asked = Mutex(false)
        gate.attach(VideoStartGate.Source(reportedTicks: { 5_000_000 }, decode: { _ in asked.withLock { $0 = true } }, covers: { _ in false }, progress: { 0 }))
        let started = ContinuousClock.now
        // AVPlayer at 0.5 s filling its buffer with the segment from 60 s.
        await gate.hold(segment: 6, range: 600_000_000..<700_000_000, startsRun: false, logger: Logger.player)
        #expect(ContinuousClock.now - started < .milliseconds(100))
        await gate.hold(segment: 6, range: 600_000_000..<700_000_000, startsRun: true, logger: Logger.player)
        #expect(ContinuousClock.now - started < VideoStartGate.reportWait + .milliseconds(200))
        #expect(!asked.withLock { $0 })
    }

    @Test func waitsForADecoderThatHasNotStartedUntilTheTimeout() async {
        let gate = VideoStartGate()
        gate.attach(VideoStartGate.Source(reportedTicks: { 0 }, decode: { _ in }, covers: { _ in false }, progress: { 0 }))
        let started = ContinuousClock.now
        await gate.hold(segment: 0, range: 0..<60_000_000, startsRun: true, logger: Logger.player)
        let took = ContinuousClock.now - started
        #expect(took >= VideoStartGate.timeout - .milliseconds(100) && took < VideoStartGate.timeout + .seconds(1))
    }

    @Test func letsGoOfADecoderThatStopsMakingProgress() async {
        let gate = VideoStartGate()
        let progress = Mutex(0)
        gate.attach(VideoStartGate.Source(
            reportedTicks: { 0 },
            decode: { _ in Task { try? await Task.sleep(for: .milliseconds(100)); progress.withLock { $0 = 5 } } },
            covers: { _ in false },
            progress: { progress.withLock { $0 } }
        ))
        let started = ContinuousClock.now
        await gate.hold(segment: 0, range: 0..<60_000_000, startsRun: true, logger: Logger.player)
        let took = ContinuousClock.now - started
        #expect(took >= VideoStartGate.stall && took < VideoStartGate.stall + .seconds(1))
    }
}
