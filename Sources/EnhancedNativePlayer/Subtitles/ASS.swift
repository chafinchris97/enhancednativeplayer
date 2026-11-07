import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CoreGraphics
import Foundation
import Libass

/// One ASS event as Matroska stores it: the timing lives in the block, the rest is the
/// event line without its `Start` and `End` fields, which is what `ass_process_chunk` takes.
struct ASSEvent: Sendable, Equatable {
    /// Position in the playlist timeline.
    var startMilliseconds: Int64
    var durationMilliseconds: Int64
    /// `ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text`
    var data: [UInt8]
}

/// A font attached to the file, which ASS styles usually name.
struct ASSFont: Sendable {
    var name: String
    var data: [UInt8]
}

enum ASSTime {
    /// 100 ns ticks to the nearest millisecond, the unit libass keeps time in.
    static func milliseconds(ticks: Int64) -> Int64 {
        let shifted = ticks + 5_000
        return shifted >= 0 ? shifted / 10_000 : -((-shifted + 9_999) / 10_000)
    }

    private static let standardRates: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48, 50, 60000.0 / 1001, 60]

    /// The exact frame length, in ticks, of the standard rate within 0.1 % of `rate`.
    static func frameTicks(forRate rate: Double?) -> Double? {
        guard let rate, rate > 0, let standard = standardRates.first(where: { abs($0 - rate) / $0 < 0.001 }) else { return nil }
        return 10_000_000 / standard
    }
}

/// What one subtitle segment holds for libass.
struct ASSSegment: Sendable, Equatable {
    var events: [ASSEvent]
    /// Start of every video frame in the segment, in playlist ticks, ascending. These are the
    /// moments the picture changes, so the only ones a subtitle frame is needed for. Empty
    /// when the read doesn't walk the video (MP4), where frames come from the frame rate instead.
    var frameTicks: [Int64]
}

/// Reads a segment's events straight from its packets, without a decoder, along with the
/// video's frame times, which the same read passes over anyway.
enum ASSEventReader {
    static func read(context: RemuxContext, track: SubtitleTrack, segment: Int) throws -> ASSSegment {
        var events: [ASSEvent] = []
        var frames: [Int64] = []
        try SubtitlePacketReader.forEachPacket(context: context, track: track, segment: segment, videoFrame: { frames.append($0) }) { packet, position in
            let payload = packet.subtitlePayload
            guard !payload.isEmpty, packet.duration > 0 else { return }
            // Both ends are rounded, not the duration, so back-to-back events stay back to back.
            let start = ASSTime.milliseconds(ticks: position)
            let end = ASSTime.milliseconds(ticks: position + track.timeBase.rescaleNearest(packet.duration, to: .ticks))
            guard end > start else { return }
            events.append(ASSEvent(startMilliseconds: start, durationMilliseconds: end - start, data: payload))
        }
        // Frames arrive in decode order; B-frames put presentation times out of order.
        return ASSSegment(events: events, frameTicks: Array(Set(frames)).sorted())
    }
}

/// Matroska attachments come through libavformat as attachment streams whose extradata
/// is the file. They sit in the header (or behind a SeekHead entry), which every demuxer
/// open reads anyway, so this costs no extra download once the blocks are cached.
enum ASSFontReader {
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "pfb", "pfa"]

    static func read(file: RemoteFile, token: CancellationToken) throws -> [ASSFont] {
        let demuxer = try Demuxer(file: file, token: token, findStreamInfo: false)
        var fonts: [ASSFont] = []
        for index in 0..<demuxer.streamCount {
            let stream = demuxer.stream(index)
            let par = stream.codecpar
            guard par.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT, par.pointee.extradata_size > 0 else { continue }
            let name = stream.metadata("filename") ?? "attachment\(index)"
            let mime = stream.metadata("mimetype")?.lowercased() ?? ""
            let isFont = par.pointee.codec_id == AV_CODEC_ID_TTF || par.pointee.codec_id == AV_CODEC_ID_OTF
                || mime.contains("font") || mime.contains("truetype") || mime.contains("opentype")
                || fontExtensions.contains((name as NSString).pathExtension.lowercased())
            guard isFont else { continue }
            fonts.append(ASSFont(name: name, data: par.extradataBytes))
        }
        return fonts
    }
}

/// Keeps every segment's events once read. Unlike PGS bitmaps they are small, and the
/// libass track holds them all for the session anyway.
final class ASSEventStore: Sendable {
    private let context: RemuxContext
    private let cache = SubtitleSegmentCache<ASSSegment>()
    private let fontCache = SubtitleSegmentCache<[ASSFont]>()

    init(context: RemuxContext) {
        self.context = context
    }

    func segment(track: SubtitleTrack, segment: Int) async throws -> ASSSegment {
        let context = context
        return try await cache.value(track: track.index, segment: segment) {
            try ASSEventReader.read(context: context, track: track, segment: segment)
        }
    }

    /// The file's attached fonts, read once for every track.
    func fonts() async throws -> [ASSFont] {
        let context = context
        return try await fontCache.value(track: 0, segment: 0) {
            try ASSFontReader.read(file: context.file, token: context.token)
        }
    }
}

/// What libass drew for one moment: every image composed into one premultiplied BGRA
/// bitmap, placed in the frame's pixels. No image means nothing on screen.
struct ASSRenderedFrame: @unchecked Sendable {
    var image: CGImage?
    var rect: CGRect
}

/// One libass library, renderer and track. libass is not thread-safe, so an instance
/// must only ever be used from one thread at a time; `ASSRenderEngine` confines it to a serial queue.
final class LibassRenderer: @unchecked Sendable {
    /// How the frame lines up with the video. All values are in pixels.
    struct Layout: Equatable {
        var frameWidth: Int
        var frameHeight: Int
        /// The video's place in the frame; the rest is black bars.
        var video: CGRect
        /// The video's coded size, which scales blur and borders like the authoring tool did.
        var storageWidth: Int
        var storageHeight: Int
    }

    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    private let colorMatrix: ColorMangling?
    private var layout: Layout?
    private var last = ASSRenderedFrame(image: nil, rect: .zero)
    /// Set when the next render must compose even if libass reports no change.
    private var forceRedraw = true

    /// - Parameter videoMatrix: The video's YCbCr matrix, which decides how VSFilter-era
    ///   colours are mangled. Nil for HDR video, where subtitles are SDR and exact colour
    ///   matching is moot.
    init?(header: [UInt8], fonts: [ASSFont], videoMatrix: ColorMangling.Matrix?) {
        guard let library = ass_library_init() else { return nil }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        guard let track = ass_new_track(library) else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            return nil
        }
        self.library = library
        self.renderer = renderer
        self.track = track
        // Fonts embedded in the script's [Fonts] section.
        ass_set_extract_fonts(library, 1)
        for font in fonts {
            font.data.withUnsafeBufferPointer { data in
                data.withMemoryRebound(to: CChar.self) { ass_add_font(library, font.name, $0.baseAddress, Int32($0.count)) }
            }
        }
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 0)
        header.withUnsafeBufferPointer { data in
            data.withMemoryRebound(to: CChar.self) { ass_process_codec_private(track, $0.baseAddress.map { UnsafeMutablePointer(mutating: $0) }, Int32($0.count)) }
        }
        // The same event comes again whenever a segment is read twice; ReadOrder tells.
        ass_set_check_readorder(track, 1)
        colorMatrix = videoMatrix.flatMap { ColorMangling(header: track.pointee.YCbCrMatrix, video: $0) }
    }

    deinit {
        ass_free_track(track)
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    func set(layout: Layout) {
        guard layout != self.layout, layout.frameWidth > 0, layout.frameHeight > 0 else { return }
        self.layout = layout
        ass_set_frame_size(renderer, Int32(layout.frameWidth), Int32(layout.frameHeight))
        ass_set_storage_size(renderer, Int32(max(1, layout.storageWidth)), Int32(max(1, layout.storageHeight)))
        let video = layout.video.integral
        ass_set_margins(
            renderer,
            Int32(max(0, video.minY)),
            Int32(max(0, CGFloat(layout.frameHeight) - video.maxY)),
            Int32(max(0, video.minX)),
            Int32(max(0, CGFloat(layout.frameWidth) - video.maxX))
        )
        // Like VSFilter, everything is drawn over the picture, not in the bars.
        ass_set_use_margins(renderer, 0)
        last = ASSRenderedFrame(image: nil, rect: .zero)
        forceRedraw = true
    }

    func add(_ events: [ASSEvent]) {
        for event in events {
            event.data.withUnsafeBufferPointer { data in
                data.withMemoryRebound(to: CChar.self) {
                    ass_process_chunk(track, UnsafeMutablePointer(mutating: $0.baseAddress), Int32($0.count), event.startMilliseconds, event.durationMilliseconds)
                }
            }
        }
        forceRedraw = true
    }

    /// What shows at `milliseconds` in the playlist timeline. libass shows an event while
    /// `start <= now < start + duration`.
    func render(atMilliseconds milliseconds: Int64) -> ASSRenderedFrame {
        guard layout != nil else { return ASSRenderedFrame(image: nil, rect: .zero) }
        var change: Int32 = 0
        let images = ass_render_frame(renderer, track, milliseconds, &change)
        if change == 0, !forceRedraw { return last }
        forceRedraw = false
        last = compose(images)
        return last
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let grayColorSpace = CGColorSpaceCreateDeviceGray()

    /// Blends the images, back to front as libass lists them, into one bitmap the size of
    /// their union. Each libass bitmap is a coverage mask filled with its colour by Core
    /// Graphics, whose optimised blending this leaves to, so a frame with hundreds of
    /// images stays fast in a debug build too.
    private func compose(_ first: UnsafeMutablePointer<ASS_Image>?) -> ASSRenderedFrame {
        var bounds = CGRect.null
        var node = first
        while let image = node {
            if image.pointee.w > 0, image.pointee.h > 0 {
                bounds = bounds.union(CGRect(x: Int(image.pointee.dst_x), y: Int(image.pointee.dst_y), width: Int(image.pointee.w), height: Int(image.pointee.h)))
            }
            node = image.pointee.next
        }
        guard !bounds.isNull else { return ASSRenderedFrame(image: nil, rect: .zero) }
        let originX = Int(bounds.minX), originY = Int(bounds.minY)
        let width = Int(bounds.width), height = Int(bounds.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return ASSRenderedFrame(image: nil, rect: .zero) }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        node = first
        while let image = node {
            node = image.pointee.next
            let w = Int(image.pointee.w), h = Int(image.pointee.h)
            guard w > 0, h > 0, let bitmap = image.pointee.bitmap else { continue }
            var color = image.pointee.color
            if let colorMatrix { color = colorMatrix.apply(color) }
            let opacity = 255 - Int(color & 0xFF)
            guard opacity > 0 else { continue }
            let stride = Int(image.pointee.stride)
            // libass keeps the bitmap until the next render, and it is only drawn here, so no copy.
            guard let provider = CGDataProvider(dataInfo: nil, data: bitmap, size: stride * h, releaseData: { _, _, _ in }),
                  let mask = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: stride, space: Self.grayColorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { continue }
            // Bitmap contexts put y = 0 at the bottom; libass puts it at the top.
            let rect = CGRect(x: Int(image.pointee.dst_x) - originX, y: height - (Int(image.pointee.dst_y) - originY) - h, width: w, height: h)
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.setFillColor(CGColor(
                colorSpace: Self.colorSpace,
                components: [CGFloat(color >> 24) / 255, CGFloat(color >> 16 & 0xFF) / 255, CGFloat(color >> 8 & 0xFF) / 255, CGFloat(opacity) / 255]
            )!)
            context.fill(rect)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return ASSRenderedFrame(image: nil, rect: .zero) }
        return ASSRenderedFrame(image: image, rect: CGRect(x: originX, y: originY, width: width, height: height))
    }
}

/// VSFilter wrote subtitle colours into the video as BT.601 TV YCbCr whatever the video
/// was, and typesetters matched colours through that. libass leaves the mangling to the
/// player: `screen = video_to_rgb(rgb_to_header_matrix(ass))`, with a missing header
/// meaning TV.601 and `None` meaning untouched. See `ass_types.h`.
struct ColorMangling: Equatable {
    struct Matrix: Equatable {
        var kr: Double
        var kb: Double
        var isFullRange: Bool

        static let bt601 = Matrix(kr: 0.299, kb: 0.114, isFullRange: false)
        static let bt709 = Matrix(kr: 0.2126, kb: 0.0722, isFullRange: false)
    }

    let from: Matrix
    let to: Matrix

    init?(header: ASS_YCbCrMatrix, video: Matrix) {
        let from: Matrix
        switch header {
        case YCBCR_NONE: return nil
        case YCBCR_BT601_PC: from = Matrix(kr: 0.299, kb: 0.114, isFullRange: true)
        case YCBCR_BT709_TV: from = .bt709
        case YCBCR_BT709_PC: from = Matrix(kr: 0.2126, kb: 0.0722, isFullRange: true)
        case YCBCR_SMPTE240M_TV: from = Matrix(kr: 0.212, kb: 0.087, isFullRange: false)
        case YCBCR_SMPTE240M_PC: from = Matrix(kr: 0.212, kb: 0.087, isFullRange: true)
        case YCBCR_FCC_TV: from = Matrix(kr: 0.3, kb: 0.11, isFullRange: false)
        case YCBCR_FCC_PC: from = Matrix(kr: 0.3, kb: 0.11, isFullRange: true)
        default: from = .bt601 // missing, unknown or TV.601
        }
        guard from != video else { return nil }
        self.from = from
        self.to = video
    }

    /// Mangles an `RRGGBBAA` libass colour, keeping its alpha.
    func apply(_ color: UInt32) -> UInt32 {
        let r = Double(color >> 24) / 255, g = Double(color >> 16 & 0xFF) / 255, b = Double(color >> 8 & 0xFF) / 255
        // RGB to YCbCr with the header's matrix and range, in 8-bit code values.
        let y = from.kr * r + (1 - from.kr - from.kb) * g + from.kb * b
        let cb = (b - y) / (2 * (1 - from.kb))
        let cr = (r - y) / (2 * (1 - from.kr))
        let (yCode, cbCode, crCode) = from.isFullRange
            ? (y * 255, cb * 255 + 128, cr * 255 + 128)
            : (16 + y * 219, 128 + cb * 224, 128 + cr * 224)
        // Those code values read back as the video's matrix and range.
        let y2 = to.isFullRange ? yCode / 255 : (yCode - 16) / 219
        let cb2 = to.isFullRange ? (cbCode - 128) / 255 : (cbCode - 128) / 224
        let cr2 = to.isFullRange ? (crCode - 128) / 255 : (crCode - 128) / 224
        let r2 = y2 + 2 * (1 - to.kr) * cr2
        let b2 = y2 + 2 * (1 - to.kb) * cb2
        let g2 = (y2 - to.kr * r2 - to.kb * b2) / (1 - to.kr - to.kb)
        func code(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return code(r2) << 24 | code(g2) << 16 | code(b2) << 8 | (color & 0xFF)
    }
}
