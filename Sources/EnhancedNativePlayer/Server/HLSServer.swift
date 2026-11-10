import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOTransportServices
import ServiceLifecycle
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The local HTTP server AVPlayer talks to. Every playlist and segment is a route;
/// playlists are rendered when requested, segments come from the pipelines.
///
/// The system reclaims the listening socket of an app that stays suspended for a while,
/// after which AVPlayer's requests to this port go unanswered and playback spins forever.
/// So the listener is bound again on the same port whenever the app returns to the
/// foreground, and whenever it closes without `stop()`.
final class HLSServer: Sendable {
    private struct Instance {
        let id: Int
        let group: ServiceGroup
        let task: Task<Void, Never>
    }

    private struct State {
        var port = 0
        var current: Instance?
        var launches = 0
        var rebinding = false
        var stopped = false
        var foregroundObserver: (any NSObjectProtocol)?
    }

    private let session: PlaybackSessionCore
    private let logger: Logger
    private let state = Mutex(State())

    init(session: PlaybackSessionCore, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    /// Starts listening on an ephemeral loopback port and returns it.
    func start() async throws -> Int {
        let port = try await launch(port: 0)
        #if canImport(UIKit) && !os(watchOS)
        await MainActor.run {
            let observer = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.rebind() }
            }
            let keep = state.withLock { state in
                guard !state.stopped else { return false }
                state.foregroundObserver = observer
                return true
            }
            if !keep { NotificationCenter.default.removeObserver(observer) }
        }
        #endif
        return port
    }

    func stop() async {
        let (current, observer) = state.withLock { state in
            state.stopped = true
            defer {
                state.current = nil
                state.foregroundObserver = nil
            }
            return (state.current, state.foregroundObserver)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let current else { return }
        await current.group.triggerGracefulShutdown()
        await current.task.value
    }

    /// Replaces the listener with a fresh one on the same port. With `replacing`, only
    /// if that instance is still the current one.
    func rebind(replacing id: Int? = nil) async {
        let claimed = state.withLock { state -> (old: Instance?, port: Int)? in
            guard !state.stopped, !state.rebinding, state.port > 0 else { return nil }
            if let id, state.current?.id != id { return nil }
            state.rebinding = true
            defer { state.current = nil }
            return (state.current, state.port)
        }
        guard let claimed else { return }
        defer { state.withLock { $0.rebinding = false } }
        if let old = claimed.old { await old.group.triggerGracefulShutdown() }
        // The old listener may hold the port for a moment after its shutdown is triggered.
        for attempt in 1...20 {
            do {
                _ = try await launch(port: claimed.port)
                logger.info("HLS server listening again on port \(claimed.port)")
                return
            } catch EnhancedPlayerError.cancelled {
                return
            } catch {
                if attempt == 20 { logger.error("HLS server could not listen again on port \(claimed.port): \(error)") }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Runs one listener on `port` (0 for an ephemeral one) and returns the port it bound.
    private func launch(port: Int) async throws -> Int {
        guard let id = state.withLock({ state -> Int? in
            guard !state.stopped else { return nil }
            state.launches += 1
            return state.launches
        }) else { throw EnhancedPlayerError.cancelled }

        let router = Router()
        let session = session
        let requestLogger = logger
        router.get(":file") { request, context -> Response in
            let file = try context.parameters.require("file")
            let ticks = request.uri.queryParameters.get("runtimeTicks").flatMap { Int64($0) }
            // One line when a request arrives and one when it is answered, so a stall shows
            // which file the player is waiting on.
            requestLogger.info("GET \(file)")
            let started = ContinuousClock.now
            let response = try await session.respond(to: file, runtimeTicks: ticks)
            requestLogger.info("GET \(file) → \(response.status.code) in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))")
            return response
        }

        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "EnhancedNativePlayer"),
            onServerRunning: { channel in
                continuation.yield(channel.localAddress?.port ?? 0)
                continuation.finish()
            },
            // Hummingbird's .singleton only picks Network.framework on iOS, not tvOS.
            eventLoopGroupProvider: .shared(NIOTSEventLoopGroup.singleton),
            logger: logger
        )
        let group = ServiceGroup(configuration: .init(services: [app], logger: logger))
        let logger = logger
        let task = Task { [weak self] in
            do {
                try await group.run()
            } catch {
                logger.error("HLS server stopped: \(error)")
            }
            continuation.finish()
            // A listener that closes on its own was taken away; bring it back.
            await self?.rebind(replacing: id)
        }
        let installed = state.withLock { state in
            guard !state.stopped else { return false }
            state.current = Instance(id: id, group: group, task: task)
            return true
        }
        guard installed else {
            await group.triggerGracefulShutdown()
            throw EnhancedPlayerError.cancelled
        }
        for await bound in ports where bound > 0 {
            state.withLock { $0.port = bound }
            return bound
        }
        throw EnhancedPlayerError.serverFailedToStart
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
    case subtitlePlaylist(track: Int)
    case subtitleSegment(track: Int, index: Int)
    case iFramePlaylist
    case iFrameInit
    case iFrameSegment(Int)

    /// master.m3u8, video.m3u8, audio_{t}.m3u8, init_video.mp4, video_{n}.mp4,
    /// audio_{t}_init.mp4, audio_{t}_{n}.mp4, master_sdr.m3u8, video_sdr.m3u8,
    /// init_video_sdr.mp4, video_sdr_{n}.mp4, subtitle_{t}.m3u8, subtitle_{t}_{n}.vtt,
    /// iframe.m3u8, init_iframe.mp4, iframe_{n}.mp4
    init?(fileName: String) {
        switch fileName {
        case "master.m3u8": self = .master
        case "video.m3u8": self = .videoPlaylist
        case "init_video.mp4": self = .videoInit
        case "master_sdr.m3u8": self = .sdrMaster
        case "video_sdr.m3u8": self = .sdrVideoPlaylist
        case "init_video_sdr.mp4": self = .sdrVideoInit
        case "iframe.m3u8": self = .iFramePlaylist
        case "init_iframe.mp4": self = .iFrameInit
        default:
            if let stem = fileName.dropSuffix(".m3u8"), let track = stem.dropPrefix("audio_").flatMap({ Int($0) }) {
                self = .audioPlaylist(track: track)
            } else if let stem = fileName.dropSuffix(".m3u8"), let track = stem.dropPrefix("subtitle_").flatMap({ Int($0) }) {
                self = .subtitlePlaylist(track: track)
            } else if let rest = fileName.dropSuffix(".vtt")?.dropPrefix("subtitle_") {
                let parts = rest.split(separator: "_")
                guard parts.count == 2, let track = Int(parts[0]), let index = Int(parts[1]) else { return nil }
                self = .subtitleSegment(track: track, index: index)
            } else if let stem = fileName.dropSuffix(".mp4") {
                if let index = stem.dropPrefix("iframe_").flatMap({ Int($0) }) {
                    self = .iFrameSegment(index)
                } else if let index = stem.dropPrefix("video_sdr_").flatMap({ Int($0) }) {
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

    static func webVTT(_ text: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "text/vtt"],
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
