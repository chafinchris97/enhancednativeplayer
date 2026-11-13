#if canImport(UIKit) && !os(watchOS)
@preconcurrency import AVFoundation
import Logging
import UIKit

/// Tone maps the video of `master_sdr.m3u8`. That master relabels HDR video as Rec. 709 so
/// AVPlayer takes it on an SDR display, which leaves the pixels PQ / HLG, and AVPlayer's own
/// picture washed out. This takes AVPlayer's decoded frames from an `AVPlayerItemVideoOutput`,
/// puts the file's real colour back on them (BT.2020 with PQ or HLG, plus the mastering display
/// and content light level when the container has them), and shows them in an
/// `AVSampleBufferDisplayLayer` over AVPlayer's picture, where the system maps them to SDR as it
/// does for HDR video the player draws. The layer goes where `RenderedVideoRenderer` puts its
/// own: under AVPlayer's subtitles when their layer is found.
///
/// Frames are taken on each display refresh, for the item time of the next one, and shown as
/// soon as they are enqueued, so pauses, seeks and rate changes need nothing of their own.
@MainActor
final class ToneMappedVideoRenderer {
    private let color: SourceHDRColor
    private let view = RenderedVideoView()
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var renderer: AVSampleBufferVideoRenderer?
    private var displayLink: CADisplayLink?
    private var formatDescription: CMVideoFormatDescription?
    private var loggedFirstFrame = false

    /// - Parameters:
    ///   - playerView: The player view controller's view, which holds AVPlayer's layer.
    ///   - container: `contentOverlayView`, where a view follows the player's size.
    init(color: SourceHDRColor, playerView: UIView, container: UIView) {
        self.color = color
        view.playerView = playerView
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        // Under the subtitle overlays, whichever was added first.
        container.insertSubview(view, at: 0)
    }

    /// Shows `item`'s video, replacing whatever was attached before.
    func attach(item: AVPlayerItem) {
        detach()
        self.item = item
        // 10-bit, as the decoder gives HDR video, so nothing is converted or lost.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            ],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ])
        item.add(output)
        self.output = output
        renderer = view.install(timebase: nil)
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] link in self?.refresh(link) }, selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        Logger.player.info("Tone mapping the SDR master's video (\(color.range.rawValue)\(color.metadata?.masteringDisplay == nil ? "" : ", mastering display")\(color.metadata?.contentLightLevel == nil ? "" : ", content light level")) \(view.isUnderPlayerSubtitles ? "under AVPlayer's subtitles" : "in the content overlay, above AVPlayer's subtitles: its subtitle layer wasn't found")")
    }

    func stop() {
        detach()
        view.removeFromSuperview()
    }

    private func detach() {
        displayLink?.invalidate()
        displayLink = nil
        if let output, let item { item.remove(output) }
        output = nil
        item = nil
        renderer = nil
        formatDescription = nil
        loggedFirstFrame = false
        view.remove()
    }

    private func refresh(_ link: CADisplayLink) {
        guard let output, let renderer else { return }
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var shownTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shownTime) else { return }
        color.apply(to: buffer)
        guard let sample = sample(for: buffer, time: shownTime.isValid ? shownTime : itemTime) else { return }
        if renderer.status == .failed {
            Logger.player.error("Tone mapped video layer failed: \(renderer.error.map { "\($0)" } ?? "no error"), flushing")
            renderer.flush()
        }
        renderer.enqueue(sample)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            Logger.player.info("Tone mapped video: first frame \(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer)) \(String(format: "%08X", CVPixelBufferGetPixelFormatType(buffer)))")
        }
    }

    private func sample(for buffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description) == noErr else { return nil }
            formatDescription = description
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // The layer has no timebase: the frame was taken for the coming refresh.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// `CADisplayLink` keeps its target, so the renderer is reached weakly through this.
private final class DisplayLinkTarget: NSObject {
    private let action: @MainActor (CADisplayLink) -> Void

    init(_ action: @escaping @MainActor (CADisplayLink) -> Void) {
        self.action = action
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        action(link)
    }
}
#endif
