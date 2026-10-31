import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

// Swift does not import FFmpeg's function-like macros (FFERRTAG, AVERROR, ...),
// so the handful the engine needs are spelled out here.

private func fferrtag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
    let value = UInt32(a.asciiValue!) | UInt32(b.asciiValue!) << 8 | UInt32(c.asciiValue!) << 16 | UInt32(d.asciiValue!) << 24
    return -Int32(bitPattern: value)
}

enum FF {
    static let noPTS = Int64.min
    static let errorEOF = fferrtag("E", "O", "F", " ")
    static let errorExit = fferrtag("E", "X", "I", "T")
    static let errorEAGAIN = -EAGAIN
    static let microseconds = AVRational(num: 1, den: Int32(AV_TIME_BASE))
    static let seekSize: Int32 = 0x10000   // AVSEEK_SIZE
    static let seekForce: Int32 = 0x20000  // AVSEEK_FORCE

    static func tag(_ string: String) -> UInt32 {
        let bytes = Array(string.utf8)
        precondition(bytes.count == 4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    @discardableResult
    static func check(_ code: Int32, _ what: @autoclosure () -> String) throws -> Int32 {
        if code < 0 { throw EnhancedPlayerError.ffmpeg(operation: what(), code: code, message: errorString(code)) }
        return code
    }
}

/// A plain-Swift rational so value types that cross threads don't carry C structs around.
struct Rational: Sendable, Hashable, CustomStringConvertible {
    var num: Int32
    var den: Int32

    init(num: Int32, den: Int32) {
        self.num = num
        self.den = den
    }

    init(_ r: AVRational) {
        self.num = r.num
        self.den = r.den
    }

    var av: AVRational { AVRational(num: num, den: den) }
    var doubleValue: Double { den == 0 ? 0 : Double(num) / Double(den) }
    var isValid: Bool { num > 0 && den > 0 }
    var description: String { "\(num)/\(den)" }

    static let microseconds = Rational(num: 1, den: Int32(AV_TIME_BASE))
    static let ticks = Rational(num: 1, den: 10_000_000)
}

extension Rational {
    func rescale(_ ts: Int64, to target: Rational) -> Int64 {
        av_rescale_q(ts, av, target.av)
    }

    func rescaleNearest(_ ts: Int64, to target: Rational) -> Int64 {
        av_rescale_q_rnd(ts, av, target.av, AV_ROUND_NEAR_INF)
    }

    func seconds(_ ts: Int64) -> Double {
        Double(ts) * Double(num) / Double(den)
    }
}

/// Exact `a·tbA <=> b·tbB` comparison, the same answer `av_compare_ts` gives.
func compareTimestamps(_ a: Int64, _ tbA: Rational, _ b: Int64, _ tbB: Rational) -> Int {
    Int(av_compare_ts(a, tbA.av, b, tbB.av))
}

func codecName(_ id: AVCodecID) -> String {
    String(cString: avcodec_get_name(id))
}

extension UnsafeMutablePointer where Pointee == AVStream {
    var timeBase: Rational { Rational(pointee.time_base) }
    var codecpar: UnsafeMutablePointer<AVCodecParameters> { pointee.codecpar }

    func metadata(_ key: String) -> String? {
        guard let entry = av_dict_get(pointee.metadata, key, nil, 0), let value = entry.pointee.value else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }
}

extension UnsafeMutablePointer where Pointee == AVCodecParameters {
    var extradataBytes: [UInt8] {
        guard let data = pointee.extradata, pointee.extradata_size > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(pointee.extradata_size)))
    }

    func codedSideData(_ type: AVPacketSideDataType) -> UnsafePointer<AVPacketSideData>? {
        av_packet_side_data_get(pointee.coded_side_data, pointee.nb_coded_side_data, type)
    }
}

/// Owns an `AVPacket` for the lifetime of a Swift value.
final class Packet {
    let pointer: UnsafeMutablePointer<AVPacket>

    init() {
        pointer = av_packet_alloc()
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = pointer
        av_packet_free(&p)
    }

    func clone() -> Packet {
        let copy = Packet()
        av_packet_ref(copy.pointer, pointer)
        return copy
    }

    func unref() { av_packet_unref(pointer) }

    /// Applies the rewriter to the payload. Timing and flags stay; side data goes.
    func rewrite(with rewriter: SDRBitstreamRewriter) throws {
        let payload = UnsafeBufferPointer(start: pointer.pointee.data, count: Int(pointer.pointee.size))
        guard let bytes = rewriter.rewrite(payload) else { return }
        let out = Packet()
        try FF.check(av_new_packet(out.pointer, Int32(bytes.count)), "av_new_packet")
        out.pointer.pointee.data.update(from: bytes, count: bytes.count)
        try FF.check(av_packet_copy_props(out.pointer, pointer), "av_packet_copy_props")
        av_packet_free_side_data(out.pointer)
        av_packet_unref(pointer)
        av_packet_move_ref(pointer, out.pointer)
    }

    var streamIndex: Int32 { pointer.pointee.stream_index }
    var pts: Int64 {
        get { pointer.pointee.pts }
        set { pointer.pointee.pts = newValue }
    }
    var dts: Int64 {
        get { pointer.pointee.dts }
        set { pointer.pointee.dts = newValue }
    }
    var duration: Int64 {
        get { pointer.pointee.duration }
        set { pointer.pointee.duration = newValue }
    }
    var isKeyframe: Bool { pointer.pointee.flags & AV_PKT_FLAG_KEY != 0 }
}

/// Owns an `AVFrame`.
final class Frame {
    let pointer: UnsafeMutablePointer<AVFrame>

    init() {
        pointer = av_frame_alloc()
    }

    deinit {
        var p: UnsafeMutablePointer<AVFrame>? = pointer
        av_frame_free(&p)
    }
}
