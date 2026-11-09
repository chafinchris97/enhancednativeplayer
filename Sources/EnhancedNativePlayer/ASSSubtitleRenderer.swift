import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// One subtitle sample: `images[index]` from `start` for `duration`, in playlist ticks.
struct ASSSampleRun: Equatable {
    var start: Int64
    var duration: Int64
    var index: Int
}

enum ASSSamples {
    /// `images[i]` shows from `frames[i]` until the next frame, the last one until `end`.
    /// Consecutive frames with the same image become one run.
    static func runs(frames: [Int64], images: [ASSRenderedFrame], end: Int64) -> [ASSSampleRun] {
        var runs: [ASSSampleRun] = []
        for (index, frame) in frames.enumerated() {
            let next = index + 1 < frames.count ? frames[index + 1] : end
            guard next > frame else { continue }
            if let last = runs.last, images[last.index].image === images[index].image {
                runs[runs.count - 1].duration = next - last.start
            } else {
                runs.append(ASSSampleRun(start: frame, duration: next - frame, index: index))
            }
        }
        return runs
    }

    /// `frames` cut into at most `count` runs of consecutive frames, as even as they go.
    static func chunks(of frames: [Int64], count: Int) -> [[Int64]] {
        let count = max(1, min(count, frames.count))
        guard count > 1 else { return [frames] }
        var chunks: [[Int64]] = []
        var start = 0
        for index in 0..<count {
            let end = (frames.count * (index + 1)) / count
            chunks.append(Array(frames[start..<end]))
            start = end
        }
        return chunks
    }

    /// One sample a worker made: `frame` from `start` for `duration`, in playlist ticks.
    struct Piece: @unchecked Sendable {
        var start: Int64
        var duration: Int64
        var frame: ASSRenderedFrame
        var sample: CMSampleBuffer?
        /// Set when `duration` grew after the sample was made, so its timing must be redone.
        var retimed = false
    }

    /// The workers' pieces back in one list. Each worker composes its own bitmaps, so an
    /// image that carries on from one chunk into the next is two pieces with the same
    /// pixels; those become one longer piece, so a still subtitle stays one sample.
    static func merged(_ chunks: [[Piece]]) -> [Piece] {
        var pieces: [Piece] = []
        for chunk in chunks {
            for (index, piece) in chunk.enumerated() {
                if index == 0, let last = pieces.last, last.start + last.duration == piece.start, sameContent(last.frame, piece.frame) {
                    pieces[pieces.count - 1].duration += piece.duration
                    pieces[pieces.count - 1].retimed = true
                } else {
                    pieces.append(piece)
                }
            }
        }
        return pieces
    }

    private static func sameContent(_ a: ASSRenderedFrame, _ b: ASSRenderedFrame) -> Bool {
        guard let left = a.image, let right = b.image else { return a.image == nil && b.image == nil }
        guard a.rect == b.rect, left.bytesPerRow == right.bytesPerRow, left.bitmapInfo == right.bitmapInfo,
              let leftData = left.dataProvider?.data, let rightData = right.dataProvider?.data else { return false }
        return (leftData as Data) == (rightData as Data)
    }

    /// Sample buffers handed from the render queue to the main thread. They are not touched
    /// again once made, so passing them across is safe.
    struct Batch: @unchecked Sendable {
        var samples: [CMSampleBuffer]
    }
}

/// Draws rendered frames into IOSurface-backed BGRA buffers the size of the overlay, in
/// pixels, and wraps them as sample buffers timed on the playlist timeline. Not thread-safe.
final class ASSSampleBufferFactory {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private var size = (width: 0, height: 0)
    /// The transparent buffer every run without text shares.
    private var empty: CVPixelBuffer?

    func sample(for frame: ASSRenderedFrame, width: Int, height: Int, start: Int64, duration: Int64) -> CMSampleBuffer? {
        guard width > 0, height > 0 else { return nil }
        if size != (width, height) {
            size = (width, height)
            pool = nil
            empty = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        let buffer: CVPixelBuffer?
        if let image = frame.image {
            buffer = draw(image, in: frame.rect)
        } else {
            if empty == nil { empty = draw(nil, in: .zero) }
            buffer = empty
        }
        guard let buffer else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: 10_000_000),
            presentationTimeStamp: CMTime(value: start, timescale: 10_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// A buffer from the pool, cleared, with `image` drawn at `rect` (top-left origin, pixels).
    private func draw(_ image: CGImage?, in rect: CGRect) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: Self.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let image {
            // Bitmap contexts put y = 0 at the bottom row.
            context.draw(image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, Self.colorSpace, .shouldPropagate)
        return buffer
    }
}

/// Renders with several `LibassRenderer`s at once, each on its own serial queue. libass is
/// not thread-safe, so every worker has its own library, renderer and track with the same
/// fonts, events and layout; they share nothing. A stretch of frames is split into one run
/// of consecutive frames per worker, so heavy typesetting renders on several cores, and
/// none of it holds up the main thread.
final class ASSRenderEngine: @unchecked Sendable {
    /// One libass instance keeps up: with its assembly, the heaviest typesetting tested so far
    /// (full-screen motion-tracked signs at 4K) renders in a few milliseconds a frame. If heavier
    /// scripts fall behind (the renderer logs it), more workers split each stretch across cores:
    /// `min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))` leaves two for
    /// decoding and the app.
    static var defaultWorkerCount: Int { 1 }

    private final class Worker: @unchecked Sendable {
        let queue: DispatchQueue
        /// Only touched on `queue`.
        let renderer: LibassRenderer
        /// Only touched on `queue`: the frames of the last chunk, reused by the next one while
        /// the generation holds.
        var cache: (generation: Int, frames: [Int64: ASSRenderedFrame]) = (0, [:])
        /// Only touched on `queue`.
        let factory = ASSSampleBufferFactory()

        init(index: Int, renderer: LibassRenderer) {
            queue = DispatchQueue(label: "ENP.ass.\(index)", qos: .userInitiated)
            self.renderer = renderer
        }

        func render(_ frames: [Int64], generation: Int) -> [ASSRenderedFrame] {
            let cached = cache.generation == generation ? cache.frames : [:]
            var images: [ASSRenderedFrame] = []
            var kept: [Int64: ASSRenderedFrame] = [:]
            for frame in frames {
                let time = ASSTime.milliseconds(ticks: frame)
                let image = cached[time] ?? renderer.render(atMilliseconds: time)
                images.append(image)
                kept[time] = image
            }
            cache = (generation, kept)
            return images
        }

        /// Renders `frames` and makes their samples, the last frame's until `end`.
        func pieces(_ frames: [Int64], end: Int64, width: Int, height: Int, generation: Int) -> [ASSSamples.Piece] {
            let images = render(frames, generation: generation)
            return ASSSamples.runs(frames: frames, images: images, end: end).map { run in
                ASSSamples.Piece(
                    start: run.start, duration: run.duration, frame: images[run.index],
                    sample: factory.sample(for: images[run.index], width: width, height: height, start: run.start, duration: run.duration)
                )
            }
        }
    }

    private let workers: [Worker]
    /// Joins the workers' chunks.
    private let assembly = DispatchQueue(label: "ENP.ass.samples", qos: .userInitiated)
    private let lock = NSLock()
    /// Counts changes to the events or the layout, under `lock`. A frame rendered under an
    /// older generation may be out of date.
    private var generationValue = 0

    init?(header: [UInt8], fonts: [ASSFont], videoMatrix: ColorMangling.Matrix?, workerCount: Int = ASSRenderEngine.defaultWorkerCount) {
        let count = max(1, workerCount)
        // Font setup takes a moment per renderer, so they are made side by side.
        let renderers = Mutex([LibassRenderer?](repeating: nil, count: count))
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let renderer = LibassRenderer(header: header, fonts: fonts, videoMatrix: videoMatrix)
            renderers.withLock { $0[index] = renderer }
        }
        let made = renderers.withLock { $0 }.compactMap { $0 }
        guard made.count == count else { return nil }
        workers = made.enumerated().map { Worker(index: $0.offset, renderer: $0.element) }
    }

    var generation: Int { lock.withLock { generationValue } }

    func set(layout: LibassRenderer.Layout) {
        bumpGeneration()
        for worker in workers {
            worker.queue.async { worker.renderer.set(layout: layout) }
        }
    }

    func add(_ events: [ASSEvent]) {
        guard !events.isEmpty else { return }
        bumpGeneration()
        for worker in workers {
            worker.queue.async { worker.renderer.add(events) }
        }
    }

    /// Renders `frames` (playlist ticks) and makes them into sample buffers for a canvas of
    /// `width` × `height` pixels, `images[i]` from `frames[i]` and the last one until `end`.
    /// Hands them, with the generation they were rendered under, to `completion` on the main queue.
    func renderSamples(_ frames: [Int64], end: Int64, width: Int, height: Int, completion: @escaping @Sendable @MainActor (Int, ASSSamples.Batch) -> Void) {
        let generation = generation
        let chunks = ASSSamples.chunks(of: frames, count: workers.count)
        let results = Mutex([[ASSSamples.Piece]](repeating: [], count: chunks.count))
        let group = DispatchGroup()
        for (index, chunk) in chunks.enumerated() {
            let worker = workers[index]
            // A chunk's last frame lasts until the next chunk starts.
            let chunkEnd = index + 1 < chunks.count ? chunks[index + 1][0] : end
            group.enter()
            worker.queue.async {
                let pieces = worker.pieces(chunk, end: chunkEnd, width: width, height: height, generation: generation)
                results.withLock { $0[index] = pieces }
                group.leave()
            }
        }
        group.notify(queue: assembly) {
            let samples = ASSSamples.merged(results.withLock { $0 }).compactMap { piece -> CMSampleBuffer? in
                guard let sample = piece.sample else { return nil }
                guard piece.retimed else { return sample }
                var timing = CMSampleTimingInfo(
                    duration: CMTime(value: piece.duration, timescale: 10_000_000),
                    presentationTimeStamp: CMTime(value: piece.start, timescale: 10_000_000),
                    decodeTimeStamp: .invalid
                )
                var retimed: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
                return retimed
            }
            let batch = ASSSamples.Batch(samples: samples)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(generation, batch) }
            }
        }
    }

    private func bumpGeneration() {
        lock.withLock { generationValue += 1 }
    }
}

#if canImport(UIKit) && !os(watchOS)
import Logging
import UIKit

/// Draws the selected ASS track with libass in `AVPlayerViewController.contentOverlayView`,
/// above the video and below the controls. The rendition's WebVTT segments are empty, so
/// its selection in the player's menu only says what to draw here.
///
/// The subtitles are presented the way the video is: as timed sample buffers in an
/// `AVSampleBufferDisplayLayer` whose control timebase is the player item's own. Each
/// rendered frame (at the video's frame times, read from the file) becomes a buffer the
/// size of the overlay with that frame's presentation time and duration, and the layer's
/// video queue picks the buffer for each refresh the same way, and against the same clock,
/// as the video's. No clock is read anywhere else, and seeks, pauses, rate changes and
/// stalls follow the timebase by themselves.
@MainActor
final class ASSSubtitleRenderer {
    /// How far back, in segments, a read looks for events still on screen as a segment starts.
    static let lookback = 3
    /// How far ahead of the playhead samples are enqueued, in ticks. Each animated frame is a
    /// buffer the size of the screen, so this stays short.
    private static let leadTicks: Int64 = 5_000_000
    /// More samples are rendered once less than this much is left of the enqueued ones.
    private static let refillTicks: Int64 = 3_000_000

    private let session: EnhancedPlaybackSession
    private let overlay = ASSOverlayView()
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var selectionObserver: NSObjectProtocol?
    private var jumpObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var track: Int?
    /// Changes with every selection, so work for an earlier one can tell it is stale.
    private var selection = 0
    private var engine: ASSRenderEngine?
    private var setupTask: Task<Void, Never>?
    private var loads: [Int: Task<Void, Never>] = [:]
    private var segments: [Int: ASSSegment] = [:]
    /// The enqueued samples run from `start` to `end` (playlist ticks), rendered under `generation`.
    private var enqueued: (start: Int64, end: Int64, generation: Int)?
    /// The stretch being rendered, in playlist ticks.
    private var inFlight: Range<Int64>?
    /// Samples rendered under an engine generation before this one are out of date. Events
    /// that show nowhere near the enqueued or rendering stretch don't move it, so reading the
    /// next segment doesn't throw away samples it changes nothing in.
    private var currentGeneration = 0
    /// Changes whenever the enqueued samples are thrown away, so a render begun before can tell.
    private var epoch = 0
    /// The playhead at the last plan, in playlist ticks.
    private var lastPlanned: Int64?
    private var rendering = false
    private var needsPlan = false

    init(session: EnhancedPlaybackSession, container: UIView) {
        self.session = session
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        container.addSubview(overlay)
        overlay.onLayout = { [weak self] in self?.updateLayout() }
    }

    /// Follows the subtitle selection of `item`, replacing whatever was attached before.
    func attach(player: AVPlayer, item: AVPlayerItem) {
        detach()
        self.player = player
        self.item = item
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelection(of: item) }
        }
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeJumped() }
        }
        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateLayout() }
        }
        updateSelection(of: item)
    }

    func stop() {
        detach()
        overlay.removeFromSuperview()
    }

    private func detach() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        selectionObserver = nil
        jumpObserver = nil
        presentationSizeObservation = nil
        select(track: nil)
        // The layer runs on this item's timebase, so it goes with the item.
        overlay.attach(timebase: nil)
        player = nil
        item = nil
    }

    private func updateSelection(of item: AVPlayerItem) {
        Task { [weak self] in
            // The group only exists once the master playlist has been read.
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), let self, self.item === item else { return }
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
            self.select(track: option?.renditionName.flatMap { self.session.assTrack(named: $0) })
        }
    }

    private func select(track: Int?) {
        guard track != self.track else { return }
        self.track = track
        selection += 1
        setupTask?.cancel()
        setupTask = nil
        loads.values.forEach { $0.cancel() }
        loads = [:]
        segments = [:]
        engine = nil
        discardSamples()
        rendering = false
        inFlight = nil
        currentGeneration = 0
        needsPlan = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        // The sample layer stays: discarding the samples has flushed it, image and all, the way a
        // seek does. A layer made anew while playing showed later samples slightly out of sync.
        // A new engine has no layout yet.
        overlay.layout = nil
        guard let track, let player, let item else { return }
        Logger.player.info("Drawing ASS track \(track) with libass")
        let header = session.assHeader(track: track)
        let matrix = session.videoColorMatrix
        let selection = selection
        setupTask = Task { [weak self, session] in
            let fonts: [ASSFont]
            do {
                fonts = try await session.assFonts()
            } catch {
                if !(error is CancellationError) { Logger.player.warning("Attached fonts not read: \(error)") }
                fonts = []
            }
            // Font setup can take a moment, so it stays off the main thread.
            let engine = await Task.detached(priority: .userInitiated) {
                ASSRenderEngine(header: header, fonts: fonts, videoMatrix: matrix)
            }.value
            guard let self, !Task.isCancelled, self.selection == selection, self.item === item else { return }
            guard let engine else {
                Logger.player.error("libass could not be initialised for track \(track)")
                return
            }
            // The item has a timebase once it has a player; the selection can't exist before that.
            guard let timebase = item.timebase else {
                Logger.player.error("The player item has no timebase to show ASS track \(track) on")
                return
            }
            Logger.player.info("libass ready for track \(track) with \(fonts.count) attached fonts")
            self.engine = engine
            if self.overlay.timebase !== timebase { self.overlay.attach(timebase: timebase) }
            for segment in self.segments.values { engine.add(segment.events) }
            self.updateLayout()
            // Only to keep samples enqueued ahead of the playhead; which one shows is the layer's.
            self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 8), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.plan() }
            }
            self.plan()
        }
    }

    private func updateLayout() {
        guard let engine else { return }
        let scale = overlay.window?.screen.scale ?? overlay.traitCollection.displayScale
        let bounds = overlay.bounds
        guard bounds.width > 0, bounds.height > 0, scale > 0 else { return }
        let size = session.videoSize
        let presentation = item?.presentationSize ?? .zero
        let aspect = presentation.width > 0 && presentation.height > 0 ? presentation : size
        let video = AVMakeRect(aspectRatio: aspect, insideRect: bounds)
        let layout = LibassRenderer.Layout(
            frameWidth: Int((bounds.width * scale).rounded()),
            frameHeight: Int((bounds.height * scale).rounded()),
            video: CGRect(x: video.minX * scale, y: video.minY * scale, width: video.width * scale, height: video.height * scale),
            storageWidth: Int(size.width),
            storageHeight: Int(size.height)
        )
        guard layout != overlay.layout else { return }
        overlay.layout = layout
        engine.set(layout: layout)
        currentGeneration = engine.generation
        plan()
    }

    /// Throws the enqueued samples away, and the image on screen with them.
    private func discardSamples() {
        epoch += 1
        enqueued = nil
        lastPlanned = nil
        overlay.flush()
    }

    /// A seek or a stall moved the playhead. The layer drops samples once it has shown them,
    /// so unless the playhead only moved forward inside the enqueued stretch, everything is
    /// enqueued again from the new place.
    private func timeJumped() {
        guard let item, let enqueued else { return plan() }
        let now = Self.ticks(item.currentTime())
        if now < (lastPlanned ?? enqueued.start) || now >= enqueued.end { discardSamples() }
        plan()
    }

    /// Enqueues samples from where the enqueued ones end, or from the frame on screen, to
    /// `leadTicks` ahead. New events or a new layout make the enqueued ones stale: they are
    /// replaced from the frame on screen.
    private func plan() {
        guard let engine, let track, let item, player?.currentItem === item, let layout = overlay.layout else { return }
        let time = item.currentTime()
        guard time.isNumeric else { return }
        let now = Self.ticks(time)
        lastPlanned = now
        loadAround(track: track, segment: session.subtitleSegment(atTicks: now))
        let target = now + Self.leadTicks
        var from = now
        var replacing = true
        if let enqueued, isCurrent(enqueued.generation), enqueued.start <= now, now < enqueued.end {
            if enqueued.end - now > Self.refillTicks { return }
            from = enqueued.end
            replacing = false
        } else if let enqueued, isCurrent(enqueued.generation), !rendering, now >= enqueued.end, now - enqueued.end < Self.leadTicks {
            // Played past everything enqueued: the last image has been held over frames it doesn't belong to.
            Logger.player.warning("ASS: subtitles ran out \((now - enqueued.end) / 10_000) ms ago; rendering can't keep up")
        }
        guard !rendering else {
            needsPlan = true
            return
        }
        // Without the segments' frame times there are no events either; their load plans again.
        // The last frame only closes the stretch; samples run up to it.
        guard let frames = frameTimes(from: from, to: target), frames.count >= 2 else { return }
        if !replacing, frames[0] != from {
            // The enqueued stretch ends on a frame start, so this only happens with frames from the rate.
            return discardAndPlan()
        }
        rendering = true
        inFlight = frames[0]..<frames[frames.count - 1]
        let selection = selection
        let epoch = epoch
        let end = frames[frames.count - 1]
        let started = ContinuousClock.now
        engine.renderSamples(Array(frames.dropLast()), end: end, width: layout.frameWidth, height: layout.frameHeight) { [weak self] rendered, batch in
            guard let self, self.selection == selection else { return }
            self.rendering = false
            self.inFlight = nil
            let took = ContinuousClock.now - started
            let span = Duration.nanoseconds((end - frames[0]) * 100)
            if took > span {
                Logger.player.warning("ASS: rendering \(span) of subtitles took \(took), slower than playback")
            }
            // A seek since the render began threw away what these samples follow on from.
            if self.isCurrent(rendered), self.epoch == epoch {
                // Stale samples go, but the image on screen stays until the new ones take over.
                if replacing { self.overlay.flush(keepingImage: true) }
                self.overlay.enqueue(batch.samples)
                let start = replacing ? frames[0] : (self.enqueued?.start ?? frames[0])
                self.enqueued = (start, end, rendered)
            }
            if self.needsPlan || !self.isCurrent(rendered) {
                self.needsPlan = false
                self.plan()
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation >= currentGeneration
    }

    /// Adds events to the engine. Only events that show somewhere in the enqueued or
    /// rendering stretch make those samples out of date.
    private func add(_ events: [ASSEvent]) {
        guard let engine, !events.isEmpty else { return }
        let stretches = [enqueued.map { $0.start..<$0.end }, inFlight].compactMap { $0 }
        engine.add(events)
        let touches = events.contains { event in
            let shown = event.startMilliseconds * 10_000..<(event.startMilliseconds + event.durationMilliseconds) * 10_000
            return stretches.contains { $0.overlaps(shown) }
        }
        if touches { currentGeneration = engine.generation }
    }

    private func discardAndPlan() {
        discardSamples()
        plan()
    }

    /// The frame on screen at `start` and every frame after it up to `end`, nil while a
    /// segment they fall in hasn't been read.
    private func frameTimes(from start: Int64, to end: Int64) -> [Int64]? {
        let first = session.subtitleSegment(atTicks: start)
        let last = session.subtitleSegment(atTicks: end)
        var times: [Int64] = []
        // The frame on screen can have started in the segment before.
        if first > 0, let previous = segments[first - 1] {
            times += frames(of: previous, segment: first - 1)
        }
        for segment in first...last {
            guard let loaded = segments[segment] else {
                if segment == first { return nil }
                break
            }
            times += frames(of: loaded, segment: segment)
        }
        let current = times.last { $0 <= start } ?? start
        return times.filter { $0 >= current && $0 <= end }
    }

    /// The segment's frame times as read, or from the frame rate where the read had none.
    private func frames(of segment: ASSSegment, segment index: Int) -> [Int64] {
        if !segment.frameTicks.isEmpty { return segment.frameTicks }
        let range = session.subtitleSegmentRange(index)
        let length = session.videoFrameTicks ?? 10_000_000 / 24
        let first = (Double(range.lowerBound) / length).rounded(.up)
        let last = (Double(range.upperBound) / length).rounded(.up)
        return stride(from: first, to: last, by: 1).map { Int64(($0 * length).rounded()) }
    }

    /// Reads the segment under the playhead first, then the next one, then the ones before it.
    private func loadAround(track: Int, segment: Int) {
        let last = session.subtitleSegment(atTicks: .max)
        var wanted = [segment]
        if segment < last { wanted.append(segment + 1) }
        wanted += stride(from: segment - 1, through: max(0, segment - Self.lookback), by: -1)
        let selection = selection
        for index in wanted where segments[index] == nil && loads[index] == nil {
            loads[index] = Task { [weak self, session] in
                let loaded: ASSSegment
                do {
                    loaded = try await session.assSegment(track: track, segment: index)
                } catch {
                    guard let self, self.selection == selection else { return }
                    self.loads[index] = nil
                    if !(error is CancellationError) {
                        // Kept as empty so it isn't read again on every tick; a new selection retries.
                        self.segments[index] = ASSSegment(events: [], frameTicks: [])
                        Logger.player.warning("ASS segment \(index) of track \(track) not read: \(error)")
                    }
                    return
                }
                guard let self, self.selection == selection else { return }
                self.loads[index] = nil
                self.segments[index] = loaded
                self.add(loaded.events)
                self.plan()
            }
        }
    }

    private static func ticks(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 10_000_000, method: .roundHalfAwayFromZero).value
    }
}

/// Hosts the `AVSampleBufferDisplayLayer` the subtitle samples are presented in.
private final class ASSOverlayView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?
    var layout: LibassRenderer.Layout?
    var onLayout: (() -> Void)?
    /// The timebase the layer runs on, nil without a layer.
    var timebase: CMTimebase? { displayLayer?.controlTimebase }

    /// A new layer on `timebase`, or none.
    func attach(timebase: CMTimebase?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.flushAndRemoveImage()
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        if let timebase {
            let displayLayer = AVSampleBufferDisplayLayer()
            displayLayer.frame = bounds
            // The samples are exactly the overlay's size in pixels.
            displayLayer.videoGravity = .resize
            displayLayer.isOpaque = false
            displayLayer.backgroundColor = nil
            displayLayer.controlTimebase = timebase
            layer.addSublayer(displayLayer)
            self.displayLayer = displayLayer
        }
        CATransaction.commit()
        layout = nil
    }

    func flush(keepingImage: Bool = false) {
        guard let displayLayer else { return }
        if keepingImage {
            displayLayer.flush()
        } else {
            displayLayer.flushAndRemoveImage()
        }
        // A layer that failed takes no more samples until flushed.
        if displayLayer.status == .failed {
            Logger.player.warning("ASS sample layer failed: \(String(describing: displayLayer.error))")
        }
    }

    func enqueue(_ samples: [CMSampleBuffer]) {
        guard let displayLayer else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        for sample in samples { displayLayer.enqueue(sample) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
        onLayout?()
    }
}
#endif
