@preconcurrency import AVFoundation

extension AVMediaSelectionOption {
    /// The rendition's NAME. `displayName` is built from LANGUAGE and FORCED instead,
    /// which several tracks can share; NAME is the title in the option's metadata.
    var renditionName: String? {
        AVMetadataItem.metadataItems(from: commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
    }
}

#if canImport(UIKit) && !os(watchOS)
import Logging
import QuartzCore
import UIKit

/// Draws the selected PGS track in `AVPlayerViewController.contentOverlayView`, which sits
/// above the video and below the controls. HLS can't carry bitmaps, so a PGS rendition's
/// segments are empty and its selection in the player's menu only says what to draw here.
@MainActor
final class PGSSubtitleRenderer {
    private let session: EnhancedPlaybackSession
    private let overlay = PGSOverlayView()
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var selectionObserver: NSObjectProtocol?
    private var track: Int?
    private var frames: [PGSFrame] = []
    private var framesSegment: Int?
    private var loadTask: Task<Void, Never>?

    init(session: EnhancedPlaybackSession, container: UIView) {
        self.session = session
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        container.addSubview(overlay)
    }

    /// Follows the subtitle selection of `item`, replacing whatever was attached before.
    func attach(player: AVPlayer, item: AVPlayerItem) {
        detach()
        self.player = player
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelection(of: item) }
        }
        updateSelection(of: item)
    }

    func stop() {
        detach()
        overlay.removeFromSuperview()
    }

    private func detach() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        select(track: nil)
        player = nil
    }

    private func updateSelection(of item: AVPlayerItem) {
        Task { [weak self] in
            // The group only exists once the master playlist has been read.
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), let self, self.player?.currentItem === item else { return }
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
            Logger.player.info("Subtitle selection: \(option?.displayName ?? "none")")
            self.select(track: option?.renditionName.flatMap { self.session.pgsTrack(named: $0) })
        }
    }

    private func select(track: Int?) {
        guard track != self.track else { return }
        self.track = track
        loadTask?.cancel()
        loadTask = nil
        frames = []
        framesSegment = nil
        overlay.show(nil)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        guard track != nil, let player else { return }
        // A time observer also fires on seeks and on starting and stopping, so a paused seek redraws too.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.update(at: time) }
        }
        update(at: player.currentTime())
    }

    private func update(at time: CMTime) {
        guard let track, time.isNumeric else { return }
        let ticks = Int64(time.seconds * 10_000_000)
        let segment = session.subtitleSegment(atTicks: ticks)
        if segment != framesSegment {
            // After a seek the frames in hand say nothing. In plain playback they're still right until the next load lands.
            if let framesSegment, !(framesSegment...(framesSegment + 1)).contains(segment) {
                frames = []
            }
            load(track: track, segment: segment)
        }
        overlay.show(frames.last { $0.startTicks <= ticks })
    }

    private func load(track: Int, segment: Int) {
        framesSegment = segment
        loadTask?.cancel()
        loadTask = Task { [weak self, session] in
            do {
                let frames = try await session.pgsFrames(track: track, segment: segment)
                guard let self, !Task.isCancelled else { return }
                self.frames = frames
                if let time = self.player?.currentTime() { self.update(at: time) }
            } catch {
                if !(error is CancellationError) {
                    Logger.player.warning("PGS segment \(segment) of track \(track) not read: \(error)")
                }
                return
            }
            // So that frames starting right at the next boundary aren't late.
            _ = try? await session.pgsFrames(track: track, segment: segment + 1)
        }
    }
}

private final class PGSOverlayView: UIView {
    private var shown: PGSFrame?
    private var bitmapLayers: [CALayer] = []

    func show(_ frame: PGSFrame?) {
        guard frame?.startTicks != shown?.startTicks else { return }
        shown = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bitmapLayers.forEach { $0.removeFromSuperlayer() }
        bitmapLayers = (frame?.bitmaps ?? []).map { bitmap in
            let sublayer = CALayer()
            sublayer.contents = bitmap.makeImage()
            layer.addSublayer(sublayer)
            return sublayer
        }
        place()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place()
        CATransaction.commit()
    }

    private func place() {
        guard let shown else { return }
        for (bitmap, sublayer) in zip(shown.bitmaps, bitmapLayers) {
            sublayer.frame = shown.rect(of: bitmap, in: bounds.size)
        }
    }
}
#endif
