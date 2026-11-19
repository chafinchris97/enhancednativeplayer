import EPLibavutil
import Foundation
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
    /// as Rec. 709 and its HDR metadata removed, for playing HDR on an SDR display; for video
    /// the player draws, the SDR placeholder under the same frames. Nil when the file is
    /// not HDR, or its codec configuration cannot be rewritten.
    let sdrMasterPlaylistURL: URL?
    /// Whether the file's video is HDR10, HLG or Dolby Vision.
    let isHDR: Bool
    /// Duration of the playlist timeline in seconds.
    let duration: TimeInterval
    /// The `NAME` of each audio rendition, in `audio_{n}` order.
    let audioTrackNames: [String]
    /// The `NAME` of each subtitle rendition, in `subtitle_{n}` order.
    let subtitleTrackNames: [String]
    /// The audio tracks as the player reports them, in `audio_{n}` order.
    let audioTracks: [MediaTrack]
    /// The subtitle tracks as the player reports them, in `subtitle_{n}` order.
    let subtitleTracks: [MediaTrack]
    /// Where the playlist timeline starts in the file's timeline, in seconds. AVPlayer's
    /// time plus this is the file's time.
    let originSeconds: TimeInterval
    /// The container's chapters, in seconds of the file's timeline.
    let fileChapters: [Chapter]

    private let core: PlaybackSessionCore
    private let server: HLSServer
    private let renderedKeyframeTicks = Mutex<[Int64]?>(nil)

    private init(masterPlaylistURL: URL, core: PlaybackSessionCore, server: HLSServer) {
        self.masterPlaylistURL = masterPlaylistURL
        self.sdrMasterPlaylistURL = !core.context.hasSDRMaster ? nil : masterPlaylistURL.deletingLastPathComponent().appendingPathComponent("master_sdr.m3u8")
        self.isHDR = core.context.media.video.isHDR
        self.core = core
        self.server = server
        self.duration = core.context.plan.segments.reduce(0) { $0 + $1.duration }
        self.audioTrackNames = core.playlists.audioNames()
        self.subtitleTrackNames = core.playlists.subtitleNames()
        let audioNames = audioTrackNames
        let subtitleNames = subtitleTrackNames
        self.audioTracks = core.context.media.audio.map { track in
            MediaTrack(index: track.index, name: audioNames[track.index], language: track.language)
        }
        self.subtitleTracks = core.context.media.subtitles.map { track in
            MediaTrack(index: track.index, name: subtitleNames[track.index], language: track.language, isForced: track.isForced, isExternal: track.isExternal)
        }
        self.originSeconds = Double(core.context.originTicks) / 10_000_000
        self.fileChapters = core.context.media.chapters
    }

    /// - Parameters:
    ///   - externalSubtitles: Fetched while the file is probed. One that fails is logged and left out.
    ///   - trickplay: Sprite sheets of thumbnails, served as the master's I-frame rendition.
    ///     Left out, logged, when its description doesn't add up.
    static func start(url: URL, configuration: EnhancedPlayerConfiguration = .init(), externalSubtitles: [ExternalSubtitle] = [], trickplay: Trickplay? = nil) async throws -> EnhancedPlaybackSession {
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
            let context = RemuxContext(file: file, media: media, plan: plan, token: token)
            let trickplayRendition = trickplay.flatMap {
                TrickplayRendition(
                    $0,
                    duration: plan.segments.reduce(0) { $0 + $1.duration },
                    originSeconds: Double(context.originTicks) / 10_000_000,
                    headers: headers,
                    logger: logger
                )
            }
            logger.info("Probed \(media.formatName) in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms: \(media.keyframes.timestamps.count) keyframes, \(plan.count) segments, \(media.audio.count) audio tracks, \(media.subtitles.count) subtitle tracks")
            core = PlaybackSessionCore(
                context: context,
                directory: directory,
                segmentsAhead: configuration.segmentsAhead,
                externalFonts: external.flatMap(\.fonts),
                trickplay: trickplayRendition,
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

    /// The regular subtitle rendition in the system's preferred language, by name, for when
    /// the audio rendition `name` has no forced track. Nil if the audio is already in that
    /// language or the file has no track in it.
    func preferredSubtitleName(forAudioNamed name: String) -> String? {
        guard let audio = audioTrackNames.firstIndex(of: name),
              let track = core.playlists.preferredSubtitleIndex(forAudio: audio, preferredLanguages: Locale.preferredLanguages)
        else { return nil }
        return subtitleTrackNames[track]
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

    /// Whether the player decodes and draws the video itself, above a placeholder rendition.
    var rendersVideo: Bool { core.context.media.video.rendered != nil }

    /// The colour `master_sdr.m3u8` relabeled away, which the player puts back on AVPlayer's
    /// frames so they are tone mapped. Nil when the SDR master isn't a relabel.
    var sdrMasterSourceColor: SourceHDRColor? {
        let video = core.context.media.video
        guard core.context.sdrRewriter != nil else { return nil }
        return SourceHDRColor(range: video.range, metadata: video.hdrMetadata)
    }

    /// Whether `iframe.m3u8` was answered 404 because no video was asked for: the display
    /// refused the HDR variant, and the item failing on the missing playlist stands for that.
    var iFramePlaylistWithheld: Bool { core.iFramePlaylistWithheld.withLock { $0 } }

    /// The rendered video's shape on screen: its size with the pixel aspect applied. Nil when
    /// AVPlayer draws the video, whose `presentationSize` says the same.
    var renderedDisplaySize: CGSize? {
        guard let source = core.context.media.video.rendered else { return nil }
        return CGSize(width: videoSize.width * source.sampleAspect.doubleValue, height: videoSize.height)
    }

    /// Where a seek the user made in the system controls lands, playlist ticks: on a nearby
    /// keyframe for AV1 the player decodes itself (see `KeyframeSnap`), nil to keep it exact.
    func keyframeLanding(target: Int64, current: Int64) -> Int64? {
        guard let source = core.context.media.video.rendered, source.codecName == "av1" else { return nil }
        let keyframes = renderedKeyframeTicks.withLock { cached in
            if cached == nil { cached = core.context.keyframeTicks }
            return cached!
        }
        return KeyframeSnap.landing(target: target, current: current, keyframes: keyframes)
    }

    /// Bytes of one decoded frame of the rendered video, as the display layer gets it.
    var videoFrameBytes: Int {
        let video = core.context.media.video
        let pixelFormat = video.range == .sdr ? video.rendered?.pixelFormat ?? -1 : AV_PIX_FMT_YUV420P10LE.rawValue
        return PixelBufferConverter.bytesPerFrame(width: video.width, height: video.height, pixelFormat: pixelFormat)
    }

    /// A decoder for the rendered video, reading the file through the session's block cache.
    /// It stops reading when the session stops or `token` is cancelled.
    func makeVideoDecoder(token: CancellationToken) throws -> RenderedVideoDecoder {
        let context = core.context
        return try RenderedVideoDecoder(file: context.file, media: context.media, originTicks: context.originTicks, token: token)
    }

    /// Holds the first video segment of a seek until the player has decoded its frame; nil
    /// unless the player draws the video.
    var videoStartGate: VideoStartGate? { core.videoGate }

    /// The session's own cancellation, for a token that should also end with the session.
    var cancellationToken: CancellationToken { core.context.token }

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
    /// Holds a run's first video segment until the player has decoded its frame; nil unless the
    /// player draws the video.
    let videoGate: VideoStartGate?
    /// Set by the first request for a video init or segment, of either master.
    private let videoRequested = Mutex(false)
    let iFramePlaylistWithheld = Mutex(false)
    private let logger: Logger

    /// How long `iframe.m3u8` waits for a video request before it is withheld.
    static let iFramePlaylistWaitSeconds: Double = 3

    init(context: RemuxContext, directory: URL, segmentsAhead: Int, externalFonts: [ASSFont] = [], trickplay: TrickplayRendition? = nil, logger: Logger) {
        self.context = context
        self.directory = directory
        self.externalFonts = externalFonts
        self.logger = logger
        self.videoGate = context.media.video.rendered == nil ? nil : VideoStartGate()
        var playlists = PlaylistBuilder(media: context.media, plan: context.plan, subtitleGrid: context.subtitleGrid)
        playlists.trickplay = trickplay
        self.playlists = playlists
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
            producer: { _ -> SegmentProducer in
                context.media.video.rendered == nil ? VideoProducer(context: context) : PlaceholderVideoProducer(context: context)
            }
        )
        sdrVideo = SegmentPipeline(
            name: "video_sdr",
            directory: directory.appendingPathComponent("video_sdr", isDirectory: true),
            segmentCount: context.plan.count,
            segmentsAhead: segmentsAhead,
            token: context.token,
            logger: logger,
            fileName: { segment, _ in "video_sdr_\(segment).mp4" },
            producer: { _ -> SegmentProducer in
                context.media.video.rendered == nil ? VideoProducer(context: context, rewriter: context.sdrRewriter) : PlaceholderVideoProducer(context: context, sdr: true)
            }
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

    func respond(to fileName: String, runtimeTicks: Int64?) async -> Response {
        guard let route = HLSRoute(fileName: fileName) else { return Response(status: .notFound) }
        let context = context
        switch route {
        case .videoInit, .videoSegment, .sdrVideoInit, .sdrVideoSegment:
            videoRequested.withLock { $0 = true }
        default:
            break
        }
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
                let logger = logger
                return .mp4(try await inits.data(for: "video") {
                    let data = try InitSegmentBuilder.video(context, token: token)
                    logger.info("init_video.mp4: \(InitSegmentBuilder.describeVideo(data))")
                    return data
                }, audio: false)
            case .audioInit(let track):
                guard context.media.audio.indices.contains(track) else { return Response(status: .notFound) }
                let token = context.token
                let audio = context.media.audio[track]
                return .mp4(try await inits.data(for: "audio-\(track)") { try InitSegmentBuilder.audio(context, track: audio, token: token) }, audio: true)
            case .videoSegment(let index):
                checkTicks(runtimeTicks, index: index, file: fileName)
                if let gate = videoGate, context.plan.segments.indices.contains(index) {
                    let segments = context.plan.segments
                    let start = segments[index].runtimeTicks
                    let end = index + 1 < segments.count ? segments[index + 1].runtimeTicks : start + Int64(segments[index].duration * 10_000_000)
                    let startsRun = gate.startsRun(index)
                    let logger = logger
                    return try await serve(index, track: 0, from: video, audio: false) {
                        await gate.hold(segment: index, range: start..<end, startsRun: startsRun, logger: logger)
                    }
                }
                return try await serve(index, track: 0, from: video, audio: false)
            case .audioSegment(let track, let index):
                guard context.media.audio.indices.contains(track) else { return Response(status: .notFound) }
                checkTicks(runtimeTicks, index: index, file: fileName)
                return try await serve(index, track: track, from: audio, audio: true)
            case .sdrMaster:
                guard context.hasSDRMaster else { return Response(status: .notFound) }
                return .playlist(playlists.master(sdr: true, start: startSelection.withLock { $0 }))
            case .sdrVideoPlaylist:
                guard context.hasSDRMaster else { return Response(status: .notFound) }
                return .playlist(playlists.sdrVideoPlaylist())
            case .sdrVideoInit:
                guard context.hasSDRMaster else { return Response(status: .notFound) }
                let token = context.token
                return .mp4(try await inits.data(for: "video-sdr") {
                    guard let rewriter = context.sdrRewriter else { return try PlaceholderVideo.initSegment(context, sdr: true) }
                    return try InitSegmentBuilder.video(context, rewriter: rewriter, token: token)
                }, audio: false)
            case .sdrVideoSegment(let index):
                guard context.hasSDRMaster else { return Response(status: .notFound) }
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
            case .iFramePlaylist:
                guard let text = playlists.iFramePlaylist() else { return Response(status: .notFound) }
                // The JPEGs are SDR, so in an HDR master on an SDR display the I-frame entry
                // is the one thing left, and AVPlayer would play the stills as the video
                // instead of refusing the master. Held until a video file is asked for, which
                // says the video variant was taken; without one the item fails on the 404.
                if context.hasSDRMaster, !(await waitForVideoRequest()) {
                    iFramePlaylistWithheld.withLock { $0 = true }
                    logger.info("iframe.m3u8 withheld: no video asked for within \(Self.iFramePlaylistWaitSeconds) s, so the video variant was refused")
                    return Response(status: .notFound)
                }
                return .playlist(text)
            case .iFrameInit:
                guard let trickplay = playlists.trickplay else { return Response(status: .notFound) }
                return .mp4(trickplay.initSegment, audio: false)
            case .iFrameSegment(let index):
                guard let trickplay = playlists.trickplay else { return Response(status: .notFound) }
                return .mp4(try await trickplay.fragment(index), audio: false)
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

    private func waitForVideoRequest() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(Self.iFramePlaylistWaitSeconds)
        while !videoRequested.withLock({ $0 }) {
            guard ContinuousClock.now < deadline, !context.token.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    /// The segment's file, sent once `hold` (if any) has returned; the two run side by side.
    private func serve(_ index: Int, track: Int, from pipeline: SegmentPipeline, audio: Bool, hold: (@Sendable () async -> Void)? = nil) async throws -> Response {
        async let file = pipeline.segment(index, track: track)
        if let hold { await hold() }
        let url = try await file
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
