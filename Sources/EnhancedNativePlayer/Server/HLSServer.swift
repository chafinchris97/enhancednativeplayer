import Foundation
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle

/// The local HTTP server AVPlayer talks to. Every playlist and segment is a route;
/// playlists are rendered when requested, segments come from the pipelines.
final class HLSServer: Sendable {
    private let session: PlaybackSessionCore
    private let logger: Logger
    private let running = Mutex<(group: ServiceGroup, task: Task<Void, Never>)?>(nil)

    init(session: PlaybackSessionCore, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    /// Starts listening on an ephemeral loopback port and returns it.
    func start() async throws -> Int {
        let router = Router()
        let session = session
        router.get(":file") { request, context -> Response in
            let file = try context.parameters.require("file")
            let ticks = request.uri.queryParameters.get("runtimeTicks").flatMap { Int64($0) }
            return try await session.respond(to: file, runtimeTicks: ticks)
        }

        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "EnhancedNativePlayer"),
            onServerRunning: { channel in
                continuation.yield(channel.localAddress?.port ?? 0)
                continuation.finish()
            },
            logger: logger
        )
        let group = ServiceGroup(configuration: .init(services: [app], logger: logger))
        let logger = logger
        let task = Task {
            do {
                try await group.run()
            } catch {
                logger.error("HLS server stopped: \(error)")
            }
            continuation.finish()
        }
        running.withLock { $0 = (group, task) }
        for await port in ports where port > 0 {
            return port
        }
        throw EnhancedPlayerError.serverFailedToStart
    }

    func stop() async {
        let current = running.withLock { value in
            defer { value = nil }
            return value
        }
        guard let current else { return }
        await current.group.triggerGracefulShutdown()
        await current.task.value
    }
}

/// Minimal lock-protected box (Synchronization.Mutex needs tvOS 18).
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

enum HLSRoute: Equatable {
    case master
    case videoPlaylist
    case audioPlaylist(track: Int)
    case videoInit
    case videoSegment(Int)
    case audioInit(track: Int)
    case audioSegment(track: Int, index: Int)
    case sdrMaster
    case sdrVideoPlaylist
    case sdrVideoInit
    case sdrVideoSegment(Int)

    /// master.m3u8, video.m3u8, audio_{t}.m3u8, init_video.mp4, video_{n}.mp4,
    /// audio_{t}_init.mp4, audio_{t}_{n}.mp4, master_sdr.m3u8, video_sdr.m3u8,
    /// init_video_sdr.mp4, video_sdr_{n}.mp4
    init?(fileName: String) {
        switch fileName {
        case "master.m3u8": self = .master
        case "video.m3u8": self = .videoPlaylist
        case "init_video.mp4": self = .videoInit
        case "master_sdr.m3u8": self = .sdrMaster
        case "video_sdr.m3u8": self = .sdrVideoPlaylist
        case "init_video_sdr.mp4": self = .sdrVideoInit
        default:
            if let stem = fileName.dropSuffix(".m3u8"), let track = stem.dropPrefix("audio_").flatMap({ Int($0) }) {
                self = .audioPlaylist(track: track)
            } else if let stem = fileName.dropSuffix(".mp4") {
                if let index = stem.dropPrefix("video_sdr_").flatMap({ Int($0) }) {
                    self = .sdrVideoSegment(index)
                } else if let index = stem.dropPrefix("video_").flatMap({ Int($0) }) {
                    self = .videoSegment(index)
                } else if let rest = stem.dropPrefix("audio_") {
                    let parts = rest.split(separator: "_")
                    guard parts.count == 2, let track = Int(parts[0]) else { return nil }
                    if parts[1] == "init" {
                        self = .audioInit(track: track)
                    } else if let index = Int(parts[1]) {
                        self = .audioSegment(track: track, index: index)
                    } else {
                        return nil
                    }
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
    }
}

private extension String {
    func dropSuffix(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }

    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

extension Response {
    static func playlist(_ text: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/vnd.apple.mpegurl", .cacheControl: "no-cache"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: text))
        )
    }

    static func mp4(_ data: Data, audio: Bool) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: audio ? "audio/mp4" : "video/mp4"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    /// Streams a segment file, then reports whether it reached the client.
    static func segment(_ url: URL, audio: Bool, completion: @escaping @Sendable (Bool) -> Void) throws -> Response {
        let handle = try FileHandle(forReadingFrom: url)
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let body = ResponseBody(contentLength: size) { writer in
            var delivered = false
            defer {
                try? handle.close()
                completion(delivered)
            }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try await writer.write(ByteBuffer(bytes: chunk))
            }
            try await writer.finish(nil)
            delivered = true
        }
        return Response(status: .ok, headers: [.contentType: audio ? "audio/mp4" : "video/mp4"], body: body)
    }
}
