import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import Foundation

/// Output format for a track that is transcoded to FLAC. Derived from the probe
/// alone, so the init segment and every run agree on it.
struct FLACFormat {
    let sampleRate: Int32
    let sampleFormat: AVSampleFormat
    let bitsPerRawSample: Int32
    private(set) var layout = AVChannelLayout()

    init(track: AudioTrack, stream: UnsafeMutablePointer<AVStream>) throws {
        sampleRate = Int32(track.sampleRate)
        // 16-bit sources stay 16-bit; anything deeper, and every float decoder, is 24-bit.
        if track.bitsPerRawSample > 0, track.bitsPerRawSample <= 16 {
            sampleFormat = AV_SAMPLE_FMT_S16
            bitsPerRawSample = 16
        } else {
            sampleFormat = AV_SAMPLE_FMT_S32
            bitsPerRawSample = 24
        }

        // FLAC defines one channel order per count (flac.c); the encoder accepts those.
        let channels = min(max(Int(stream.codecpar.pointee.ch_layout.nb_channels), track.channels, 1), 8)
        let name = ["mono", "stereo", "3.0", "quad", "5.0", "5.1", "6.1", "7.1"][channels - 1]
        try FF.check(av_channel_layout_from_string(&layout, name), "av_channel_layout_from_string(\(name))")
    }

    func makeEncoder() throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_FLAC), let ctx = avcodec_alloc_context3(codec) else {
            throw EnhancedPlayerError.ffmpeg(operation: "avcodec_alloc_context3(flac)", code: -ENOMEM, message: "out of memory")
        }
        ctx.pointee.sample_rate = sampleRate
        ctx.pointee.sample_fmt = sampleFormat
        ctx.pointee.bits_per_raw_sample = bitsPerRawSample
        ctx.pointee.time_base = AVRational(num: 1, den: sampleRate)
        var layout = layout
        av_channel_layout_copy(&ctx.pointee.ch_layout, &layout)
        let opened = avcodec_open2(ctx, codec, nil)
        if opened < 0 {
            var p: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&p)
            try FF.check(opened, "avcodec_open2(flac)")
        }
        return ctx
    }

    static func configure(_ output: UnsafeMutablePointer<AVStream>, from encoder: UnsafeMutablePointer<AVCodecContext>) throws {
        try FF.check(avcodec_parameters_from_context(output.codecpar, encoder), "avcodec_parameters_from_context")
        output.pointee.time_base = encoder.pointee.time_base
    }

    var channelCount: Int { Int(layout.nb_channels) }
    var bytesPerFrame: Int { channelCount * Int(av_get_bytes_per_sample(sampleFormat)) }
}

/// Decodes any other codec (DTS, TrueHD, Opus, MP3, PCM, ...) and re-encodes it as FLAC.
///
/// The output is the stream one FLAC encode of the whole track would produce:
/// fixed-size blocks on a grid of `blockSize` samples from the track start, each
/// frame header carrying its absolute frame number, and a short block only at the
/// very end. Apple's FLAC decoder rejects anything else (a short block mid-stream,
/// or frame numbers starting over), with CoreMedia error -16170.
///
/// Like a copied codec's packets, segment k starts with the first block at or after
/// the video segment's start. A run that seeked starts encoding on that block, and
/// renumbers its frames onto the grid, so segment k comes out the same from any run.
struct FLACTranscodeProducer: SegmentProducer {
    let context: RemuxContext
    let track: AudioTrack

    func produce(_ run: RemuxRun) throws {
        let start = run.startSegment
        let plan = context.plan
        let demuxer = try openAudioDemuxer(context: context, track: track, start: start, token: run.token)
        let input = demuxer.stream(track.streamIndex)
        let format = try FLACFormat(track: track, stream: input)

        var encoder: UnsafeMutablePointer<AVCodecContext>? = try format.makeEncoder()
        defer { avcodec_free_context(&encoder) }
        let writer = try FragmentedMP4Writer { output in try FLACFormat.configure(output, from: encoder!) }
        let emitter = SegmentEmitter(writer: writer, run: run)
        let blockSize = Int64(encoder!.pointee.frame_size > 0 ? encoder!.pointee.frame_size : 4608)

        let sampleTB = Rational(num: 1, den: format.sampleRate)
        let outTB = emitter.timeBase
        let videoTB = context.media.video.timeBase
        let offset = context.timeline.offset(in: sampleTB)
        let origin = track.timeBase.rescaleNearest(track.startTime, to: sampleTB)
        // First block of each segment: block 0 for segment 0, otherwise the first
        // block starting at or after the segment's video start.
        let firstBlock: [Int64] = (0..<plan.count).map { index in
            guard index > 0 else { return 0 }
            let boundary = videoTB.rescaleNearest(context.presentationStart(of: index), to: sampleTB)
            return max(0, (boundary - origin + blockSize - 1) / blockSize)
        }
        let startBlock = firstBlock[start]
        let startSample = origin + startBlock * blockSize

        let decoder = try AudioDecoder(stream: input)
        let converter = SampleConverter(format: format)
        let fifo = SampleFIFO(bytesPerFrame: format.bytesPerFrame)
        var expected: Int64?
        var nextBlock = startBlock
        var current = start
        let frame = Frame()
        let packet = Packet()

        func receivePackets() throws {
            while true {
                let result = avcodec_receive_packet(encoder, packet.pointer)
                if result == FF.errorEAGAIN || result == FF.errorEOF { return }
                try FF.check(result, "avcodec_receive_packet(flac)")
                av_packet_free_side_data(packet.pointer)
                let out = packet.clone()
                packet.unref()
                let block = (out.pts - origin) / blockSize
                out.withData { FLACFrameHeader.renumber($0, frameNumber: UInt64(block)) }
                while current + 1 < plan.count, block >= firstBlock[current + 1] { current += 1 }
                out.pts = sampleTB.rescale(out.pts + offset, to: outTB)
                out.dts = out.pts
                out.duration = sampleTB.rescale(out.duration, to: outTB)
                try emitter.push(out, segment: current)
            }
        }

        func encode(samples count: Int) throws {
            av_frame_unref(frame.pointer)
            frame.pointer.pointee.nb_samples = Int32(count)
            frame.pointer.pointee.format = format.sampleFormat.rawValue
            frame.pointer.pointee.sample_rate = format.sampleRate
            var layout = format.layout
            av_channel_layout_copy(&frame.pointer.pointee.ch_layout, &layout)
            try FF.check(av_frame_get_buffer(frame.pointer, 0), "av_frame_get_buffer")
            frame.pointer.pointee.pts = fifo.start
            fifo.read(count, into: frame.pointer.pointee.data.0!)
            try FF.check(avcodec_send_frame(encoder, frame.pointer), "avcodec_send_frame(flac)")
            nextBlock += 1
            try receivePackets()
        }

        func accept(_ decoded: UnsafeMutablePointer<AVFrame>) throws {
            let nbSamples = Int64(decoded.pointee.nb_samples)
            guard nbSamples > 0 else { return }
            var position = expected ?? 0
            let ts = decoded.pointee.best_effort_timestamp != FF.noPTS ? decoded.pointee.best_effort_timestamp : decoded.pointee.pts
            if ts != FF.noPTS {
                let stamped = track.timeBase.rescaleNearest(ts, to: sampleTB)
                if let expected {
                    // Follow the decoded sample count; only a real gap or overlap
                    // (beyond 100 ms) moves the position back onto the timestamps.
                    if abs(stamped - expected) > Int64(format.sampleRate / 10) { position = stamped }
                } else {
                    position = alignToFrameGrid(stamped, frameSize: nbSamples, origin: origin)
                }
            }

            let converted = try converter.convert(decoded)
            guard !converted.isEmpty else { return }
            var bytes = converted
            if expected == nil {
                fifo.reset(start: position)
            } else if position > fifo.end {
                fifo.appendSilence(Int(min(position - fifo.end, Int64(format.sampleRate) * 10)))
            } else if position < fifo.end {
                let overlap = Int(fifo.end - position) * format.bytesPerFrame
                bytes = overlap >= bytes.count ? Data() : bytes.subdata(in: overlap..<bytes.count)
            }
            fifo.append(bytes)
            expected = fifo.end

            // Lead-in before the run's first block (the seek preroll) is dropped. A
            // track that starts late is padded so blocks stay on the grid.
            if fifo.start < startSample {
                fifo.drop(Int(min(Int64(fifo.count), startSample - fifo.start)))
            }
            if nextBlock == startBlock, fifo.count > 0, fifo.start > startSample {
                fifo.prependSilence(Int(fifo.start - startSample))
            }
            while fifo.start == origin + nextBlock * blockSize, Int64(fifo.count) >= blockSize {
                try encode(samples: Int(blockSize))
            }
        }

        while try demuxer.read(into: packet) {
            guard packet.streamIndex == track.streamIndex else { continue }
            for decodedFrame in try decoder.decode(packet) {
                try accept(decodedFrame.pointer)
            }
        }
        for decodedFrame in try decoder.decode(nil) {
            try accept(decodedFrame.pointer)
        }
        if let tail = try converter.flush(), !tail.isEmpty {
            fifo.append(tail)
            while Int64(fifo.count) >= blockSize { try encode(samples: Int(blockSize)) }
        }
        // The last block is the only short one.
        if fifo.count > 0 { try encode(samples: fifo.count) }
        try FF.check(avcodec_send_frame(encoder, nil), "avcodec_send_frame(flush)")
        try receivePackets()
        try emitter.finish(fallbackDuration: sampleTB.rescale(blockSize, to: outTB))
    }

    /// Codecs with a fixed frame size start every frame on a multiple of it from the
    /// track start. Snapping the first decoded frame there removes the rounding of
    /// millisecond (Matroska) timestamps, so a run that seeked counts samples from
    /// the same origin as one that started at the beginning.
    private func alignToFrameGrid(_ position: Int64, frameSize: Int64, origin: Int64) -> Int64 {
        guard frameSize >= 256 else { return position }
        let frames = (Double(position - origin) / Double(frameSize)).rounded()
        return origin + Int64(frames) * frameSize
    }
}

/// Rewrites the frame number of a fixed-blocksize FLAC frame (RFC 9639 §9.1).
/// The number is UTF-8-style coded, so the header can change length; both the
/// header CRC-8 and the frame CRC-16 are recomputed.
enum FLACFrameHeader {
    static func renumber(_ frame: [UInt8], frameNumber: UInt64) -> [UInt8]? {
        guard frame.count > 8, frame[0] == 0xFF, frame[1] == 0xF8 else { return nil }
        let codedLength: Int
        switch frame[4] {
        case 0x00...0x7F: codedLength = 1
        case 0xC0...0xDF: codedLength = 2
        case 0xE0...0xEF: codedLength = 3
        case 0xF0...0xF7: codedLength = 4
        case 0xF8...0xFB: codedLength = 5
        case 0xFC...0xFD: codedLength = 6
        default: return nil
        }
        var extra = 0
        switch frame[2] >> 4 {
        case 6: extra += 1
        case 7: extra += 2
        default: break
        }
        switch frame[2] & 0x0F {
        case 12: extra += 1
        case 13, 14: extra += 2
        default: break
        }
        let headerEnd = 4 + codedLength + extra   // index of the CRC-8 byte
        guard frame.count > headerEnd + 2 else { return nil }

        var header = Array(frame[0..<4]) + utf8Coded(frameNumber) + Array(frame[(4 + codedLength)..<headerEnd])
        header.append(crc8(header))
        var result = header + Array(frame[(headerEnd + 1)..<(frame.count - 2)])
        let crc = crc16(result)
        result.append(UInt8(crc >> 8))
        result.append(UInt8(crc & 0xFF))
        return result
    }

    static func utf8Coded(_ value: UInt64) -> [UInt8] {
        if value < 0x80 { return [UInt8(value)] }
        var length = 2
        while length < 7, value >= (UInt64(1) << (5 * length + 1)) { length += 1 }
        var bytes = [UInt8](repeating: 0x80, count: length)
        var v = value
        for i in stride(from: length - 1, to: 0, by: -1) {
            bytes[i] = 0x80 | UInt8(v & 0x3F)
            v >>= 6
        }
        bytes[0] = UInt8((0xFF00 >> length) & 0xFF) | UInt8(v)
        return bytes
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    private static let crc16Table: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        return crc
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        crc16Table.withUnsafeBufferPointer { table in
            bytes.withUnsafeBufferPointer { input in
                var crc: UInt16 = 0
                for byte in input {
                    crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ byte)]
                }
                return crc
            }
        }
    }
}

extension Packet {
    /// Replaces the payload with `transform(payload)` when it returns new bytes.
    func withData(_ transform: ([UInt8]) -> [UInt8]?) {
        guard let data = pointer.pointee.data, pointer.pointee.size > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(pointer.pointee.size)))
        guard let replaced = transform(bytes) else { return }
        guard let buffer = av_buffer_alloc(replaced.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else { return }
        replaced.withUnsafeBufferPointer { buffer.pointee.data.update(from: $0.baseAddress!, count: replaced.count) }
        memset(buffer.pointee.data + replaced.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        av_buffer_unref(&pointer.pointee.buf)
        pointer.pointee.buf = buffer
        pointer.pointee.data = buffer.pointee.data
        pointer.pointee.size = Int32(replaced.count)
    }
}

/// libavcodec audio decoder for one stream.
final class AudioDecoder {
    private var ctx: UnsafeMutablePointer<AVCodecContext>?

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codec = avcodec_find_decoder(stream.codecpar.pointee.codec_id), let ctx = avcodec_alloc_context3(codec) else {
            throw EnhancedPlayerError.ffmpeg(operation: "avcodec_find_decoder", code: -ENOSYS, message: "no decoder for \(codecName(stream.codecpar.pointee.codec_id))")
        }
        self.ctx = ctx
        try FF.check(avcodec_parameters_to_context(ctx, stream.codecpar), "avcodec_parameters_to_context")
        ctx.pointee.pkt_timebase = stream.pointee.time_base
        try FF.check(avcodec_open2(ctx, codec, nil), "avcodec_open2")
    }

    deinit { avcodec_free_context(&ctx) }

    /// Sends `packet` (nil flushes) and returns the frames it produced. Corrupt input
    /// right after a seek (TrueHD before its next major sync, for one) is skipped.
    func decode(_ packet: Packet?) throws -> [Frame] {
        let sent = avcodec_send_packet(ctx, packet?.pointer)
        if sent < 0, sent != FF.errorEAGAIN, sent != FF.errorEOF { return [] }
        var frames: [Frame] = []
        while true {
            let frame = Frame()
            let result = avcodec_receive_frame(ctx, frame.pointer)
            if result == FF.errorEAGAIN || result == FF.errorEOF { break }
            if result < 0 { break }
            frames.append(frame)
        }
        return frames
    }
}

/// Converts decoded frames to the encoder's packed format and layout.
final class SampleConverter {
    private let format: FLACFormat
    private var swr: OpaquePointer?
    private var inputKey: String?

    init(format: FLACFormat) {
        self.format = format
    }

    deinit { swr_free(&swr) }

    func convert(_ frame: UnsafeMutablePointer<AVFrame>) throws -> Data {
        let key = "\(frame.pointee.format)/\(frame.pointee.sample_rate)/\(frame.pointee.ch_layout.nb_channels)/\(frame.pointee.ch_layout.u.mask)"
        if key != inputKey {
            swr_free(&swr)
            var out = format.layout
            try FF.check(swr_alloc_set_opts2(&swr, &out, format.sampleFormat, format.sampleRate,
                                             &frame.pointee.ch_layout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate,
                                             0, nil), "swr_alloc_set_opts2")
            try FF.check(swr_init(swr), "swr_init")
            inputKey = key
        }
        return try run(frame)
    }

    func flush() throws -> Data? {
        guard swr != nil else { return nil }
        return try run(nil)
    }

    private func run(_ frame: UnsafeMutablePointer<AVFrame>?) throws -> Data {
        let out = Frame()
        out.pointer.pointee.format = format.sampleFormat.rawValue
        out.pointer.pointee.sample_rate = format.sampleRate
        var layout = format.layout
        av_channel_layout_copy(&out.pointer.pointee.ch_layout, &layout)
        try FF.check(swr_convert_frame(swr, out.pointer, frame), "swr_convert_frame")
        let count = Int(out.pointer.pointee.nb_samples) * format.bytesPerFrame
        guard count > 0, let data = out.pointer.pointee.data.0 else { return Data() }
        return Data(bytes: data, count: count)
    }
}

/// Packed samples with their absolute position on the output sample clock.
final class SampleFIFO {
    private let bytesPerFrame: Int
    private var buffer = Data()
    private var head = 0
    private(set) var start: Int64 = 0

    init(bytesPerFrame: Int) {
        self.bytesPerFrame = bytesPerFrame
    }

    var count: Int { (buffer.count - head) / bytesPerFrame }
    var end: Int64 { start + Int64(count) }

    func reset(start: Int64) {
        buffer.removeAll(keepingCapacity: true)
        head = 0
        self.start = start
    }

    func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    func appendSilence(_ samples: Int) {
        buffer.append(Data(count: samples * bytesPerFrame))
    }

    func prependSilence(_ samples: Int) {
        buffer.removeSubrange(0..<head)
        head = 0
        buffer.insert(contentsOf: Data(count: samples * bytesPerFrame), at: 0)
        start -= Int64(samples)
    }

    func drop(_ samples: Int) {
        let n = min(samples, count)
        head += n * bytesPerFrame
        start += Int64(n)
        compact()
    }

    func read(_ samples: Int, into destination: UnsafeMutablePointer<UInt8>) {
        let n = min(samples, count) * bytesPerFrame
        buffer.withUnsafeBytes { raw in
            destination.update(from: raw.baseAddress!.advanced(by: head).assumingMemoryBound(to: UInt8.self), count: n)
        }
        head += n
        start += Int64(n / bytesPerFrame)
        compact()
    }

    private func compact() {
        if head > 4 << 20 || head == buffer.count {
            buffer.removeSubrange(0..<head)
            head = 0
        }
    }
}
