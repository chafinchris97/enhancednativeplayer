import Foundation
import Hummingbird
import Logging

/// One playback of one remote file: probe, plan, local HLS server and the remux
/// pipelines behind it.
///
/// Internal: the only way to play is `EnhancedPlayer`, since PGS and ASS drawing,
/// forced-subtitle selection, display-mode matching and the SDR fallback all live there.
/// `stop()` stops the server and deletes every cached file.
final class EnhancedPlaybackSession: Sendable {
    /// `http://127.0.0.1:{port}/master.m3u8`
    let masterPlaylistURL: URL
    /// `http://127.0.0.1:{port}/master_sdr.m3u8`: the same stream with the video relabeled
    /// as Rec. 709 and its HDR metadata removed, for playing HDR on an SDR display. Nil
    /// when the file is not HDR, or its codec configuration cannot be rewritten.
    let sdrMasterPlaylistURL: URL?
    /// Whether the file's video is HDR10, HLG or Dolby Vision.
    let isHDR: Bool
    /// Duration of the playlist timeline in seconds.
    let duration: TimeInterval
    /// The `NAME` of each audio rendition, in `audio_{n}` order.
    let audioTrackNames: [String]
    /// The `NAME` of each subtitle rendition, in `subtitle_{n}` order.
    let subtitleTrackNames: [String]
    /// Where the playlist timeline starts in the file's timeline, in seconds. AVPlayer's
    /// time plus this is the file's time.
    let originSeconds: TimeInterval
    /// The container's chapters, in seconds of the file's timeline.
    let fileChapters: [Chapter]

    private let core: PlaybackSessionCore
    private let server: HLSServer

    private init(masterPlaylistURL: URL, core: PlaybackSessionCore, server: HLSServer) {
        self.masterPlaylistURL = masterPlaylistURL
        self.sdrMasterPlaylistURL = core.context.sdrRewriter == nil ? nil : masterPlaylistURL.deletingLastPathComponent().appendingPathComponent("master_sdr.m3u8")
        self.isHDR = core.context.media.video.isHDR
        self.core = core
        self.server = server
        self.duration = core.context.plan.segments.reduce(0) { $0 + $1.duration }
        self.audioTrackNames = core.playlists.audioNames()
        self.subtitleTrackNames = core.playlists.subtitleNames()
        self.originSeconds = Double(core.context.originTicks) / 10_000_000
        self.fileChapters = core.context.media.chapters
    }

    /// - Parameter externalSubtitles: Fetched while the file is probed. One that fails is logged and left out.
    static func start(url: URL, configuration: EnhancedPlayerConfiguration = .init(), externalSubtitles: [ExternalSubtitle] = []) async throws -> EnhancedPlaybackSession {
        let logger = Logger.player
        let started = Date()

        let base = configuration.cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EnhancedNativePlayer", isDirectory: true)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let headers = configuration.httpHeaders
        let externalTask = Task { await loadExternalSubtitles(externalSubtitles, headers: headers, logger: logger) }
        defer { externalTask.cancel() }

        let token = CancellationToken()
        let file: RemoteFile
        do {
            file = try await RemoteFile.open(
                url: url,
                headers: configuration.httpHeaders,
                directory: directory.appendingPathComponent("source", isDirectory: true),
                diskBudget: configuration.sourceCacheBytes,
                logger: logger
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let core: PlaybackSessionCore
        do {
            var media = try await runBlocking(label: "ENP.probe") { try MediaProbe.probe(file: file, token: token) }
            let external = await externalTask.value
            media.subtitles = externalTracks(external) + media.subtitles.map { track in
                var track = track
                track.index += external.count
                return track
            }
            let plan = SegmentPlan(
                keyframes: media.keyframes.timestamps,
                timeBase: media.keyframes.timeBase,
                hlsTime: configuration.segmentDuration,
                end: media.videoEndTimestamp
            )
            logger.info("Probed \(media.formatName) in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms: \(media.keyframes.timestamps.count) keyframes, \(plan.count) segments, \(media.audio.count) audio tracks, \(media.subtitles.count) subtitle tracks")
            core = PlaybackSessionCore(
                context: RemuxContext(file: file, media: media, plan: plan, token: token),
                directory: directory,
                segmentsAhead: configuration.segmentsAhead,
                externalFonts: external.flatMap(\.fonts),
                logger: logger
            )
        } catch {
            file.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let server = HLSServer(session: core, logger: logger)
        do {
            let port = try await server.start()
            let master = URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
            logger.info("Serving \(master.absoluteString)")
            return EnhancedPlaybackSession(masterPlaylistURL: master, core: core, server: server)
        } catch {
            await server.stop()
            core.shutdown()
            throw error
        }
    }

    /// Fetches every external subtitle at once. One that fails is logged and left out.
    private static func loadExternalSubtitles(_ subtitles: [ExternalSubtitle], headers: [String: String], logger: Logger) async -> [LoadedExternalSubtitle] {
        await withTaskGroup(of: (Int, LoadedExternalSubtitle?).self) { group in
            for (index, subtitle) in subtitles.enumerated() {
                group.addTask {
                    do {
                        return (index, try await ExternalSubtitleLoader.load(subtitle, headers: headers))
                    } catch {
                        logger.warning("External subtitle \(subtitle.url.lastPathComponent) left out: \(error.localizedDescription)")
                        return (index, nil)
                    }
                }
            }
            var loaded: [(Int, LoadedExternalSubtitle)] = []
            for await case let (index, subtitle?) in group { loaded.append((index, subtitle)) }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func externalTracks(_ loaded: [LoadedExternalSubtitle]) -> [SubtitleTrack] {
        loaded.enumerated().map { index, external in
            // "pt-BR" → "pt": the menu labels by language.
            let language = external.subtitle.language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            var header: [UInt8] = []
            var codec = "subrip"
            if case .ass(let scriptHeader, _) = external.content {
                header = scriptHeader
                codec = "ass"
            }
            return SubtitleTrack(
                index: index,
                streamIndex: -1,
                codecName: codec,
                timeBase: .ticks,
                language: language,
                title: nil,
                isDefault: false,
                isForced: external.subtitle.isForced,
                textFormat: nil,
                extradata: header,
                external: external.content
            )
        }
    }

    /// Which tracks the master marks DEFAULT from now on. Set before the player reads it.
    func setStartSelection(_ selection: StartSelection) {
        core.startSelection.withLock { $0 = selection }
    }

    /// The audio track playback starts with for `selection`.
    func defaultAudioIndex(_ selection: StartSelection) -> Int? {
        core.playlists.defaultAudioIndex(selection)
    }

    /// The subtitle track playback starts with for `selection`, nil for none.
    func defaultSubtitleIndex(_ selection: StartSelection) -> Int? {
        core.playlists.defaultSubtitleIndex(selection)
    }

    /// The PGS track behind a subtitle rendition's name, nil for any other kind of track.
    func pgsTrack(named name: String) -> Int? {
        guard let track = subtitleTrackNames.firstIndex(of: name), core.context.media.subtitles[track].isPGS else { return nil }
        return track
    }

    /// The forced subtitle rendition for the language of an audio rendition, by name.
    func forcedSubtitleName(forAudioNamed name: String) -> String? {
        let media = core.context.media
        guard let audio = audioTrackNames.firstIndex(of: name),
              let language = media.audio[audio].language.flatMap(Languages.tag),
              let track = media.subtitles.first(where: { $0.isForced && $0.language.flatMap(Languages.tag) == language })
        else { return nil }
        return subtitleTrackNames[track.index]
    }

    func isForcedSubtitle(named name: String) -> Bool {
        guard let track = subtitleTrackNames.firstIndex(of: name) else { return false }
        return core.context.media.subtitles[track].isForced
    }

    var hasForcedSubtitles: Bool { core.context.media.subtitles.contains(where: \.isForced) }

    var hasPGSTracks: Bool { core.context.media.subtitles.contains(where: \.isPGS) }

    var hasASSTracks: Bool { core.context.media.subtitles.contains(where: \.isASS) }

    /// The ASS track behind a subtitle rendition's name, nil for any other kind of track.
    func assTrack(named name: String) -> Int? {
        guard let track = subtitleTrackNames.firstIndex(of: name), core.context.media.subtitles[track].isASS else { return nil }
        return track
    }

    /// The script header of an ASS track: script info and styles.
    func assHeader(track: Int) -> [UInt8] {
        core.context.media.subtitles[track].extradata
    }

    func assSegment(track: Int, segment: Int) async throws -> ASSSegment {
        let context = core.context
        guard segment < context.subtitleGrid.count else { return ASSSegment(events: [], frameTicks: []) }
        let subtitle = context.media.subtitles[track]
        if case .ass(_, let events)? = subtitle.external {
            // Every event that shows in the segment, wherever it starts: the whole script is
            // in memory, so nothing needs looking back for. ReadOrder drops repeats in libass.
            let start = context.subtitleGrid.startTicks(of: segment) + context.originTicks
            let end = context.subtitleGrid.endTicks(of: segment) + context.originTicks
            let shown = events.filter { $0.startTicks < end && $0.endTicks > start }.compactMap { event -> ASSEvent? in
                let startMilliseconds = ASSTime.milliseconds(ticks: event.startTicks - context.originTicks)
                let endMilliseconds = ASSTime.milliseconds(ticks: event.endTicks - context.originTicks)
                guard endMilliseconds > startMilliseconds else { return nil }
                return ASSEvent(startMilliseconds: startMilliseconds, durationMilliseconds: endMilliseconds - startMilliseconds, data: event.data)
            }
            return ASSSegment(events: shown, frameTicks: [])
        }
        return try await core.assEvents.segment(track: subtitle, segment: segment)
    }

    /// Start and end of a subtitle segment in playlist ticks.
    func subtitleSegmentRange(_ segment: Int) -> Range<Int64> {
        let grid = core.context.subtitleGrid
        return grid.startTicks(of: segment)..<grid.endTicks(of: segment)
    }

    /// The file's attached fonts and those of external ASS tracks.
    func assFonts() async throws -> [ASSFont] {
        try await core.assEvents.fonts() + core.externalFonts
    }

    /// The video's coded size in pixels.
    var videoSize: CGSize {
        CGSize(width: core.context.media.video.width, height: core.context.media.video.height)
    }

    /// The length of one video frame in 100 ns ticks, nil unless the video has a standard
    /// constant rate. The demuxer's average rate is often a little off (23.98 for 24000/1001),
    /// and frame starts are counted from 0, so only the exact rate keeps a 2 h film on its frames.
    var videoFrameTicks: Double? {
        ASSTime.frameTicks(forRate: core.context.media.video.frameRate)
    }

    /// The matrix the video's YCbCr is in, for ASS colour mangling. Nil for HDR.
    var videoColorMatrix: ColorMangling.Matrix? {
        let video = core.context.media.video
        guard !video.isHDR else { return nil }
        return video.height > 576 ? .bt709 : .bt601
    }

    /// The subtitle segment holding a position in the playlist timeline.
    func subtitleSegment(atTicks ticks: Int64) -> Int {
        min(max(0, Int(ticks / SubtitleGrid.segmentTicks)), core.context.subtitleGrid.count - 1)
    }

    func pgsFrames(track: Int, segment: Int) async throws -> [PGSFrame] {
        guard segment < core.context.subtitleGrid.count else { return [] }
        return try await core.pgsFrames.frames(track: core.context.media.subtitles[track], segment: segment)
    }

    /// What returning to the foreground does: a fresh listener on the same port.
    func rebindServer() async {
        await server.rebind()
    }

    /// Stops the server and the remux, and deletes every segment and cached block.
    func stop() async {
        await server.stop()
        core.shutdown()
    }
}

/// Routes requests to playlists, inits and the two pipelines.
final class PlaybackSessionCore: Sendable {
    let context: RemuxContext
    let playlists: PlaylistBuilder
    private let directory: URL
    private let video: SegmentPipeline
    /// Idle unless the player was given `master_sdr.m3u8`.
    private let sdrVideo: SegmentPipeline
    private let audio: SegmentPipeline
    private let inits = InitSegmentStore()
    private let subtitleCues = SubtitleSegmentCache<[SubtitleCue]>()
    let pgsFrames: PGSFrameStore
    let assEvents: ASSEventStore
    let externalFonts: [ASSFont]
    /// Which tracks the master marks DEFAULT.
    let startSelection = Mutex(StartSelection())
    private let logger: Logger

    init(context: RemuxContext, directory: URL, segmentsAhead: Int, externalFonts: [ASSFont] = [], logger: Logger) {
        self.context = context
        self.directory = directory
        self.externalFonts = externalFonts
        self.logger = logger
        self.playlists = PlaylistBuilder(media: context.media, plan: context.plan, subtitleGrid: context.subtitleGrid)
        pgsFrames = PGSFrameStore(context: context)
        assEvents = ASSEventStore(context: context)
        video = SegmentPipeline(
            name: "video",
            directory: directory.appendingPathComponent("video", isDirectory: true),
            segmentCount: context.plan.count,
            segmentsAhead: segmentsAhead,
            token: context.token,
            logger: logger,
            fileName: { segment, _ in "video_\(segment).mp4" },
            producer: { _ in VideoProducer(context: context) }
        )
        sdrVideo = SegmentPipeline(
            name: "video_sdr",
            directory: directory.appendingPathComponent("video_sdr", isDirectory: true),
            segmentCount: context.plan.count,
            segmentsAhead: segmentsAhead,
            token: context.token,
            logger: logger,
            fileName: { segment, _ in "video_sdr_\(segment).mp4" },
            producer: { _ in VideoProducer(context: context, rewriter: context.sdrRewriter) }
        )
        audio = SegmentPipeline(
            name: "audio",
            directory: directory.appendingPathComponent("audio", isDirectory: true),
            segmentCount: context.plan.count,
            segmentsAhead: segmentsAhead,
            token: context.token,
            logger: logger,
            fileName: { segment, track in "audio_\(track)_\(segment).mp4" },
            producer: { track in
                let audio = context.media.audio[track]
                switch audio.delivery {
                case .copy: return AudioCopyProducer(context: context, track: audio)
                case .flac: return FLACTranscodeProducer(context: context, track: audio)
                }
            }
        )
    }

    func respond(to fileName: String, runtimeTicks: Int64?) async throws -> Response {
        guard let route = HLSRoute(fileName: fileName) else { return Response(status: .notFound) }
        let context = context
        do {
            switch route {
            case .master:
                return .playlist(playlists.master(start: startSelection.withLock { $0 }))
            case .videoPlaylist:
                return .playlist(playlists.videoPlaylist())
            case .audioPlaylist(let track):
                guard context.media.audio.indices.contains(track) else { return Response(status: .notFound) }
                return .playlist(playlists.audioPlaylist(track: track))
            case .videoInit:
                let token = context.token
                return .mp4(try await inits.data(for: "video") { try InitSegmentBuilder.video(context, token: token) }, audio: false)
            case .audioInit(let track):
                guard context.media.audio.indices.contains(track) else { return Response(status: .notFound) }
                let token = context.token
                let audio = context.media.audio[track]
                return .mp4(try await inits.data(for: "audio-\(track)") { try InitSegmentBuilder.audio(context, track: audio, token: token) }, audio: true)
            case .videoSegment(let index):
                checkTicks(runtimeTicks, index: index, file: fileName)
                return try await serve(index, track: 0, from: video, audio: false)
            case .audioSegment(let track, let index):
                guard context.media.audio.indices.contains(track) else { return Response(status: .notFound) }
                checkTicks(runtimeTicks, index: index, file: fileName)
                return try await serve(index, track: track, from: audio, audio: true)
            case .sdrMaster:
                guard context.sdrRewriter != nil else { return Response(status: .notFound) }
                return .playlist(playlists.master(sdr: true, start: startSelection.withLock { $0 }))
            case .sdrVideoPlaylist:
                guard context.sdrRewriter != nil else { return Response(status: .notFound) }
                return .playlist(playlists.sdrVideoPlaylist())
            case .sdrVideoInit:
                guard let rewriter = context.sdrRewriter else { return Response(status: .notFound) }
                let token = context.token
                return .mp4(try await inits.data(for: "video-sdr") { try InitSegmentBuilder.video(context, rewriter: rewriter, token: token) }, audio: false)
            case .sdrVideoSegment(let index):
                guard context.sdrRewriter != nil else { return Response(status: .notFound) }
                checkTicks(runtimeTicks, index: index, file: fileName)
                return try await serve(index, track: 0, from: sdrVideo, audio: false)
            case .subtitlePlaylist(let track):
                guard context.media.subtitles.indices.contains(track) else { return Response(status: .notFound) }
                return .playlist(playlists.subtitlePlaylist(track: track))
            case .subtitleSegment(let track, let index):
                guard context.media.subtitles.indices.contains(track), (0..<context.subtitleGrid.count).contains(index) else { return Response(status: .notFound) }
                let subtitle = context.media.subtitles[track]
                if let external = subtitle.external {
                    guard index == 0 else { return Response(status: .notFound) }
                    guard case .text(let cues) = external else { return .webVTT(WebVTT.document([])) }
                    let origin = context.originTicks
                    let shifted = cues.compactMap { cue -> SubtitleCue? in
                        var cue = cue
                        cue.startTicks = max(0, cue.startTicks - origin)
                        cue.endTicks -= origin
                        return cue.endTicks > cue.startTicks ? cue : nil
                    }
                    return .webVTT(WebVTT.document(shifted))
                }
                guard let format = subtitle.textFormat else { return .webVTT(WebVTT.document([])) }
                let cues = try await subtitleCues.value(track: track, segment: index) {
                    try SubtitleCueReader.read(context: context, track: subtitle, format: format, segment: index)
                }
                return .webVTT(WebVTT.document(cues))
            }
        } catch EnhancedPlayerError.segmentOutOfRange {
            return Response(status: .notFound)
        } catch {
            if !(error is CancellationError) {
                logger.error("\(fileName): \(error.localizedDescription)")
            }
            return Response(status: .internalServerError)
        }
    }

    private func serve(_ index: Int, track: Int, from pipeline: SegmentPipeline, audio: Bool) async throws -> Response {
        let url = try await pipeline.segment(index, track: track)
        return try Response.segment(url, audio: audio) { delivered in
            pipeline.didFinishSending(url, segment: index, delivered: delivered)
        }
    }

    /// `runtimeTicks` is the segment's start in the playlist timeline. A restart seeks
    /// to exactly that keyframe through the plan, which is where the ticks came from,
    /// so the two can only disagree for a stale or hand-written URL.
    private func checkTicks(_ ticks: Int64?, index: Int, file: String) {
        guard let ticks, context.plan.segments.indices.contains(index) else { return }
        let expected = context.plan.segments[index].runtimeTicks
        if ticks != expected {
            logger.warning("\(file): runtimeTicks \(ticks) does not match the plan (\(expected)); using the segment index")
        }
    }

    func shutdown() {
        context.token.cancel()
        video.stop()
        sdrVideo.stop()
        audio.stop()
        context.file.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
