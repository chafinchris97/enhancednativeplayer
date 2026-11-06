import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

/// Turns rendered frames into one discrete key-frame animation for a layer inside an
/// `AVSynchronizedLayer`, where animation time is the player item's time.
enum ASSKeyframes {
    /// Each image switches this much before its frame starts, so floating point in the key
    /// times can never make it late. Far shorter than any frame.
    static let switchEarlySeconds = 0.000_1

    /// 1×1 transparent, for frames with nothing on screen: `contents` can't animate to nil.
    static let empty: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }()

    /// Shows `images[i]` from `frames[i]` (playlist ticks) until the next frame, and the last
    /// one until `end`. Runs of the same image become one key. Rects are divided by `scale`
    /// into the layer's points; the layer's anchor point must be at its origin.
    static func animation(frames: [Int64], images: [ASSRenderedFrame], end: Int64, scale: CGFloat) -> CAAnimationGroup? {
        guard let first = frames.first, scale > 0 else { return nil }
        let start = Double(first) / 10_000_000
        let duration = Double(end - first) / 10_000_000
        guard duration > 0 else { return nil }
        var keyTimes: [NSNumber] = []
        var contents: [Any] = []
        var positions: [NSValue] = []
        var sizes: [NSValue] = []
        var previous: CGImage??
        for (time, frame) in zip(frames, images) {
            if let previous, previous === frame.image { continue }
            previous = .some(frame.image)
            let offset = keyTimes.isEmpty ? 0 : max(0, Double(time) / 10_000_000 - start - switchEarlySeconds)
            keyTimes.append(NSNumber(value: offset / duration))
            contents.append(frame.image ?? empty)
            let rect = frame.image == nil ? CGRect.zero : CGRect(x: frame.rect.minX / scale, y: frame.rect.minY / scale, width: frame.rect.width / scale, height: frame.rect.height / scale)
            positions.append(.of(rect.origin))
            sizes.append(.of(CGRect(origin: .zero, size: rect.size)))
        }
        // Discrete key frames take one more key time than values; the last value holds to the end.
        keyTimes.append(1)
        func animation(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.calculationMode = .discrete
            animation.values = values
            animation.keyTimes = keyTimes
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = [animation("contents", contents), animation("position", positions), animation("bounds", sizes)]
        // In a synchronized layer the begin time is item time, and 0 would mean "now".
        group.beginTime = start == 0 ? AVCoreAnimationBeginTimeAtZero : start
        group.duration = duration
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        return group
    }
}

private extension NSValue {
    static func of(_ point: CGPoint) -> NSValue {
        #if canImport(UIKit)
        NSValue(cgPoint: point)
        #else
        NSValue(point: point)
        #endif
    }

    static func of(_ rect: CGRect) -> NSValue {
        #if canImport(UIKit)
        NSValue(cgRect: rect)
        #else
        NSValue(rect: rect)
        #endif
    }
}

/// Runs a `LibassRenderer` on its own serial queue. libass is not thread-safe, and rendering
/// a stretch of frames ahead of the playhead must not hold up the main thread.
final class ASSRenderEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ENP.ass", qos: .userInitiated)
    /// Only touched on `queue`.
    private let renderer: LibassRenderer
    /// Only touched on `queue`: the frames of the last batch, reused by the next one while
    /// the generation holds.
    private var cache: (generation: Int, frames: [Int64: ASSRenderedFrame]) = (0, [:])
    private let lock = NSLock()
    /// Counts changes to the events or the layout, under `lock`. A frame rendered under an
    /// older generation may be out of date.
    private var generationValue = 0

    init?(header: [UInt8], fonts: [ASSFont], videoMatrix: ColorMangling.Matrix?) {
        guard let renderer = LibassRenderer(header: header, fonts: fonts, videoMatrix: videoMatrix) else { return nil }
        self.renderer = renderer
    }

    var generation: Int { lock.withLock { generationValue } }

    func set(layout: LibassRenderer.Layout) {
        bumpGeneration()
        queue.async { [renderer] in renderer.set(layout: layout) }
    }

    func add(_ events: [ASSEvent]) {
        guard !events.isEmpty else { return }
        bumpGeneration()
        queue.async { [renderer] in renderer.add(events) }
    }

    /// Renders each of `milliseconds` in order and hands the frames, with the generation they
    /// were rendered under, to `completion` on the main queue.
    func render(_ milliseconds: [Int64], completion: @escaping @Sendable @MainActor (Int, [ASSRenderedFrame]) -> Void) {
        let generation = generation
        queue.async { [self] in
            let cached = cache.generation == generation ? cache.frames : [:]
            var frames: [ASSRenderedFrame] = []
            var kept: [Int64: ASSRenderedFrame] = [:]
            for time in milliseconds {
                let frame = cached[time] ?? renderer.render(atMilliseconds: time)
                frames.append(frame)
                kept[time] = frame
            }
            cache = (generation, kept)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(generation, frames) }
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
/// Timing is left to Core Animation, not to the main thread. The subtitles live in an
/// `AVSynchronizedLayer`, whose clock is the player item's timebase, the same clock that
/// presents the video frames. The next second is rendered ahead, one image per video frame
/// (at the frame times read from the file), and installed as a discrete keyframe animation
/// keyed at those frame times. The render server switches images on the very vsync the
/// video frame changes, whatever the main thread is doing, and paused seeks, rate changes
/// and stalls follow the timebase by themselves.
@MainActor
final class ASSSubtitleRenderer {
    /// How far back, in segments, a read looks for events still on screen as a segment starts.
    static let lookback = 3
    /// How far ahead of the playhead frames are rendered, in ticks.
    private static let leadTicks: Int64 = 10_000_000
    /// A new stretch is rendered once less than this much is left of the planned one.
    private static let refillTicks: Int64 = 6_000_000

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
    /// The stretch the installed animation covers, in playlist ticks, and the generation it was rendered under.
    private var planned: (start: Int64, end: Int64, generation: Int)?
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
        overlay.attach(item)
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
        overlay.attach(nil)
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
        planned = nil
        rendering = false
        needsPlan = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        overlay.clear()
        // A new engine has no layout yet.
        overlay.layout = nil
        guard let track, let player else { return }
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
            guard let self, !Task.isCancelled, self.selection == selection else { return }
            guard let engine else {
                Logger.player.error("libass could not be initialised for track \(track)")
                return
            }
            Logger.player.info("libass ready for track \(track) with \(fonts.count) attached fonts")
            self.engine = engine
            for segment in self.segments.values { engine.add(segment.events) }
            self.updateLayout()
            // Only to keep the planned stretch ahead of the playhead; the timing itself is the layer's.
            self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
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
        overlay.scale = scale
        engine.set(layout: layout)
        plan()
    }

    /// A seek or a stall moved the playhead. If it left the planned stretch, the installed
    /// images are for other frames, so they go before anything wrong is shown.
    private func timeJumped() {
        guard let item, let planned else { return plan() }
        let now = Self.ticks(item.currentTime())
        if now < planned.start || now >= planned.end {
            overlay.clear()
            self.planned = nil
        }
        plan()
    }

    /// Renders and installs the stretch from the frame on screen to `leadTicks` ahead, unless
    /// the installed one still reaches far enough.
    private func plan() {
        guard let engine, let track, let item, player?.currentItem === item else { return }
        let time = item.currentTime()
        guard time.isNumeric else { return }
        let now = Self.ticks(time)
        loadAround(track: track, segment: session.subtitleSegment(atTicks: now))
        let generation = engine.generation
        if let planned, planned.generation == generation, planned.start <= now, planned.end - now > Self.refillTicks { return }
        guard !rendering else {
            needsPlan = true
            return
        }
        // Without the segments' frame times there are no events either; their load plans again.
        guard let frames = frameTimes(from: now, to: now + Self.leadTicks), !frames.isEmpty else { return }
        rendering = true
        let selection = selection
        let end = now + Self.leadTicks
        engine.render(frames.map(ASSTime.milliseconds(ticks:))) { [weak self] rendered, images in
            guard let self, self.selection == selection else { return }
            self.rendering = false
            if rendered == self.engine?.generation {
                self.overlay.install(frames: frames, images: images, end: end)
                self.planned = (frames[0], end, rendered)
            }
            if self.needsPlan || rendered != self.engine?.generation {
                self.needsPlan = false
                self.plan()
            }
        }
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
                self.engine?.add(loaded.events)
                self.plan()
            }
        }
    }

    private static func ticks(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 10_000_000, method: .roundHalfAwayFromZero).value
    }
}

/// Hosts the `AVSynchronizedLayer` the subtitle images are animated in.
private final class ASSOverlayView: UIView {
    private var syncLayer: AVSynchronizedLayer?
    private let imageLayer = CALayer()
    var scale: CGFloat = 1
    var layout: LibassRenderer.Layout?
    var onLayout: (() -> Void)?

    func attach(_ item: AVPlayerItem?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        syncLayer?.removeFromSuperlayer()
        imageLayer.removeAllAnimations()
        imageLayer.removeFromSuperlayer()
        syncLayer = nil
        if let item {
            let syncLayer = AVSynchronizedLayer(playerItem: item)
            syncLayer.frame = bounds
            imageLayer.anchorPoint = .zero
            imageLayer.contentsGravity = .resize
            syncLayer.addSublayer(imageLayer)
            layer.addSublayer(syncLayer)
            self.syncLayer = syncLayer
        }
        CATransaction.commit()
        layout = nil
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAllAnimations()
        CATransaction.commit()
    }

    func install(frames: [Int64], images: [ASSRenderedFrame], end: Int64) {
        guard let group = ASSKeyframes.animation(frames: frames, images: images, end: end, scale: scale) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.add(group, forKey: "ass")
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        syncLayer?.frame = bounds
        CATransaction.commit()
        onLayout?()
    }
}
#endif
