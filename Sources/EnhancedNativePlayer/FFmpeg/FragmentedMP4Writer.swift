import EPLibavcodec
import EPLibavformat
import EPLibavutil
import Foundation

private final class ByteSink {
    var bytes = Data()
}

private func sinkWrite(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return size }
    Unmanaged<ByteSink>.fromOpaque(opaque).takeUnretainedValue().bytes.append(buffer, count: Int(size))
    return size
}

/// A single-track `mp4` muxer producing HLS fMP4: one init (`ftyp`+`moov`) and then
/// one `moof`+`mdat` per `flush()`, collected in memory.
///
/// The movflags are hlsenc's fMP4 set (`frag_custom+dash+delay_moov`) plus:
/// - `frag_discont` with `use_editlist=0`: the first fragment's `tfdt` is the packet's
///   own decode time instead of zero, so a run that starts at segment k writes the
///   same `tfdt` a run from the start would have. Every run is "discontinuous".
/// - `skip_sidx`: with a sidx, movenc rewrites the first sample's pts of every
///   fragment to line up with the previous one, which would make a fragment's bytes
///   depend on where the run started.
/// - `avoid_negative_ts=disabled`: timestamps are already shifted onto a positive
///   timeline (see `Timeline`), and must not be re-based per run.
final class FragmentedMP4Writer {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var avio: UnsafeMutablePointer<AVIOContext>?
    private let sink = Unmanaged.passRetained(ByteSink())
    private(set) var stream: UnsafeMutablePointer<AVStream>
    private(set) var timeBase: Rational
    private var released = false

    /// ISO BMFF `styp`, written at the head of each media segment exactly like hlsenc's `write_styp`.
    static let styp: Data = {
        var box = Data([0, 0, 0, 24])
        box.append(contentsOf: Array("stypmsdh".utf8))
        box.append(contentsOf: [0, 0, 0, 0])
        box.append(contentsOf: Array("msdhmsix".utf8))
        return box
    }()

    init(configure: (UnsafeMutablePointer<AVStream>) throws -> Void) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        try FF.check(avformat_alloc_output_context2(&ctx, nil, "mp4", nil), "avformat_alloc_output_context2")
        guard let ctx, let stream = avformat_new_stream(ctx, nil) else {
            throw EnhancedPlayerError.ffmpeg(operation: "avformat_new_stream", code: -ENOMEM, message: "out of memory")
        }
        context = ctx
        self.stream = stream
        self.timeBase = Rational(num: 1, den: 1)
        do {
            try configure(stream)
            let size: Int32 = 64 * 1024
            guard let buffer = av_malloc(Int(size))?.assumingMemoryBound(to: UInt8.self),
                  let io = avio_alloc_context(buffer, size, 1, sink.toOpaque(), nil, sinkWrite, nil) else {
                throw EnhancedPlayerError.ffmpeg(operation: "avio_alloc_context", code: -ENOMEM, message: "out of memory")
            }
            avio = io
            ctx.pointee.pb = io
            // dvcC / dvvC (Dolby Vision) is only written at -strict unofficial.
            ctx.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL

            var options: OpaquePointer?
            av_dict_set(&options, "movflags", "+frag_custom+dash+delay_moov+frag_discont+skip_sidx", 0)
            av_dict_set(&options, "use_editlist", "0", 0)
            av_dict_set(&options, "avoid_negative_ts", "disabled", 0)
            av_dict_set(&options, "fflags", "-autobsf", 0)
            let result = avformat_write_header(ctx, &options)
            av_dict_free(&options)
            try FF.check(result, "avformat_write_header")
            timeBase = stream.timeBase
        } catch {
            // deinit also runs for a fully initialized instance; release() is idempotent.
            release()
            throw error
        }
    }

    deinit { release() }

    /// Writes one packet already expressed in `timeBase`.
    func write(_ packet: Packet) throws {
        packet.pointer.pointee.stream_index = 0
        packet.pointer.pointee.pos = -1
        try FF.check(av_write_frame(context, packet.pointer), "av_write_frame")
    }

    /// Closes the current fragment and returns every byte produced since the last call.
    /// With `delay_moov`, the first call returns the init segment and keeps the samples
    /// buffered for the next one.
    func flush() throws -> Data {
        try FF.check(av_write_frame(context, nil), "av_write_frame(flush)")
        avio_flush(avio)
        let sink = sink.takeUnretainedValue()
        let bytes = sink.bytes
        sink.bytes = Data()
        return bytes
    }

    private func release() {
        guard !released else { return }
        released = true
        if let ctx = context {
            // No trailer: the mfra index means nothing for HLS segments.
            avformat_free_context(ctx)
            context = nil
        }
        if avio != nil {
            av_freep(&avio!.pointee.buffer)
            avio_context_free(&avio)
        }
        sink.release()
    }
}
