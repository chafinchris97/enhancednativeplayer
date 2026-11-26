#if canImport(UIKit) && !os(watchOS)
@preconcurrency import AVFoundation
import Logging
import UIKit

/// Draws video AVPlayer can't decode (AV1, VC-1, MPEG-4 Part 2, …) where AVPlayer draws its own
/// picture: inside the `AVPlayerLayer`, above AVPlayer's picture (only a black placeholder) and
/// below the subtitle layer AVPlayer draws text subtitles in, so SRT and WebVTT still show in the
/// system's subtitle style. PGS, ASS and the controls are above it in any case. That layer is
/// AVPlayer's own and has no public name, so it is found by its class; if it isn't there, the
/// picture goes to the bottom of `contentOverlayView` instead, above AVPlayer's subtitles.
///
/// The frames go to an `AVSampleBufferDisplayLayer` whose control timebase is the player item's
/// own, so they follow the item's clock (the one the audio plays on) through pauses, seeks, rate
/// changes and stalls, and the controls work on the video the way they do on AVPlayer's.
@MainActor
final class RenderedVideoRenderer {
    private let session: EnhancedPlaybackSession
    private let logger: Logger
    private let view = RenderedVideoView()
    private weak var item: AVPlayerItem?
    private var feeder: RenderedVideoFeeder?
    private var jumpObserver: NSObjectProtocol?
    private var startTask: Task<Void, Never>?

    /// - Parameters:
    ///   - playerView: The player view controller's view, which holds AVPlayer's layer.
    ///   - container: `contentOverlayView`, where a view follows the player's size.
    init(session: EnhancedPlaybackSession, playerView: UIView, container: UIView) {
        self.session = session
        logger = session.logger.category(.video)
        view.playerView = playerView
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        // Under the subtitle overlays, whichever was added first.
        container.insertSubview(view, at: 0)
    }

    /// Shows the video on `item`'s clock, replacing whatever was attached before.
    func attach(item: AVPlayerItem) {
        detach()
        self.item = item
        startTask = Task { [weak self] in
            // The item has a timebase once it is the player's current item, not always at once.
            var timebase = item.timebase
            for _ in 0..<200 where timebase == nil {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
                timebase = item.timebase
            }
            guard let self, !Task.isCancelled, self.item === item else { return }
            guard let timebase else {
                logger.error("The player item has no timebase to show the video on")
                return
            }
            self.start(item: item, timebase: timebase)
        }
    }

    func stop() {
        detach()
        view.removeFromSuperview()
    }

    private func start(item: AVPlayerItem, timebase: CMTimebase) {
        let renderer = view.install(timebase: timebase)
        let session = session
        let token = CancellationToken(parent: session.cancellationToken)
        let size = session.videoSize
        let feeder = RenderedVideoFeeder(
            renderer: renderer,
            timebase: timebase,
            startTicks: Self.ticks(item.currentTime()),
            frameBytes: session.videoFrameBytes,
            token: token,
            logger: logger,
            makeDecoder: { try session.makeVideoDecoder(token: token) }
        )
        self.feeder = feeder
        logger.info("Drawing the video (\(Int(size.width))×\(Int(size.height))) \(view.isUnderPlayerSubtitles ? "under AVPlayer's subtitles" : "in the content overlay, above AVPlayer's subtitles: its subtitle layer wasn't found")")
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak feeder] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            let time = item.currentTime()
            guard time.isNumeric else { return }
            feeder?.timeJumped(to: Self.ticks(time))
        }
        // The server holds a seek's first segment until the frame AVPlayer starts on is queued.
        session.videoStartGate?.attach(VideoStartGate.Source(
            reportedTicks: { [weak self] in await self?.reportedTicks() },
            decode: { [weak feeder] in feeder?.decode(at: $0) },
            covers: { [weak feeder] in feeder?.covers($0) ?? true },
            progress: { [weak feeder] in feeder?.progress ?? 0 }
        ))
    }

    /// AVPlayer's current time, which is a pending seek's target before its clock moves there.
    private func reportedTicks() -> Int64? {
        guard let item else { return nil }
        let time = item.currentTime()
        return time.isNumeric ? Self.ticks(time) : nil
    }

    private func detach() {
        startTask?.cancel()
        startTask = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        session.videoStartGate?.attach(nil)
        feeder?.stop()
        feeder = nil
        // The layer runs on this item's timebase, so it goes with the item.
        view.remove()
        item = nil
    }

    private nonisolated static func ticks(_ time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        return CMTimeConvertScale(time, timescale: 10_000_000, method: .roundTowardNegativeInfinity).value
    }
}

/// Places the `AVSampleBufferDisplayLayer` the player's own frames are shown in (decoded ones,
/// or AVPlayer's tone mapped), and keeps it the player's size. The view itself sits in
/// `contentOverlayView`, which is always the player's size; it only shows anything when the
/// layer had to go in it.
final class RenderedVideoView: UIView {
    weak var playerView: UIView?
    private var displayLayer: AVSampleBufferDisplayLayer?

    /// Whether the layer is in AVPlayer's layer, under its subtitles.
    var isUnderPlayerSubtitles: Bool { displayLayer.map { $0.superlayer !== layer } ?? false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A new layer, replacing the one before, on `timebase` or showing each frame as it is
    /// enqueued. Returns the layer's renderer.
    func install(timebase: CMTimebase?) -> AVSampleBufferVideoRenderer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remove()
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        // Covers AVPlayer's own picture.
        displayLayer.backgroundColor = UIColor.black.cgColor
        if let timebase { displayLayer.controlTimebase = timebase }
        if let (parent, subtitles) = playerView.flatMap(Self.subtitleSlot) {
            parent.insertSublayer(displayLayer, below: subtitles)
            displayLayer.frame = parent.bounds
        } else {
            backgroundColor = .black
            layer.addSublayer(displayLayer)
            displayLayer.frame = bounds
        }
        self.displayLayer = displayLayer
        CATransaction.commit()
        return displayLayer.sampleBufferRenderer
    }

    /// Takes the layer away, if there is one.
    func remove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        backgroundColor = nil
        CATransaction.commit()
    }

    /// The layer AVPlayer draws its picture and subtitles in, and the subtitle layer inside it:
    /// in the player's visible `AVPlayerLayer` (the scrubbing thumbnails have their own, zero-sized
    /// ones), the sublayer that holds a layer whose class names subtitles.
    private static func subtitleSlot(in view: UIView) -> (CALayer, CALayer)? {
        var queue: [CALayer] = [view.layer]
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if candidate is AVPlayerLayer, !candidate.isHidden, !candidate.bounds.isEmpty {
                for parent in candidate.sublayers ?? [] {
                    if let subtitles = parent.sublayers?.first(where: { String(describing: type(of: $0)).contains("Subtitle") }) {
                        return (parent, subtitles)
                    }
                }
            }
            queue += candidate.sublayers ?? []
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let displayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = displayLayer.superlayer === layer ? bounds : (displayLayer.superlayer?.bounds ?? bounds)
        CATransaction.commit()
    }
}
#endif
