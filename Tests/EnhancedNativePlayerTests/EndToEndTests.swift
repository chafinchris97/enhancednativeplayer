@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import EnhancedNativePlayer

/// Opt-in tests against a real file served over HTTP with range support.
///
///     ENP_E2E_URL=http://127.0.0.1:18931/movie.mkv \
///     ENP_E2E_TRUTH=/path/to/ffmpeg/video.m3u8 \   # optional: ffmpeg -f hls -hls_time 6 output
///     ENP_E2E_OUT=/tmp/enp-out \                    # optional: dump playlists and segments
///     swift test --filter EndToEnd
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENP_E2E_URL"] != nil))
struct EndToEndTests {
    let source = URL(string: ProcessInfo.processInfo.environment["ENP_E2E_URL"] ?? "http://invalid")!
    let truth = ProcessInfo.processInfo.environment["ENP_E2E_TRUTH"]
    let out = ProcessInfo.processInfo.environment["ENP_E2E_OUT"].map { URL(fileURLWithPath: $0) }

    @Test func playlistsMatchFFmpegAndRestartsAreByteIdentical() async throws {
        let started = Date()
        let session = try await EnhancedPlaybackSession.start(url: source)
        let startup = Date().timeIntervalSince(started)
        print("session ready in \(Int(startup * 1000)) ms → \(session.masterPlaylistURL)")
        do { try await checkPlaylistsAndRestarts(session, started: started) } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    private func checkPlaylistsAndRestarts(_ session: EnhancedPlaybackSession, started: Date) async throws {
        let base = session.masterPlaylistURL.deletingLastPathComponent()

        let master = try await text(base, "master.m3u8")
        let video = try await text(base, "video.m3u8")
        print(master)
        try save("master.m3u8", Data(master.utf8))
        try save("video.m3u8", Data(video.utf8))

        let extinf = video.split(separator: "\n").filter { $0.hasPrefix("#EXTINF") }
        if let truth {
            let expected = try String(contentsOfFile: truth, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("#EXTINF") }
            #expect(extinf.count == expected.count, "segment count")
            // ffmpeg's last EXTINF sums packet durations; ours ends at the stream end.
            #expect(Array(extinf.dropLast()) == Array(expected.dropLast()), "EXTINF durations differ from ffmpeg")
        }
        let segmentCount = extinf.count
        let audioCount = session.audioTrackNames.count

        // Continuous pass: every segment, in order, as a player would fetch them.
        var videoSegments: [Data] = []
        let videoInit = try await data(base, "init_video.mp4")
        try save("init_video.mp4", videoInit)
        for i in 0..<segmentCount {
            let segment = try await data(base, "video_\(i).mp4")
            videoSegments.append(segment)
            try save("video_\(i).mp4", segment)
        }
        var audioSegments: [[Data]] = []
        print("video pass done at \(Date().timeIntervalSince(started))")
        for track in 0..<audioCount {
            print("audio track \(track) starts at \(Date().timeIntervalSince(started))")
            let playlist = try await text(base, "audio_\(track).m3u8")
            try save("audio_\(track).m3u8", Data(playlist.utf8))
            #expect(playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF") } == extinf, "audio EXTINF must equal video EXTINF")
            try save("audio_\(track)_init.mp4", try await data(base, "audio_\(track)_init.mp4"))
            var list: [Data] = []
            for i in 0..<segmentCount {
                let segment = try await data(base, "audio_\(track)_\(i).mp4")
                list.append(segment)
                try save("audio_\(track)_\(i).mp4", segment)
            }
            audioSegments.append(list)
        }

        // Restarted passes: segments already sent are gone, so these seek and remux again.
        for i in [segmentCount / 2, 1, segmentCount - 1] where i > 0 {
            let again = try await data(base, "video_\(i).mp4")
            try save("video_\(i).restart.mp4", again)
            #expect(again == videoSegments[i], "video_\(i) differs between a continuous and a restarted run")
            for track in 0..<audioCount {
                let audioAgain = try await data(base, "audio_\(track)_\(i).mp4")
                try save("audio_\(track)_\(i).restart.mp4", audioAgain)
                // Same timing always. Same bytes too, except PCM decoded from a lossy codec:
                // its decoder state (Opus energy prediction, ...) never converges bit-exactly
                // after a seek, so the FLAC payload may differ in the last bits.
                let lossySource = ["OPUS", "MP3", "VORBIS", "DTS)"].contains { session.audioTrackNames[track].contains("FLAC (\($0)") }
                var timing = Self.timing(audioAgain), expected = Self.timing(audioSegments[track][i])
                if lossySource, i == segmentCount - 1 {
                    // The track's final short block may differ by a few samples: codec delays
                    // like Opus's 6.5 ms do not survive Matroska's millisecond timestamps.
                    timing.removeLast()
                    expected.removeLast()
                }
                #expect(timing == expected, "audio_\(track)_\(i) timing differs between runs")
                if !lossySource {
                    #expect(audioAgain == audioSegments[track][i], "audio_\(track)_\(i) differs between a continuous and a restarted run")
                }
            }
        }
    }

    /// A seek must read the file around its target, not everything before it. Every
    /// block a session fetches lands in the cache, so the cache shows what was read.
    @Test func seekReadsOnlyAroundItsTarget() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("enp-seek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        var configuration = EnhancedPlayerConfiguration()
        configuration.cacheDirectory = cache
        configuration.sourceCacheBytes = 64 << 40
        let session = try await EnhancedPlaybackSession.start(url: source, configuration: configuration)
        let base = session.masterPlaylistURL.deletingLastPathComponent()
        let extinf = try await text(base, "video.m3u8").split(separator: "\n").filter { $0.hasPrefix("#EXTINF") }
        let middle = extinf.count / 2

        func blocks() throws -> [Int] {
            try FileManager.default.subpathsOfDirectory(atPath: cache.path)
                .filter { $0.hasSuffix(".block") }
                .compactMap { Int((($0 as NSString).lastPathComponent as NSString).deletingPathExtension) }
        }
        let beforeSeek = Set(try blocks())

        var names = ["video_\(middle).mp4"]
        names += session.audioTrackNames.indices.map { "audio_\($0)_\(middle).mp4" }
        for name in names {
            let started = Date()
            _ = try await data(base, name)
            print("\(name) ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }

        let read = Set(try blocks()).subtracting(beforeSeek)
        let highest = read.max() ?? 0
        let skippedOver = read.filter { $0 < highest / 2 }
        print("seek read \(read.count) blocks; \(skippedOver.count) from the first half of the range read")
        #expect(skippedOver.count < 16, "seeking to segment \(middle) read \(skippedOver.count) blocks far before it")
        await session.stop()
    }

    @MainActor
    @Test func avPlayerPlaysAndSeeks() async throws {
        let session = try await EnhancedPlaybackSession.start(url: source)
        try await play(session)
        await session.stop()
    }

    @MainActor
    private func play(_ session: EnhancedPlaybackSession) async throws {
        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()

        try await waitUntil(timeout: 20) { player.currentTime().seconds > 3 || item.status == .failed }
        guard item.status == .readyToPlay else {
            Issue.record("item failed: \(String(describing: item.error)) \((item.error as NSError?)?.userInfo ?? [:])")
            for event in item.errorLog()?.events ?? [] {
                print("errorLog:", event.errorStatusCode, event.errorDomain, event.errorComment ?? "", event.uri ?? "")
            }
            return
        }
        print("played to", player.currentTime().seconds)

        let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        print("audible options:", group?.options.map(\.displayName) ?? [])

        let target = session.duration * 0.6
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await waitUntil(timeout: 20) { player.currentTime().seconds > target + 2 }
        print("after seek to", target, "playing at", player.currentTime().seconds)

        if let group, group.options.count > 1 {
            item.select(group.options[1], in: group)
            let position = player.currentTime().seconds
            try await waitUntil(timeout: 20) { player.currentTime().seconds > position + 3 }
            print("after switching to", group.options[1].displayName, "playing at", player.currentTime().seconds)
        }
        #expect(item.error == nil, "\(String(describing: item.error))")
        print("access log:", item.accessLog()?.events.map { "\($0.indicatedBitrate) stalls=\($0.numberOfStalls)" } ?? [])
        player.pause()
    }

    /// A subtitle segment far into the file comes back with only its own stretch read,
    /// even for a sparse track with no cue anywhere near it.
    @Test func subtitleSegmentReadsOnlyItsStretch() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("enp-subtitle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        var configuration = EnhancedPlayerConfiguration()
        configuration.cacheDirectory = cache
        configuration.sourceCacheBytes = 64 << 40
        let session = try await EnhancedPlaybackSession.start(url: source, configuration: configuration)
        let base = session.masterPlaylistURL.deletingLastPathComponent()
        var range = URLRequest(url: source)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: range)
        let contentRange = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
        let fileBlocks = Int(contentRange.split(separator: "/").last!)! >> 20

        func blocks() throws -> Set<String> {
            Set(try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".block") })
        }
        var before = try blocks()
        let segment = Int(session.duration / 10) / 4
        for track in session.subtitleTrackNames.indices {
            let started = Date()
            _ = try await data(base, "subtitle_\(track)_\(segment).vtt")
            let read = try blocks().subtracting(before)
            before.formUnion(read)
            print("subtitle_\(track)_\(segment).vtt ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(read.count) of \(fileBlocks) blocks")
            #expect(read.count <= max(12, fileBlocks / 4), "subtitle_\(track)_\(segment) read \(read.count) of \(fileBlocks) blocks")
        }
        await session.stop()
    }

    /// Files with text subtitles: a segment read straight after opening (no earlier
    /// segments) has the cues a full pass finds, and AVPlayer shows a cue on time after a seek.
    @MainActor
    @Test func subtitleSegmentsAreRandomAccessAndReachAVPlayer() async throws {
        let session = try await EnhancedPlaybackSession.start(url: source)
        let base = session.masterPlaylistURL.deletingLastPathComponent()
        let master = try await text(base, "master.m3u8")
        try save("master.m3u8", Data(master.utf8))
        #expect(master.components(separatedBy: "TYPE=SUBTITLES").count - 1 == session.subtitleTrackNames.count)

        var target: (track: Int, seconds: Double, text: String)?
        for track in session.subtitleTrackNames.indices {
            let playlist = try await text(base, "subtitle_\(track).m3u8")
            let names = playlist.split(separator: "\n").filter { $0.hasSuffix(".vtt") }
            for name in names {
                let started = Date()
                let vtt = try await text(base, String(name))
                try save(String(name), Data(vtt.utf8))
                #expect(vtt.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n"))
                let index = Int(name.split(separator: "_")[2].dropLast(4))!
                let lines = vtt.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains(" --> ") {
                    let cueStart = Self.seconds(line.components(separatedBy: " --> ")[0])
                    #expect(cueStart >= Double(index * 10) && cueStart < Double(index * 10 + 10), "\(name): cue at \(cueStart)")
                    if target == nil, index >= names.count / 2 {
                        target = (track, cueStart, lines[i + 1])
                        print("\(name) ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    }
                }
            }
        }
        guard let target else {
            await session.stop()
            return
        }

        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let output = AVPlayerItemLegibleOutput()
        let collector = CueCollector()
        output.setDelegate(collector, queue: .main)
        output.suppressesPlayerRendering = true
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        try await waitUntil(timeout: 20) { item.status != .unknown }
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
        #expect(group.options.map(\.displayName) == session.subtitleTrackNames)
        item.select(group.options[target.track], in: group)
        let lead = max(0, target.seconds - 2)
        await player.seek(to: CMTime(seconds: lead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let wanted = target.text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        try await waitUntil(timeout: 20) { collector.shown.contains { $0.text.contains(wanted) } }
        let shown = collector.shown.first { $0.text.contains(wanted) }
        print("cue \"\(wanted)\" at \(target.seconds) shown at", shown?.time ?? -1)
        #expect(abs((shown?.time ?? -100) - target.seconds) < 0.5, "cue is off its time")
        player.pause()
        await session.stop()
    }

    /// Files with PGS subtitles: frames read straight after a seek are what a full pass
    /// shows at that time, and choosing the rendition in AVPlayer says which track to draw.
    @MainActor
    @Test func pgsFramesAreRandomAccessAndSelectionIsSeen() async throws {
        let session = try await EnhancedPlaybackSession.start(url: source)
        guard let track = session.subtitleTrackNames.firstIndex(where: { session.pgsTrack(named: $0) != nil }) else {
            await session.stop()
            return
        }
        let last = session.subtitleSegment(atTicks: Int64(session.duration * 10_000_000))
        var full: [PGSFrame] = []
        for segment in 0...last {
            let frames = try await session.pgsFrames(track: track, segment: segment)
            full += frames.filter { frame in full.last.map { frame.startTicks > $0.startTicks } ?? true }
        }
        let drawn = full.filter { !$0.bitmaps.isEmpty }
        print("PGS track \(track): \(full.count) frames, \(drawn.count) with bitmaps")
        #expect(!drawn.isEmpty)
        if let out, let frame = drawn.first, let image = frame.bitmaps.first?.makeImage() {
            let url = out.appendingPathComponent("pgs_first.png") as CFURL
            let destination = try #require(CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }

        // A fresh session has read nothing, so each lookup stands alone.
        let fresh = try await EnhancedPlaybackSession.start(url: source)
        for wanted in stride(from: drawn.count / 2, to: drawn.count, by: max(1, drawn.count / 8)) {
            let frame = drawn[wanted]
            let ticks = frame.startTicks + 1
            let frames = try await fresh.pgsFrames(track: track, segment: fresh.subtitleSegment(atTicks: ticks))
            #expect(frames.last { $0.startTicks <= ticks } == frame, "frame at \(frame.startTicks)")
        }
        await fresh.stop()

        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        try await waitUntil(timeout: 20) { item.status != .unknown }
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
        var notified = false
        let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { notified = true }
        }
        item.select(group.options[track], in: group)
        try await waitUntil(timeout: 5) { notified }
        NotificationCenter.default.removeObserver(observer)
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        #expect(selected?.renditionName.flatMap { session.pgsTrack(named: $0) } == track)
        player.pause()
        await session.stop()
    }

    /// HDR sources only: `master_sdr.m3u8` announces SDR, its segments restart byte for
    /// byte, and AVPlayer plays it with no HDR transfer function on the track.
    @MainActor
    @Test func sdrMasterIsPlayableAndRestartsAreByteIdentical() async throws {
        let session = try await EnhancedPlaybackSession.start(url: source)
        guard let master = session.sdrMasterPlaylistURL else {
            #expect(!session.isHDR)
            await session.stop()
            return
        }
        let base = master.deletingLastPathComponent()
        let playlist = try await text(base, "master_sdr.m3u8")
        #expect(playlist.contains("VIDEO-RANGE=SDR"))
        #expect(!playlist.contains("VIDEO-RANGE=PQ") && !playlist.contains("VIDEO-RANGE=HLG") && !playlist.contains("dvh1"))
        #expect(playlist.contains("video_sdr.m3u8"))
        try save("master_sdr.m3u8", Data(playlist.utf8))
        try save("init_video_sdr.mp4", try await data(base, "init_video_sdr.mp4"))

        let first = try await data(base, "video_sdr_0.mp4")
        let second = try await data(base, "video_sdr_1.mp4")
        try save("video_sdr_0.mp4", first)
        try save("video_sdr_1.mp4", second)
        #expect(try await data(base, "video_sdr_1.mp4") == second, "video_sdr_1 differs after a restart")
        #expect(try await data(base, "video_sdr_0.mp4") == first, "video_sdr_0 differs after a restart")

        let item = AVPlayerItem(url: master)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        try await waitUntil(timeout: 20) { player.currentTime().seconds > 3 || item.status == .failed }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        print("SDR master played to", player.currentTime().seconds, "duration", session.duration)
        player.pause()
        await session.stop()
    }

    #if os(tvOS)
    /// The simulator has no HDR display, so it refuses an HDR master the way an SDR TV does.
    @MainActor
    @Test func hdrMasterRefusalIsRecognised() async throws {
        let session = try await EnhancedPlaybackSession.start(url: source)
        defer { Task { await session.stop() } }
        guard session.sdrMasterPlaylistURL != nil else { return }
        let item = AVPlayerItem(url: session.masterPlaylistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        try await waitUntil(timeout: 20) { item.status != .unknown }
        print("HDR master status:", item.status.rawValue, String(describing: item.error))
        #expect(item.status == .failed && DisplayRefusal.matches(item.error!))
    }

    @MainActor
    @Test func assetReportsDisplayCriteria() async throws {
        let session = try await EnhancedPlaybackSession.start(url: source)
        let criteria = try await AVURLAsset(url: session.masterPlaylistURL).load(.preferredDisplayCriteria)
        print("display criteria:", criteria)
        await session.stop()
    }
    #endif

    // MARK: - Helpers

    static func seconds(_ timestamp: String) -> Double {
        timestamp.split(separator: ":").reduce(0) { $0 * 60 + Double($1)! }
    }

    /// tfdt and the trun sample durations of a one-fragment segment.
    static func timing(_ data: Data) -> [UInt64] {
        let bytes = [UInt8](data)
        func u32(_ i: Int) -> UInt64 { UInt64(bytes[i]) << 24 | UInt64(bytes[i + 1]) << 16 | UInt64(bytes[i + 2]) << 8 | UInt64(bytes[i + 3]) }
        func find(_ tag: String) -> Int? {
            let t = Array(tag.utf8)
            return bytes.indices.dropLast(4).first { bytes[$0] == t[0] && bytes[$0 + 1] == t[1] && bytes[$0 + 2] == t[2] && bytes[$0 + 3] == t[3] }.map { $0 - 4 }
        }
        guard let tfdt = find("tfdt"), let trun = find("trun") else { return [] }
        var result = [bytes[tfdt + 8] == 1 ? u32(tfdt + 12) << 32 | u32(tfdt + 16) : u32(tfdt + 12)]
        let flags = Int(u32(trun + 8) & 0xFFFFFF)
        let count = Int(u32(trun + 12))
        var offset = trun + 16 + (flags & 1 != 0 ? 4 : 0) + (flags & 4 != 0 ? 4 : 0)
        for _ in 0..<count {
            if flags & 0x100 != 0 { result.append(u32(offset)); offset += 4 }
            for bit in [0x200, 0x400, 0x800] where flags & bit != 0 { offset += 4 }
        }
        return result
    }

    private func data(_ base: URL, _ name: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(name))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw EnhancedPlayerError.http(status: status, url: base.appendingPathComponent(name)) }
        return data
    }

    private func text(_ base: URL, _ name: String) async throws -> String {
        String(decoding: try await data(base, name), as: UTF8.self)
    }

    private func save(_ name: String, _ data: Data) throws {
        guard let out else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try data.write(to: out.appendingPathComponent(name))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("timed out after \(timeout) s")
    }
}

/// What AVPlayer renders for the selected subtitle rendition.
final class CueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    var shown: [(text: String, time: Double)] = []

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        shown += strings.map { ($0.string, itemTime.seconds) }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENP_E2E_URL"] != nil))
struct CleanupTests {
    @Test func rebindKeepsThePlaylistURL() async throws {
        let session = try await EnhancedPlaybackSession.start(url: URL(string: ProcessInfo.processInfo.environment["ENP_E2E_URL"]!)!)
        let before = try await URLSession.shared.data(from: session.masterPlaylistURL).0
        await session.rebindServer()
        await session.rebindServer()
        let after = try await URLSession.shared.data(from: session.masterPlaylistURL).0
        #expect(after == before)
        let segment = try await URLSession.shared.data(from: session.masterPlaylistURL.deletingLastPathComponent().appendingPathComponent("video_0.mp4"))
        #expect((segment.1 as? HTTPURLResponse)?.statusCode == 200)
        await session.stop()
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: session.masterPlaylistURL) }
    }

    @Test func stopDeletesEverything() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("enp-cleanup-\(UUID().uuidString)")
        var configuration = EnhancedPlayerConfiguration()
        configuration.cacheDirectory = cache
        let session = try await EnhancedPlaybackSession.start(url: URL(string: ProcessInfo.processInfo.environment["ENP_E2E_URL"]!)!, configuration: configuration)
        let base = session.masterPlaylistURL.deletingLastPathComponent()
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("video_3.mp4"))
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("audio_0_3.mp4"))
        try await Task.sleep(for: .seconds(1))
        let during = try FileManager.default.subpathsOfDirectory(atPath: cache.path)
        let videoFiles = Set(during.filter { $0.hasSuffix(".mp4") && $0.contains("video_") }.map { ($0 as NSString).lastPathComponent })
        let audioFiles = Set(during.filter { $0.hasSuffix(".mp4") && $0.contains("audio_") }.map { ($0 as NSString).lastPathComponent })
        // video_3 was sent and deleted; the run filled 4, 5, 6 and paused before 7.
        #expect(videoFiles == ["video_4.mp4", "video_5.mp4", "video_6.mp4"])
        #expect(audioFiles == ["audio_0_4.mp4", "audio_0_5.mp4", "audio_0_6.mp4"])
        #expect(during.contains { $0.hasSuffix(".block") }, "source blocks are cached while playing")
        await session.stop()
        try await Task.sleep(for: .milliseconds(500))
        let after = (try? FileManager.default.subpathsOfDirectory(atPath: cache.path)) ?? []
        #expect(after.isEmpty, "left behind: \(after)")
        // The server is gone too.
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: base.appendingPathComponent("master.m3u8")) }
        try? FileManager.default.removeItem(at: cache)
    }
}
