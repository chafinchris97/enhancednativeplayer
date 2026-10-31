import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

private func remoteRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer else { return FF.errorEOF }
    return Unmanaged<RemoteCursor>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, capacity: Int(size))
}

private func remoteSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<RemoteCursor>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
}

private func remoteInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<RemoteCursor>.fromOpaque(opaque).takeUnretainedValue().token.isCancelled ? 1 : 0
}

/// An `AVFormatContext` reading the remote file through a `RemoteCursor`.
/// Each producer owns its own demuxer; they share the `RemoteFile` block cache.
final class Demuxer {
    private(set) var context: UnsafeMutablePointer<AVFormatContext>?
    private var avio: UnsafeMutablePointer<AVIOContext>?
    private let cursor: Unmanaged<RemoteCursor>

    init(file: RemoteFile, token: CancellationToken, findStreamInfo: Bool = true) throws {
        cursor = Unmanaged.passRetained(RemoteCursor(file: file, token: token))
        let bufferSize: Int32 = 256 * 1024
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self),
              let io = avio_alloc_context(buffer, bufferSize, 0, cursor.toOpaque(), remoteRead, nil, remoteSeek) else {
            cursor.release()
            throw EnhancedPlayerError.ffmpeg(operation: "avio_alloc_context", code: -ENOMEM, message: "out of memory")
        }
        avio = io

        var ctx = avformat_alloc_context()
        ctx?.pointee.pb = io
        ctx?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        ctx?.pointee.interrupt_callback = AVIOInterruptCB(callback: remoteInterrupt, opaque: cursor.toOpaque())
        let name = file.url.lastPathComponent
        let opened = avformat_open_input(&ctx, name.isEmpty ? "remote" : name, nil, nil)
        guard opened >= 0, let ctx else {
            close()
            throw EnhancedPlayerError.ffmpeg(operation: "avformat_open_input", code: opened, message: FF.errorString(opened))
        }
        context = ctx
        if findStreamInfo {
            let found = avformat_find_stream_info(ctx, nil)
            if found < 0 {
                close()
                throw EnhancedPlayerError.ffmpeg(operation: "avformat_find_stream_info", code: found, message: FF.errorString(found))
            }
        }
    }

    deinit { close() }

    var formatContext: UnsafeMutablePointer<AVFormatContext> { context! }

    func stream(_ index: Int32) -> UnsafeMutablePointer<AVStream> {
        formatContext.pointee.streams[Int(index)]!
    }

    var streamCount: Int32 { Int32(formatContext.pointee.nb_streams) }

    /// Tells the demuxer to drop every stream but `keep`, which skips their payload parsing.
    func discardAll(except keep: Set<Int32>) {
        for index in 0..<streamCount {
            stream(index).pointee.discard = keep.contains(index) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Seeks `stream` to the index entry at or before `timestamp` (in that stream's time base).
    func seek(stream: Int32, timestamp: Int64) throws {
        try FF.check(av_seek_frame(formatContext, stream, timestamp, AVSEEK_FLAG_BACKWARD), "av_seek_frame")
    }

    /// Reads the next packet. Returns `false` at end of file.
    func read(into packet: Packet) throws -> Bool {
        packet.unref()
        let result = av_read_frame(formatContext, packet.pointer)
        if result == FF.errorEOF { return false }
        if result == FF.errorExit { throw EnhancedPlayerError.cancelled }
        try FF.check(result, "av_read_frame")
        return true
    }

    private func close() {
        if context != nil {
            avformat_close_input(&context)
        }
        if avio != nil {
            av_freep(&avio!.pointee.buffer)
            avio_context_free(&avio)
            cursor.release()
        }
    }
}
