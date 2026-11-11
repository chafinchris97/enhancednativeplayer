import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Builds `init_video.mp4` and `audio_{n}_init.mp4` (ftyp + moov) on demand.
///
/// AVPlayer asks for the init before any media segment, and before it is known
/// where playback starts, so inits come from a short dedicated mux instead of a
/// remux run: the stream's first packet is muxed and the moov taken. Writing a
/// real packet matters for E-AC-3, whose `dec3` box (Atmos JOC included) is
/// built from the first access unit. Media segments carry no sample
/// descriptions, so they combine with this init whichever run produced them.
enum InitSegmentBuilder {
    static func video(_ context: RemuxContext, rewriter: SDRBitstreamRewriter? = nil, token: CancellationToken) throws -> Data {
        if context.media.video.rendered != nil { return try PlaceholderVideo.initSegment(context) }
        let video = rewriter == nil ? context.media.video : context.media.video.sdrVariant
        let demuxer = try Demuxer(file: context.file, token: token)
        demuxer.discardAll(except: [video.streamIndex])
        let input = demuxer.stream(video.streamIndex)
        let writer = try FragmentedMP4Writer { try VideoProducer.configure($0, from: input, video: video, rewriter: rewriter) }
        return try muxFirstPacket(of: video.streamIndex, demuxer: demuxer, writer: writer)
    }

    /// The sample entry and Dolby Vision record of a video init, for the log: the
    /// first of `hvc1` / `dvh1` / `avc1`, then the dvcC / dvvC fields if there is one.
    static func describeVideo(_ data: Data) -> String {
        let bytes = [UInt8](data)
        func find(_ type: String) -> Int? {
            let pattern = Array(type.utf8)
            guard bytes.count >= pattern.count else { return nil }
            return (0...(bytes.count - pattern.count)).first { bytes[$0..<$0 + pattern.count].elementsEqual(pattern) }
        }
        let entry = ["hvc1", "hev1", "dvh1", "dvhe", "avc1"].first { find($0) != nil } ?? "no sample entry"
        guard let at = find("dvvC") ?? find("dvcC") else { return "\(entry), no dvcC/dvvC" }
        let box = String(decoding: bytes[at..<at + 4], as: UTF8.self)
        let p = at + 4
        guard p + 5 <= bytes.count else { return "\(entry), \(box) truncated" }
        let profile = Int(bytes[p + 2] >> 1)
        let level = Int((bytes[p + 2] & 1) << 5 | bytes[p + 3] >> 3)
        let rpu = (bytes[p + 3] >> 2) & 1, el = (bytes[p + 3] >> 1) & 1, bl = bytes[p + 3] & 1
        let compatibility = Int(bytes[p + 4] >> 4)
        return "\(entry), \(box) version \(bytes[p]).\(bytes[p + 1]) profile \(profile) level \(level) rpu \(rpu) el \(el) bl \(bl) compatibility \(compatibility)"
    }

    static func audio(_ context: RemuxContext, track: AudioTrack, token: CancellationToken) throws -> Data {
        let demuxer = try Demuxer(file: context.file, token: token)
        demuxer.discardAll(except: [track.streamIndex])
        let input = demuxer.stream(track.streamIndex)
        switch track.delivery {
        case .copy:
            let writer = try FragmentedMP4Writer { try AudioCopyProducer.configure($0, from: input) }
            return try muxFirstPacket(of: track.streamIndex, demuxer: demuxer, writer: writer)
        case .flac:
            let format = try FLACFormat(track: track, stream: input)
            var encoder: UnsafeMutablePointer<AVCodecContext>? = try format.makeEncoder()
            defer { avcodec_free_context(&encoder) }
            let writer = try FragmentedMP4Writer { try FLACFormat.configure($0, from: encoder!) }
            return try writer.flush()
        }
    }

    private static func muxFirstPacket(of streamIndex: Int32, demuxer: Demuxer, writer: FragmentedMP4Writer) throws -> Data {
        let packet = Packet()
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == streamIndex else { continue }
            packet.pts = 0
            packet.dts = 0
            packet.duration = 1
            try writer.write(packet)
            return try writer.flush()
        }
        return try writer.flush()
    }
}

/// Init segments are a few kilobytes and requested again on every track switch,
/// so they stay in memory for the session.
actor InitSegmentStore {
    private var cache: [String: Data] = [:]
    private var building: [String: Task<Data, Error>] = [:]

    func data(for key: String, build: @escaping @Sendable () throws -> Data) async throws -> Data {
        if let data = cache[key] { return data }
        if let task = building[key] { return try await task.value }
        let task = Task { try await runBlocking(label: "ENP.init.\(key)", build) }
        building[key] = task
        do {
            let data = try await task.value
            cache[key] = data
            building[key] = nil
            return data
        } catch {
            building[key] = nil
            throw error
        }
    }
}
