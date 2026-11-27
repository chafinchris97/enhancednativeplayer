import EPLibavcodec
import EPLibavformat
import EPLibavutil
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Logging

/// Pictures for chapters that have none: the video at each chapter's start, as a JPEG.
///
/// Only keyframes are decoded, each on its own, so a picture costs one packet read and one
/// frame decoded, never the frames between a keyframe and an exact time. The first keyframe at
/// or after the chapter's start is tried first; a nearly black one (a fade, a title card's lead-in)
/// gives way to a later keyframe of the same chapter, up to `attempts` in all, and the brightest
/// one tried is kept.
///
/// It reads through the session's `RemoteFile` with a lookup reader of its own, so playback's
/// connection is never moved. Not thread-safe: one thread uses it at a time.
final class ChapterThumbnailer {
    /// The picture's height in pixels, at most; its width follows the video's display aspect.
    static let height = 360
    /// Keyframes tried per chapter before the brightest one so far is kept.
    static let attempts = 3
    /// How far past the last keyframe tried the next one is looked for, in 100 ns ticks.
    static let retryStep: Int64 = 30_000_000
    /// Average luma below this share of the nominal range counts as black.
    static let darkLevel = 0.08

    private let demuxer: Demuxer
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private let streamIndex: Int32
    private let converter: PixelBufferConverter
    private let packet = Packet()
    private let token: CancellationToken
    private let logger: Logger
    /// Index timestamps, and each keyframe's presentation time in the file's timeline (100 ns ticks).
    private let keyframes: [Int64]
    private let keyframeTicks: [Int64]
    private let sampleAspect: Rational

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Nil when the video can't be pictured here: Dolby Vision profile 5 has no base layer
    /// a plain decoder shows in the right colours, and some codecs have no decoder in the build.
    init?(file: RemoteFile, media: MediaInfo, token: CancellationToken, logger: Logger) {
        self.logger = logger
        self.token = token
        let video = media.video
        if video.dolbyVision?.profile == 5 { return nil }
        guard let demuxer = try? Demuxer(file: file, token: token, findStreamInfo: false, role: .lookup) else { return nil }
        self.demuxer = demuxer
        demuxer.discardAll(except: [video.streamIndex])
        streamIndex = video.streamIndex
        let shift = media.keyframes.usesDecodeTimestamps ? media.keyframes.presentationOffset : 0
        let timeBase = media.keyframes.timeBase
        keyframes = media.keyframes.timestamps
        keyframeTicks = keyframes.map { timeBase.rescaleNearest($0 + shift, to: .ticks) }

        let parameters = demuxer.stream(video.streamIndex).pointee.codecpar!.pointee
        let aspect = Rational(parameters.sample_aspect_ratio)
        sampleAspect = aspect.isValid ? aspect : Rational(num: 1, den: 1)
        let source = video.rendered ?? RenderedVideoSource(
            codecID: parameters.codec_id.rawValue,
            codecName: String(cString: avcodec_get_name(parameters.codec_id)),
            pixelFormat: parameters.format,
            sampleAspect: sampleAspect,
            colorPrimaries: Int32(parameters.color_primaries.rawValue),
            colorTransfer: Int32(parameters.color_trc.rawValue),
            colorSpace: Int32(parameters.color_space.rawValue),
            colorRange: Int32(parameters.color_range.rawValue)
        )
        converter = PixelBufferConverter(source: source)

        guard let decoder = VideoRoute.decoder(for: parameters.codec_id) else {
            logger.notice("No decoder for \(source.codecName) video; chapters keep no pictures")
            return nil
        }
        var ctx = avcodec_alloc_context3(decoder)
        guard let context = ctx else { return nil }
        let stream = demuxer.stream(video.streamIndex)
        guard avcodec_parameters_to_context(context, stream.pointee.codecpar) >= 0 else {
            avcodec_free_context(&ctx)
            return nil
        }
        context.pointee.pkt_timebase = stream.pointee.time_base
        // One frame at a time: frame threads would only hold it back.
        context.pointee.thread_count = 0
        context.pointee.thread_type = FF_THREAD_SLICE
        // Deblocking and SAO are a large share of a 4K intra frame's decode, and invisible at 360 lines.
        context.pointee.skip_loop_filter = AVDISCARD_ALL
        guard avcodec_open2(context, decoder, nil) >= 0 else {
            avcodec_free_context(&ctx)
            return nil
        }
        codec = context
    }

    deinit {
        avcodec_free_context(&codec)
    }

    /// A JPEG of the chapter running over `range` (the file's timeline), nil when no keyframe
    /// in or before it decodes.
    func picture(for range: Range<Duration>) -> Data? {
        let start = Int64((range.lowerBound.timeInterval * 1e7).rounded())
        let end = Int64((range.upperBound.timeInterval * 1e7).rounded())
        var candidates: [Int] = []
        var from = start
        while candidates.count < Self.attempts {
            let index = firstKeyframe(atOrAfter: from)
            guard index < keyframeTicks.count, keyframeTicks[index] < end else { break }
            candidates.append(index)
            from = keyframeTicks[index] + Self.retryStep
        }
        // No keyframe inside the chapter: the one it starts in.
        if candidates.isEmpty, let before = keyframeTicks.lastIndex(where: { $0 <= start }) { candidates = [before] }

        var best: (frame: UnsafeMutablePointer<AVFrame>, brightness: Double)?
        defer { if let best { free(best.frame) } }
        for index in candidates {
            if token.isCancelled { return nil }
            guard let frame = decodeKeyframe(index) else { continue }
            let brightness = Self.brightness(frame)
            if let current = best, current.brightness >= brightness {
                free(frame)
            } else {
                if let current = best { free(current.frame) }
                best = (frame, brightness)
            }
            if brightness >= Self.darkLevel { break }
        }
        guard let best else { return nil }
        return jpeg(best.frame)
    }

    private func firstKeyframe(atOrAfter ticks: Int64) -> Int {
        var low = 0, high = keyframeTicks.count
        while low < high {
            let mid = (low + high) / 2
            if keyframeTicks[mid] < ticks { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Seeks to keyframe `index` and decodes it alone.
    private func decodeKeyframe(_ index: Int) -> UnsafeMutablePointer<AVFrame>? {
        guard let codec else { return nil }
        avcodec_flush_buffers(codec)
        do {
            try demuxer.seek(stream: streamIndex, timestamp: keyframes[index])
            // The seek lands on the index entry; its keyframe is the stream's next key packet.
            var found = false
            for _ in 0..<64 {
                guard try demuxer.read(into: packet) else { break }
                if packet.streamIndex == streamIndex, packet.pointer.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                    found = true
                    break
                }
            }
            guard found else { return nil }
        } catch {
            if !token.isCancelled { logger.debug("Chapter picture: keyframe \(index) not read: \(error)") }
            return nil
        }
        guard avcodec_send_packet(codec, packet.pointer) >= 0 else { return nil }
        packet.unref()
        guard let frame = av_frame_alloc() else { return nil }
        var received = avcodec_receive_frame(codec, frame)
        if received == FF.errorEAGAIN {
            avcodec_send_packet(codec, nil)
            received = avcodec_receive_frame(codec, frame)
        }
        guard received == 0 else {
            free(frame)
            return nil
        }
        return frame
    }

    /// Average luma over a grid of samples, 0 at nominal black and 1 at nominal white.
    private static func brightness(_ frame: UnsafePointer<AVFrame>) -> Double {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let tenBit = format == AV_PIX_FMT_YUV420P10LE
        let fullRange = format == AV_PIX_FMT_YUVJ420P || frame.pointee.color_range == AVCOL_RANGE_JPEG
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        guard let plane = frame.pointee.data.0, width > 0, height > 0 else { return 0 }
        let stride = Int(frame.pointee.linesize.0)
        var total = 0.0, count = 0.0
        for row in 0..<36 {
            let y = (row * 2 + 1) * height / 72
            for column in 0..<64 {
                let x = (column * 2 + 1) * width / 128
                let value = tenBit
                    ? Double(UnsafeRawPointer(plane + y * stride).assumingMemoryBound(to: UInt16.self)[x]) / 4
                    : Double(plane[y * stride + x])
                total += value
                count += 1
            }
        }
        let (black, white) = fullRange ? (0.0, 255.0) : (16.0, 235.0)
        return (total / count - black) / (white - black)
    }

    private func jpeg(_ frame: UnsafePointer<AVFrame>) -> Data? {
        // The converter's samples carry the frame's colour, which Core Image reads off the buffer.
        guard let sample = converter.sample(for: frame, start: 0, end: 1), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            logger.debug("Chapter picture: pixel format \(frame.pointee.format) not converted")
            return nil
        }
        var image: CIImage
        if #available(iOS 18, tvOS 18, macOS 15, *) {
            image = CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true])
        } else {
            image = CIImage(cvPixelBuffer: buffer)
        }
        let pixelHeight = Double(frame.pointee.height)
        let scale = min(1, Double(Self.height) / pixelHeight)
        let frameAspect = Rational(frame.pointee.sample_aspect_ratio)
        let aspect = (frameAspect.isValid ? frameAspect : sampleAspect).doubleValue
        image = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: aspect,
        ])
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        return Self.context.jpegRepresentation(of: image, colorSpace: sRGB, options: options)
    }

    private func free(_ frame: UnsafeMutablePointer<AVFrame>) {
        var pointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&pointer)
    }
}
