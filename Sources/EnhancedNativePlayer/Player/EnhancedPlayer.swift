#if canImport(UIKit) && !os(watchOS)
@preconcurrency import AVFoundation
import AVKit
import Logging
import MediaAccessibility
import Observation
import UIKit

/// Plays a remote MKV or MP4 through AVPlayer, remuxed to HLS on the fly. Show it with
/// `EnhancedPlayerView`, the way `AVPlayer` is shown with `VideoPlayer`.
///
/// ```swift
/// struct MovieView: View {
///     @State private var player = EnhancedPlayer()
///     let media: EnhancedMedia
///
///     var body: some View {
///         EnhancedPlayerView(player)
///             .ignoresSafeArea()
///             .task(id: media) {
///                 try? await player.load(media, startTime: .seconds(754))
///                 player.play()
///             }
///     }
/// }
/// ```
///
/// Loading says what to play; the view showing it is what opens it. From synchronous code,
/// such as a button's action, `load` returns at once; in async code it is the form below,
/// which waits for the file to open. When the view appears,
/// the player probes the file, starts the local server and, on tvOS, matches the display
/// mode; `play()` takes effect once that is done. When the view goes away the server stops,
/// the cache is deleted and the display mode and audio session are reset. The player keeps
/// the media and its position, so showing it again resumes. Loading other media while the
/// view is up ends the session and starts one for the new media.
///
/// To choose tracks before playback starts, await the load, which returns once the file is
/// open and the track lists are known, and set them before calling `play()`:
///
/// ```swift
/// .task(id: media) {
///     try? await player.load(media)
///     player.selectedSubtitleTrack = player.subtitleTracks.first { $0.language == "eng" }
///     player.play()
/// }
/// ```
///
/// Times are in the file's own timeline.
@MainActor
@Observable
public final class EnhancedPlayer {
    public enum Status: Equatable, Sendable {
        /// Nothing loaded, not shown, or stopped.
        case idle
        /// Opening the file, matching the display, or buffering.
        case loading
        case playing
        case paused
        /// Played to the end.
        case ended
        /// See `error`.
        case failed
    }

    /// The AVPlayer underneath, for observing. Replacing its item breaks playback.
    public let avPlayer = AVPlayer()
    public private(set) var status: Status = .idle
    /// Why playback failed, once `status` is `.failed`.
    public private(set) var error: (any Error)?
    /// What was loaded last.
    public private(set) var currentMedia: EnhancedMedia?
    public private(set) var currentTime: Duration = .zero
    /// Known once the file is open.
    public private(set) var duration: Duration?
    /// The chapters showing: the media's own if it has them, else the file's. Known once the file is open.
    public private(set) var chapters: [Chapter] = []
    /// Known once the file is open; empty until then.
    public private(set) var audioTracks: [MediaTrack] = []
    /// External subtitles first, then the file's own. Known once the file is open; empty until then.
    public private(set) var subtitleTracks: [MediaTrack] = []

    /// The audio track playing. Set it to one of `audioTracks` to switch; before playback
    /// starts, that is the track it starts with.
    public var selectedAudioTrack: MediaTrack? {
        get { audioSelection }
        set { selectAudio(newValue) }
    }

    /// The subtitle track showing, nil when subtitles are off. Set it to one of
    /// `subtitleTracks`, or to nil to turn subtitles off; a forced track for the audio's
    /// language still shows. Before playback starts, that is what it starts with.
    public var selectedSubtitleTrack: MediaTrack? {
        get { subtitleSelection }
        set { selectSubtitle(newValue) }
    }

    private var audioSelection: MediaTrack?
    private var subtitleSelection: MediaTrack?

    private let configuration: EnhancedPlayerConfiguration
    /// The configuration's logger, with the current session's ID once one starts.
    @ObservationIgnored private var logger: Logger
    /// App, thermal and audio session events, observed while a session runs.
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    /// For `deinit`, which can't reach the main actor's state.
    private let sessionForCleanup = Mutex<EnhancedPlaybackSession?>(nil)

    @ObservationIgnored private weak var host: PlayerHostViewController?
    @ObservationIgnored private var session: EnhancedPlaybackSession?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var item: AVPlayerItem?
    /// Counts loads, so an awaited load answers for its own media only.
    @ObservationIgnored private var loadGeneration = 0
    /// Awaited loads, answered when their file opens or fails to.
    @ObservationIgnored private var openWaiters: [UUID: (generation: Int, continuation: CheckedContinuation<Void, any Error>)] = [:]
    /// Set once the current item's starting tracks and position are in place.
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var wantsToPlay = false
    /// Where playback starts, in seconds of the file's timeline.
    @ObservationIgnored private var startPosition: TimeInterval?
    @ObservationIgnored private var startSelection = StartSelection()
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var waitingObservation: NSKeyValueObservation?
    @ObservationIgnored private var pgsRenderer: PGSSubtitleRenderer?
    @ObservationIgnored private var assRenderer: ASSSubtitleRenderer?
    @ObservationIgnored private var videoRenderer: RenderedVideoRenderer?
    @ObservationIgnored private var toneMapper: ToneMappedVideoRenderer?
    /// Whether the current item plays `master_sdr.m3u8`.
    @ObservationIgnored private var playsSDRMaster = false
    @ObservationIgnored private var forcedSubtitles: ForcedSubtitleSelector?
    @ObservationIgnored private var audioSessionActive = false
    #if os(tvOS)
    /// Kept because the view has no window any more by the time it goes away.
    @ObservationIgnored private var displayManager: AVDisplayManager?
    /// Whether the display switched mode for this session, so leaving switches it back.
    @ObservationIgnored private var didSwitchDisplay = false
    #endif

    // What the view shows around the playback.
    @ObservationIgnored private var artworkCache: [Artwork: Data] = [:]
    @ObservationIgnored private var failedArtwork: Set<Artwork> = []
    @ObservationIgnored private var artworkLoads: [Artwork: Task<Void, Never>] = [:]
    @ObservationIgnored private var appliedMetadata: MetadataState?
    @ObservationIgnored private var appliedChapters: ChapterState?
    /// Pictures made from the video for chapters with none of their own, by chapter start.
    /// Kept for the loaded media, across its sessions.
    @ObservationIgnored private var chapterPictures: [Duration: Data] = [:]
    /// Chapter starts a picture has been made for or is being made for, whether or not one came of it.
    @ObservationIgnored private var chapterPicturesAsked: Set<Duration> = []
    @ObservationIgnored private var chapterPictureRun: (id: UUID, token: CancellationToken)?

    /// - Parameter configuration: Engine tuning, the same for everything this player loads.
    public init(configuration: EnhancedPlayerConfiguration = EnhancedPlayerConfiguration()) {
        self.configuration = configuration
        self.logger = configuration.logger ?? .systemDefault
        // AVPlayer's automatic selection criteria stay on: with them off, AVKit's subtitles switch
        // stays off once the user turns subtitles off in its menu, whatever is selected after.

        // Playback that never stopped (the app was killed) left its files behind; delete them
        // now rather than at the next playback. Once per cache directory per process.
        let base = SessionCache.base(for: configuration)
        if Self.sweptCacheDirectories.withLock({ $0.insert(base.standardizedFileURL.path).inserted }) {
            let logger = self.logger.category(.player)
            Task.detached(priority: .utility) { SessionCache.removeStale(in: base, logger: logger) }
        }
    }

    private static let sweptCacheDirectories = Mutex<Set<String>>([])

    /// Deletes the cached segments and source blocks of every playback that is not running,
    /// in the configuration's `cacheDirectory` (the Caches directory by default). A running
    /// playback, in any player or process, keeps its files.
    ///
    /// The engine already does this when a player is made and when playback starts; call it
    /// to free the space at another time, such as from a "clear cache" setting.
    public nonisolated static func removeCachedFiles(configuration: EnhancedPlayerConfiguration = EnhancedPlayerConfiguration()) async {
        let base = SessionCache.base(for: configuration)
        let logger = (configuration.logger ?? .systemDefault).category(.player)
        await Task.detached(priority: .utility) { SessionCache.removeStale(in: base, logger: logger) }.value
    }

    deinit {
        // The view normally ends the session; this is the backstop.
        if let session = sessionForCleanup.withLock({ $0 }) {
            Task { await session.stop() }
        }
    }

    private func log(_ category: LogCategory) -> Logger {
        logger.category(category)
    }

    // MARK: Loading

    /// Plays `media` from now on, starting at `startTime` (the beginning when nil). Ends the
    /// session of what was loaded before. The file opens once the view is showing; playback
    /// waits for `play()`.
    public func load(_ media: EnhancedMedia, startTime: Duration? = nil) {
        replaceMedia(with: media, startTime: startTime)
    }

    /// Plays `url` from now on, with nothing else about it set.
    public func load(_ url: URL, startTime: Duration? = nil) {
        replaceMedia(with: EnhancedMedia(url: url), startTime: startTime)
    }

    private func replaceMedia(with media: EnhancedMedia, startTime: Duration?) {
        teardown()
        loadGeneration += 1
        failWaiters(CancellationError()) { $0 != self.loadGeneration }
        currentMedia = media
        startPosition = startTime.map { max(0, $0.timeInterval) }
        startSelection = StartSelection()
        wantsToPlay = false
        status = .idle
        error = nil
        currentTime = startTime ?? .zero
        duration = nil
        chapters = []
        chapterPictures = [:]
        chapterPicturesAsked = []
        audioTracks = []
        subtitleTracks = []
        audioSelection = nil
        subtitleSelection = nil
        if host != nil { start() }
    }

    /// Loads `media` and returns once the file is open: the duration, chapters and track lists
    /// are known, and playback has not started unless `play()` was called. Tracks selected now
    /// are what playback starts with. Async code, such as `.task`, always calls this form.
    ///
    /// The file opens once the view is showing, so this waits for that too. Throws the error
    /// opening failed with, or `CancellationError` when other media is loaded first or the
    /// calling task is cancelled. Cancelling only stops the wait; the media stays loaded.
    public func load(_ media: EnhancedMedia, startTime: Duration? = nil) async throws {
        replaceMedia(with: media, startTime: startTime)
        let generation = loadGeneration
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    openWaiters[id] = (generation, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.openWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Loads `url`, with nothing else about it set, and returns once the file is open.
    public func load(_ url: URL, startTime: Duration? = nil) async throws {
        try await load(EnhancedMedia(url: url), startTime: startTime)
    }

    private func answerWaiters() {
        let waiters = openWaiters.filter { $0.value.generation == loadGeneration }
        for (id, waiter) in waiters {
            openWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func failWaiters(_ error: any Error, where matches: (Int) -> Bool) {
        let waiters = openWaiters.filter { matches($0.value.generation) }
        for (id, waiter) in waiters {
            openWaiters[id] = nil
            waiter.continuation.resume(throwing: error)
        }
    }

    // MARK: Playback

    /// Starts or resumes playback. Before the file is open, playback starts as soon as it can.
    public func play() {
        log(.player).info("play()")
        wantsToPlay = true
        if isReady { avPlayer.play() }
    }

    public func pause() {
        log(.player).info("pause() at \(String(format: "%.1f", currentTime.timeInterval)) s")
        wantsToPlay = false
        if isReady { avPlayer.pause() }
        if status == .loading, !isReady { return }
        if status != .ended, status != .failed, status != .idle { status = .paused }
    }

    /// Jumps to `time` in the file's timeline. Before playback starts, sets where it starts.
    public func seek(to time: Duration) {
        log(.player).info("seek(to: \(String(format: "%.3f", time.timeInterval)) s) from \(String(format: "%.1f", currentTime.timeInterval)) s")
        currentTime = time
        let seconds = time.timeInterval
        guard isReady, let session else {
            startPosition = max(0, seconds)
            return
        }
        let target = CMTime(seconds: max(0, seconds - session.originSeconds), preferredTimescale: 600)
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if status == .ended { status = .paused }
    }

    /// Ends playback now: the server stops, the cache is deleted and the display mode is reset.
    /// Showing the view again starts a new session from the same position.
    public func stop() {
        log(.player).info("stop()")
        teardown()
    }

    /// Where a seek the user made in the system controls goes. For AV1 the player decodes itself,
    /// a nearby keyframe (see `KeyframeSnap`), so the picture shows at once instead of after
    /// seconds of decoding; a jump to a chapter's start stays exact. Otherwise where it was aimed.
    func seekTarget(afterUserNavigatedFrom old: CMTime, to target: CMTime) -> CMTime {
        guard let session, target.isNumeric, old.isNumeric else { return target }
        if chapters.contains(where: { abs(max(0, $0.start.timeInterval - session.originSeconds) - target.seconds) < 0.05 }) { return target }
        func ticks(_ time: CMTime) -> Int64 { CMTimeConvertScale(time, timescale: 10_000_000, method: .roundHalfAwayFromZero).value }
        guard let landing = session.keyframeLanding(target: ticks(target), current: ticks(old)) else { return target }
        log(.player).info("Seek to \(String(format: "%.3f", target.seconds)) s lands on the keyframe at \(String(format: "%.3f", Double(landing) / 1e7)) s")
        return CMTime(value: landing, timescale: 10_000_000)
    }

    // MARK: Tracks

    private func selectAudio(_ track: MediaTrack?) {
        guard let track else {
            log(.player).warning("Audio can't be turned off; keeping the current track")
            return
        }
        guard audioTracks.contains(track) else {
            log(.player).warning("Audio track \(track.index) (\(track.name)) is not one of the loaded media's tracks")
            return
        }
        audioSelection = track
        guard isReady, let item, let session else {
            startSelection.audio = track.index
            session?.setStartSelection(startSelection)
            return
        }
        let name = session.audioTrackNames[track.index]
        Task { await self.select(named: name, characteristic: .audible, in: item) }
    }

    private func selectSubtitle(_ track: MediaTrack?) {
        if let track, !subtitleTracks.contains(track) {
            log(.player).warning("Subtitle track \(track.index) (\(track.name)) is not one of the loaded media's tracks")
            return
        }
        subtitleSelection = track
        guard isReady, let item, let session else {
            startSelection.subtitle = track.map { .track($0.index) } ?? .off
            session?.setStartSelection(startSelection)
            return
        }
        let name = track.map { session.subtitleTrackNames[$0.index] }
        Task { await self.selectSubtitle(named: name, in: item) }
    }

    /// Sets the system caption display type the way the switch in AVKit's subtitles menu does
    /// (always on for a track, forced only for off), then selects the rendition. The switch
    /// follows the display type, so it then shows the selection. Like the switch, this changes
    /// the user's setting for every app.
    private func selectSubtitle(named name: String?, in item: AVPlayerItem) async {
        MACaptionAppearanceSetDisplayType(.user, name == nil ? .forcedOnly : .alwaysOn)
        await select(named: name, characteristic: .legible, in: item)
    }

    private func select(named name: String?, characteristic: AVMediaCharacteristic, in item: AVPlayerItem) async {
        // The groups only exist once the master playlist has been read.
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic), self.item === item else { return }
        let option = name.flatMap { name in group.options.first { $0.renditionName == name } }
        if name != nil, option == nil {
            log(.player).warning("No rendition named \(name!)")
            return
        }
        item.select(option, in: group)
    }

    // MARK: Presentation

    private struct MetadataState: Equatable {
        var metadata: PlayerMetadata?
        var hasArtwork: Bool
    }

    private struct ChapterState: Equatable {
        var chapters: [Chapter]
        var loadedArtwork: Set<Artwork>
        var madePictures: Set<Duration>
    }

    private func applyPresentation(to item: AVPlayerItem) {
        applyMetadata(to: item)
        applyChapters(to: item)
    }

    private func applyMetadata(to item: AVPlayerItem) {
        let metadata = currentMedia?.metadata
        let artwork = metadata?.artwork
        if let artwork { loadArtwork(artwork) }
        let data = artwork.flatMap(artworkData)
        let state = MetadataState(metadata: metadata, hasArtwork: data != nil)
        guard state != appliedMetadata else { return }
        appliedMetadata = state
        item.externalMetadata = metadata.map { MetadataItems.info($0, artwork: data) } ?? []
    }

    private func applyChapters(to item: AVPlayerItem) {
        #if os(tvOS)
        guard let session else { return }
        let artworks = Set(chapters.compactMap(\.artwork))
        artworks.forEach(loadArtwork)
        makeChapterPictures(session: session)
        // Titles go up at once; images together once they have all arrived, not one by one.
        // While pictures are being made from the video, the list waits for them, so it never
        // shows without them.
        if chapterPictureRun != nil { return }
        let pending = artworks.contains(where: { artworkLoads[$0] != nil })
        if appliedChapters?.chapters == chapters, pending { return }
        let shown = chapters.map { chapter in
            var chapter = chapter
            if needsPicture(chapter), let picture = chapterPictures[chapter.start] { chapter.artwork = .data(picture) }
            return chapter
        }
        let state = ChapterState(
            chapters: chapters,
            loadedArtwork: artworks.filter { artworkData($0) != nil },
            madePictures: Set(chapters.filter { needsPicture($0) && chapterPictures[$0.start] != nil }.map(\.start))
        )
        guard state != appliedChapters else { return }
        appliedChapters = state
        let markers = MetadataItems.chapterMarkers(
            shown,
            origin: session.originSeconds,
            movieEnd: session.originSeconds + session.duration,
            artwork: { self.artworkData($0) }
        )
        item.navigationMarkerGroups = markers.isEmpty ? [] : [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
        #endif
    }

    /// Whether a chapter shows a picture made from the video: it has no image, or its image
    /// didn't load.
    private func needsPicture(_ chapter: Chapter) -> Bool {
        switch chapter.artwork {
        case nil: true
        case .data(let data): data.isEmpty
        case .url: failedArtwork.contains(chapter.artwork!)
        }
    }

    /// Makes pictures from the video for the chapters that need one and have none yet, from
    /// the moment the file is open. One run at a time; a chapter whose image fails to load
    /// later gets its picture in the next run.
    private func makeChapterPictures(session: EnhancedPlaybackSession) {
        guard chapterPictureRun == nil else { return }
        let movieEnd = Duration.seconds(session.originSeconds + session.duration)
        let wanted = chapters.resolvingEnds(movieEnd: movieEnd)
            .filter { !chapterPicturesAsked.contains($0.chapter.start) && needsPicture($0.chapter) }
            .map { $0.chapter.start..<$0.end }
        guard !wanted.isEmpty else { return }
        chapterPicturesAsked.formUnion(wanted.map(\.lowerBound))
        let run = (id: UUID(), token: CancellationToken(parent: session.cancellationToken))
        chapterPictureRun = run
        let generation = loadGeneration
        Task { [weak self] in
            let pictures = await session.chapterPictures(for: wanted, token: run.token)
            guard let self, self.loadGeneration == generation else { return }
            self.chapterPictures.merge(pictures) { _, new in new }
            // Stopped part way: the rest are asked for again in the next session.
            if run.token.isCancelled { self.chapterPicturesAsked.subtract(wanted.map(\.lowerBound).filter { pictures[$0] == nil }) }
            guard self.chapterPictureRun?.id == run.id else { return }
            self.chapterPictureRun = nil
            if let item = self.item { self.applyPresentation(to: item) }
        }
    }

    private func artworkData(_ artwork: Artwork) -> Data? {
        switch artwork {
        case .data(let data): data
        case .url: artworkCache[artwork]
        }
    }

    /// Downloads an image once for the player's lifetime, then applies whatever is waiting on it.
    private func loadArtwork(_ artwork: Artwork) {
        guard case .url(let url) = artwork, artworkCache[artwork] == nil, artworkLoads[artwork] == nil, !failedArtwork.contains(artwork) else { return }
        let headers = configuration.httpHeaders.merging(currentMedia?.headers ?? [:]) { _, media in media }
        artworkLoads[artwork] = Task { [weak self] in
            var request = URLRequest(url: url, timeoutInterval: 15)
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            let result: Data?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
                result = ok && !data.isEmpty ? data : nil
            } catch {
                result = nil
            }
            guard let self else { return }
            self.artworkLoads[artwork] = nil
            if let result {
                self.artworkCache[artwork] = result
            } else {
                // Without the query, which can carry a token.
                log(.player).warning("Artwork not loaded: \(url.host ?? "")\(url.path)")
                self.failedArtwork.insert(artwork)
            }
            if let item = self.item { self.applyPresentation(to: item) }
        }
    }

    // MARK: View

    /// The view appeared: show the player there and start a session for the loaded media unless one is running.
    func attach(_ host: PlayerHostViewController) {
        let previous = self.host
        if let previous, previous !== host { previous.playerViewController.player = nil }
        self.host = host
        host.playerViewController.player = avPlayer
        if previous !== host, let session, let item { installRenderers(session: session, item: item, recreate: true) }
        guard session == nil, startTask == nil, currentMedia != nil else { return }
        start()
    }

    /// The view is going away. Resets the display mode now, while the view is still on
    /// screen, and covers the window in black until the switch back starts, so the view
    /// underneath is not shown in the stream's mode first.
    func willLeave(_ host: PlayerHostViewController) {
        guard self.host === host else { return }
        resetDisplay()
    }

    /// The view went away: end the session.
    func detach(_ host: PlayerHostViewController) {
        guard self.host === host else { return }
        teardown()
        host.playerViewController.player = nil
        self.host = nil
    }

    // MARK: Session

    private func start() {
        guard let media = currentMedia else { return }
        status = .loading
        error = nil
        logger[metadataKey: LogMetadata.session] = .string(LogMetadata.newSessionID())
        log(.player).notice("Opening \(media.url.lastPathComponent)\(startPosition.map { String(format: " at %.1f s", $0) } ?? "")")
        observeSessionEvents()
        var configuration = configuration
        configuration.httpHeaders.merge(media.headers) { _, media in media }
        let generation = loadGeneration
        let logger = logger
        startTask = Task { [weak self, configuration] in
            do {
                let session = try await EnhancedPlaybackSession.start(url: media.url, configuration: configuration, externalSubtitles: media.subtitles, trickplay: media.trickplay, logger: logger)
                guard let self, !Task.isCancelled else {
                    await session.stop()
                    return
                }
                self.session = session
                self.sessionForCleanup.withLock { $0 = session }
                self.sessionDidOpen(session)
                session.prepareSegments(at: max(0, (self.startPosition ?? 0) - session.originSeconds), selection: self.startSelection)
                try await self.matchDisplay(to: session)
                guard !Task.isCancelled, self.session === session else { return }
                log(.display).info("Display ready, starting AVPlayer")
                self.activateAudioSession()
                self.begin(session, master: session.masterPlaylistURL)
            } catch {
                if !(error is CancellationError) { logger.category(.player).error("Playback did not start: \(error)") }
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.fail(error)
                self.failWaiters(error) { $0 == generation }
            }
        }
    }

    private func sessionDidOpen(_ session: EnhancedPlaybackSession) {
        duration = .seconds(session.duration)
        chapters = currentMedia?.chapters ?? session.fileChapters
        audioTracks = session.audioTracks
        subtitleTracks = session.subtitleTracks
        // A selection kept from an earlier session of this media, by index.
        if let audio = startSelection.audio, !session.audioTracks.indices.contains(audio) {
            log(.player).warning("Audio track \(audio) does not exist (\(session.audioTracks.count) tracks); starting with the default")
            startSelection.audio = nil
        }
        if case .track(let subtitle) = startSelection.subtitle, !session.subtitleTracks.indices.contains(subtitle) {
            log(.player).warning("Subtitle track \(subtitle) does not exist (\(session.subtitleTracks.count) tracks); starting with the default")
            startSelection.subtitle = nil
        }
        session.setStartSelection(startSelection)
        #if os(tvOS)
        // Made while the display switches and the first segments are prepared, so the chapter
        // list has its pictures by the time it can be opened.
        makeChapterPictures(session: session)
        #endif
        audioSelection = session.defaultAudioIndex(startSelection).map { session.audioTracks[$0] }
        subtitleSelection = session.defaultSubtitleIndex(startSelection).map { session.subtitleTracks[$0] }
        answerWaiters()
    }

    private func fail(_ error: any Error) {
        self.error = error
        status = .failed
    }

    /// Ends the session and keeps the position for the next one.
    private func teardown() {
        startTask?.cancel()
        startTask = nil
        if isReady, status != .ended, startPosition == nil { startPosition = currentTime.timeInterval }
        // Showing the view again starts on the tracks playing now.
        if isReady {
            if let audio = audioSelection { startSelection.audio = audio.index }
            startSelection.subtitle = subtitleSelection.map { .track($0.index) } ?? .off
        }
        if status == .ended { startPosition = nil }
        isReady = false
        removeItemObservers()
        waitingObservation = nil
        pgsRenderer?.stop()
        pgsRenderer = nil
        assRenderer?.stop()
        assRenderer = nil
        videoRenderer?.stop()
        videoRenderer = nil
        toneMapper?.stop()
        toneMapper = nil
        playsSDRMaster = false
        forcedSubtitles?.stop()
        forcedSubtitles = nil
        if let item { logSummary(of: item) }
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers = []
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        item = nil
        appliedMetadata = nil
        appliedChapters = nil
        chapterPictureRun?.token.cancel()
        chapterPictureRun = nil
        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        resetDisplay()
        if let session {
            Task { await session.stop() }
        }
        session = nil
        sessionForCleanup.withLock { $0 = nil }
        if status != .failed { status = .idle }
    }

    /// Clears the display criteria. When the display had switched for the stream and the
    /// view still has a window, that window stays black until the switch back has ended:
    /// the start notification comes as soon as the switch is requested, before the TV
    /// blanks, so the view underneath would still show in the stream's mode.
    private func resetDisplay() {
        #if os(tvOS)
        guard let manager = displayManager else { return }
        displayManager = nil
        let window = host?.view.window
        log(.display).info("Resetting the display criteria (switched: \(didSwitchDisplay), window: \(window != nil))")
        guard didSwitchDisplay, let window else {
            didSwitchDisplay = false
            manager.preferredDisplayCriteria = nil
            return
        }
        didSwitchDisplay = false
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .black
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        window.addSubview(cover)
        let recorder = DisplayModeSwitchRecorder()
        manager.preferredDisplayCriteria = nil
        Task { @MainActor in
            let outcome = try? await DisplayModeSwitch.wait(events: { recorder.events }, startTimeout: .seconds(3), switchTimeout: .seconds(10))
            let seen = recorder.events.map { "\($0)" }.joined(separator: ", ")
            log(.display).info("Display reset: \(outcome.map { "\($0)" } ?? "cancelled") (\(seen)), removing the cover")
            recorder.invalidate()
            cover.removeFromSuperview()
        }
        #endif
    }

    /// Asks for the display mode the stream prefers and waits until the display has
    /// switched. Without "Match Content" enabled in Settings no switch can happen, so
    /// there is nothing to wait for.
    private func matchDisplay(to session: EnhancedPlaybackSession) async throws {
        #if os(tvOS)
        guard let manager = host?.view.window?.avDisplayManager else { return }
        guard let criteria = try? await AVURLAsset(url: session.masterPlaylistURL).load(.preferredDisplayCriteria), self.session === session else { return }
        displayManager = manager
        guard manager.isDisplayCriteriaMatchingEnabled else {
            // Without it the display stays in its mode: other frame rates judder, HDR may not switch.
            log(.display).notice("Match Content is off in Settings; no display mode switch, screen at \(UIScreen.main.maximumFramesPerSecond) fps")
            manager.preferredDisplayCriteria = criteria
            return
        }
        if manager.isDisplayModeSwitchInProgress {
            // Nothing has been asked for yet, so this is AVKit's stale count (see DisplayModeSwitch).
            log(.display).notice("isDisplayModeSwitchInProgress is already true before any switch was requested; following the switch notifications instead")
        }
        // Recording starts before the request so a quick switch's start is not missed.
        let recorder = DisplayModeSwitchRecorder()
        defer { recorder.invalidate() }
        manager.preferredDisplayCriteria = criteria
        log(.display).info("Waiting for the display mode switch")
        let outcome = try await DisplayModeSwitch.wait(events: { recorder.events })
        let seen = recorder.events.map { "\($0)" }.joined(separator: ", ")
        didSwitchDisplay = outcome != .neverStarted
        switch outcome {
        case .switched: log(.display).notice("Display mode switch ended (\(seen)); screen at \(UIScreen.main.maximumFramesPerSecond) fps")
        case .neverStarted: log(.display).notice("No display mode switch started; screen at \(UIScreen.main.maximumFramesPerSecond) fps")
        case .neverEnded: log(.display).warning("Display mode switch did not end within 15 s (\(seen)), starting anyway")
        }
        #endif
    }

    /// tvOS offers Enhance Dialogue only in the `moviePlayback` mode. A failure here costs
    /// that option, not the movie, so playback goes ahead without it.
    private func activateAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            audioSessionActive = true
        } catch {
            log(.player).warning("Audio session not activated: \(error)")
        }
    }

    // MARK: Item

    /// tvOS cannot report the display's mode: `potentialEDRHeadroom` reads 1 in every mode
    /// and `currentEDRHeadroom` stays at 1 for a while after HDR video. So an HDR file is
    /// always offered its HDR master, and AVPlayer's refusal is what says the display is SDR.
    private func begin(_ session: EnhancedPlaybackSession, master: URL) {
        removeItemObservers()
        isReady = false
        let item = AVPlayerItem(url: master)
        self.item = item
        playsSDRMaster = master == session.sdrMasterPlaylistURL
        appliedMetadata = nil
        appliedChapters = nil
        applyPresentation(to: item)
        session.setStartOffset(startPosition.map { max(0, $0 - session.originSeconds) })
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: item)
        forcedSubtitles?.stop()
        forcedSubtitles = session.hasForcedSubtitles ? ForcedSubtitleSelector(session: session, player: avPlayer, item: item) : nil
        installRenderers(session: session, item: item, recreate: false)
        observe(item, session: session, master: master)
        Task { await self.prepareStart(item, session: session) }
    }

    /// Puts the starting tracks and position in place, then plays if asked to.
    private func prepareStart(_ item: AVPlayerItem, session: EnhancedPlaybackSession) async {
        let applied = await applyStartSelection(to: item, session: session, after: nil)
        guard self.item === item else { return }
        if let startPosition, startPosition > 0 {
            let target = CMTime(seconds: max(0, startPosition - session.originSeconds), preferredTimescale: 600)
            _ = await avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.item === item else { return }
        }
        // A track chosen while the others were applied, or during the seek, still counts as a
        // starting track: until `isReady`, choices only go into `startSelection`.
        // Nothing awaits between its return and `isReady`, so no choice falls in between.
        _ = await applyStartSelection(to: item, session: session, after: applied)
        guard self.item === item else { return }
        isReady = true
        // AVPlayer may have started on other tracks than the master's defaults.
        updateSelectedTracks(item, session: session)
        // Kept until the item is ready, for the SDR fallback's new item.
        if item.status == .readyToPlay { startPosition = nil }
        if wantsToPlay {
            avPlayer.play()
        } else {
            status = .paused
        }
    }

    /// Selects the starting tracks, again for as long as they change while being selected.
    /// Returns what was selected last. With `after`, only applies what differs from it.
    private func applyStartSelection(to item: AVPlayerItem, session: EnhancedPlaybackSession, after previous: StartSelection?) async -> StartSelection {
        var applied = previous
        while applied != startSelection, self.item === item {
            let selection = startSelection
            // No audio rendition is DEFAULT or AUTOSELECT, so AVPlayer starts on none: the
            // audio is always selected here. The master marks the chosen subtitle track DEFAULT;
            // selecting it as well covers the system's language preference choosing another.
            let audio = session.defaultAudioIndex(selection)
            if let audio, applied.map(session.defaultAudioIndex) != audio {
                await select(named: session.audioTrackNames[audio], characteristic: .audible, in: item)
            }
            if selection.subtitle != applied?.subtitle {
                switch selection.subtitle {
                case .track(let index):
                    await selectSubtitle(named: session.subtitleTrackNames[index], in: item)
                case .off:
                    await selectSubtitle(named: nil, in: item)
                case nil:
                    break
                }
            }
            applied = selection
        }
        return applied ?? startSelection
    }

    private func installRenderers(session: EnhancedPlaybackSession, item: AVPlayerItem, recreate: Bool) {
        if recreate {
            pgsRenderer?.stop()
            pgsRenderer = nil
            assRenderer?.stop()
            assRenderer = nil
            videoRenderer?.stop()
            videoRenderer = nil
            toneMapper?.stop()
            toneMapper = nil
        }
        guard let host, let overlay = host.playerViewController.contentOverlayView else { return }
        // The SDR master's video is relabeled HDR: shown tone mapped over AVPlayer's picture.
        if playsSDRMaster, let color = session.sdrMasterSourceColor {
            let renderer = toneMapper ?? ToneMappedVideoRenderer(color: color, playerView: host.playerViewController.view, container: overlay, logger: log(.video))
            toneMapper = renderer
            renderer.attach(item: item)
        } else {
            toneMapper?.stop()
            toneMapper = nil
        }
        if session.rendersVideo {
            // Below the subtitles: it puts itself at the bottom of the overlay.
            let renderer = videoRenderer ?? RenderedVideoRenderer(session: session, playerView: host.playerViewController.view, container: overlay)
            videoRenderer = renderer
            renderer.attach(item: item)
        }
        if session.hasPGSTracks {
            let renderer = pgsRenderer ?? PGSSubtitleRenderer(session: session, container: overlay)
            pgsRenderer = renderer
            renderer.attach(player: avPlayer, item: item)
        }
        if session.hasASSTracks {
            let renderer = assRenderer ?? ASSSubtitleRenderer(session: session, container: overlay)
            assRenderer = renderer
            renderer.attach(player: avPlayer, item: item)
        }
    }

    private func observe(_ item: AVPlayerItem, session: EnhancedPlaybackSession, master: URL) {
        // What AVPlayer itself reports while loading: the server only sees what it asks for.
        let avLogger = log(.avplayer)
        waitingObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let reason = player.reasonForWaitingToPlay.map { ", waiting: \($0.rawValue)" } ?? ""
            avLogger.info("AVPlayer \(player.timeControlStatus.logName)\(reason)")
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                self?.updateStatus()
                if playing { self?.logVideoFormat(item, when: "playing") }
            }
        }
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.item === item else { return }
                self.log(.avplayer).log(level: item.status == .failed ? .error : .info, "AVPlayerItem \(item.status.logName)\(item.error.map { ": \($0)" } ?? "")")
                switch item.status {
                case .readyToPlay:
                    self.logVideoFormat(item, when: "ready")
                    self.forcedSubtitles?.itemIsReady(item)
                    // The start position held for the SDR fallback; from here on, time moves.
                    if self.isReady { self.startPosition = nil }
                case .failed:
                    guard let error = item.error else { return }
                    if master == session.masterPlaylistURL, let sdrMaster = session.sdrMasterPlaylistURL, DisplayRefusal.matches(error, iFramePlaylistWithheld: session.iFramePlaylistWithheld) {
                        let nsError = error as NSError
                        self.log(.avplayer).notice("HDR master refused (\(nsError.domain) \(nsError.code)), playing the SDR master")
                        self.begin(session, master: sdrMaster)
                    } else {
                        self.fail(error)
                    }
                default:
                    break
                }
            }
        })
        itemObservations.append(item.observe(\.tracks, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.logVideoFormat(item, when: "tracks changed") }
        })
        let center = NotificationCenter.default
        // Seeks, the player's own and scrubs in the transport bar alike.
        itemObservers.append(center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logVideoFormat(item, when: "time jumped") }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log(.avplayer).warning("Playback stalled at \(String(format: "%.1f", self.currentTime.timeInterval)) s: AVPlayer ran out of loaded media")
            }
        })
        let errorLogger = log(.avplayer)
        itemObservers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { _ in
            guard let event = item.errorLog()?.events.last else { return }
            errorLogger.warning("AVPlayer error log: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") \(event.uri ?? "")")
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = .ended }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelectedTracks(item, session: session) }
        })
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isReady, time.isNumeric else { return }
                self.currentTime = .seconds(time.seconds + session.originSeconds)
            }
        }
    }

    /// What AVPlayer has as the video's sample description: the sample entry, the transfer
    /// function and the extension boxes (dvcC / dvvC carry the Dolby Vision profile). The
    /// master's variants are logged with it, as AVPlayer parsed them.
    private func logVideoFormat(_ item: AVPlayerItem, when moment: String) {
        guard self.item === item else { return }
        let itemTracks = item.tracks
        let asset = item.asset as? AVURLAsset
        Task {
            // Every item track, so a video track without an asset track still shows.
            var lines = ["\(itemTracks.count) item tracks: " + itemTracks.map { $0.assetTrack.map { "\($0.mediaType.rawValue) \($0.trackID)" } ?? "no asset track" }.joined(separator: ", ")]
            for track in itemTracks.compactMap(\.assetTrack) where track.mediaType == .video {
                let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                if descriptions.isEmpty { lines.append("track \(track.trackID): no format description yet") }
                for description in descriptions {
                    let subtype = CMFormatDescriptionGetMediaSubType(description).fourCharacterCode
                    let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? "none"
                    let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
                    let boxes = atoms.map { $0.keys.sorted().joined(separator: ",") } ?? "none"
                    lines.append("track \(track.trackID): \(subtype), transfer \(transfer), boxes \(boxes)")
                }
            }
            if moment == "ready", let asset, let variants = try? await asset.load(.variants) {
                for variant in variants {
                    let video = variant.videoAttributes
                    let codecs = video?.codecTypes.map(\.fourCharacterCode).joined(separator: ",") ?? "none"
                    lines.append("variant: codecs \(codecs), range \(video?.videoRange.rawValue ?? "none")")
                }
            }
            // Ready says what AVPlayer took; the rest repeats it on every seek and resume.
            self.log(.avplayer).log(level: moment == "ready" ? .info : .debug, "Video format (\(moment)): \(lines.joined(separator: "; "))")
        }
    }

    private func removeItemObservers() {
        itemObservations = []
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers = []
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    /// What AVPlayer measured over the item, from its access log: one line for the whole item.
    private func logSummary(of item: AVPlayerItem) {
        guard let events = item.accessLog()?.events, !events.isEmpty else { return }
        let watched = events.reduce(0) { $0 + max(0, $1.durationWatched) }
        let stalls = events.reduce(0) { $0 + max(0, $1.numberOfStalls) }
        let dropped = events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
        let bytes = events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
        let startup = events.first.map { $0.startupTime > 0 ? String(format: "%.2f s", $0.startupTime) : "–" } ?? "–"
        let observed = events.last.map { $0.observedBitrate > 0 ? "\(Int($0.observedBitrate / 1000)) kb/s" : "–" } ?? "–"
        // AVPlayer's dropped frames are the placeholder's when the engine draws the video; the
        // engine's own summary lines count those.
        log(.avplayer).notice("Item summary: watched \(String(format: "%.0f", watched)) s, startup \(startup), \(stalls) stalls, \(dropped) dropped frames\(session?.rendersVideo == true ? " (placeholder)" : ""), \(bytes >> 20) MB from the server at \(observed), ended at \(String(format: "%.1f", currentTime.timeInterval)) s\(playsSDRMaster ? ", SDR master" : "")")
    }

    /// The app and system around playback: backgrounding, memory, heat, and the audio route.
    private func observeSessionEvents() {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        let center = NotificationCenter.default
        let logger = log(.player)
        sessionObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                logger.info("App entered the background")
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                logger.info("App entering the foreground")
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                logger.warning("Memory warning")
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                let state = ProcessInfo.processInfo.thermalState
                logger.log(level: state.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .warning : .notice, "Thermal state \(state.logName)")
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { notification in
                let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                logger.notice("Audio session interruption \(type == .began ? "began" : type == .ended ? "ended" : "of unknown type")")
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                // Category changes come with every activation and say nothing about the route.
                guard let reason, reason != .categoryChange else { return }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                    .map { "\($0.portType.rawValue) \($0.portName)\($0.channels.map { ", \($0.count) ch" } ?? "")" }
                    .joined(separator: "; ")
                logger.notice("Audio route changed (reason \(reason.rawValue)): \(outputs.isEmpty ? "no output" : outputs)")
            },
        ]
    }

    private func updateStatus() {
        guard item != nil, status != .failed else { return }
        switch avPlayer.timeControlStatus {
        case .playing: status = .playing
        case .waitingToPlayAtSpecifiedRate: status = .loading
        case .paused: if status != .ended { status = isReady ? .paused : .loading }
        @unknown default: break
        }
    }

    private func updateSelectedTracks(_ item: AVPlayerItem, session: EnhancedPlaybackSession) {
        Task {
            guard let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self.item === item
            else { return }
            let selection = item.currentMediaSelection
            let before = (audioSelection, subtitleSelection)
            if let name = selection.selectedMediaOption(in: audible)?.renditionName, let index = session.audioTrackNames.firstIndex(of: name) {
                audioSelection = session.audioTracks[index]
            }
            subtitleSelection = selection.selectedMediaOption(in: legible)?.renditionName
                .flatMap { session.subtitleTrackNames.firstIndex(of: $0) }
                .map { session.subtitleTracks[$0] }
            if before.0 != audioSelection || before.1 != subtitleSelection {
                let audio = audioSelection.map { "\($0.index) (\($0.name))" } ?? "none"
                let subtitle = subtitleSelection.map { "\($0.index) (\($0.name))" } ?? "off"
                log(.player).info("Playing audio \(audio), subtitles \(subtitle)")
            }
        }
    }
}

/// The `AVMetadataItem`s behind the info panel, Now Playing and the chapter list.
enum MetadataItems {
    static func info(_ metadata: PlayerMetadata, artwork: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let title = metadata.title { items.append(item(.commonIdentifierTitle, title as NSString)) }
        if let subtitle = metadata.subtitle { items.append(item(.iTunesMetadataTrackSubTitle, subtitle as NSString)) }
        if let description = metadata.description { items.append(item(.commonIdentifierDescription, description as NSString)) }
        if let genre = metadata.genre { items.append(item(.quickTimeMetadataGenre, genre as NSString)) }
        if let rating = metadata.contentRating { items.append(item(.iTunesMetadataContentRating, rating as NSString)) }
        if let date = metadata.releaseDate { items.append(item(.commonIdentifierCreationDate, date as NSDate)) }
        if let artwork { items.append(artworkItem(artwork)) }
        return items
    }

    static func chapterMarkers(_ chapters: [Chapter], origin: TimeInterval, movieEnd: TimeInterval, artwork: (Artwork) -> Data?) -> [AVTimedMetadataGroup] {
        chapters.resolvingEnds(movieEnd: .seconds(movieEnd)).map { chapter, end in
            var items = [item(.commonIdentifierTitle, chapter.title as NSString)]
            if let data = chapter.artwork.flatMap(artwork) { items.append(artworkItem(data)) }
            let chapterStart = chapter.start.timeInterval
            let start = CMTime(seconds: max(0, chapterStart - origin), preferredTimescale: 1000)
            let duration = CMTime(seconds: end.timeInterval - max(chapterStart, origin), preferredTimescale: 1000)
            return AVTimedMetadataGroup(items: items, timeRange: CMTimeRange(start: start, duration: duration))
        }
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }

    private static func artworkItem(_ data: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = data as NSData
        item.dataType = (data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }
}
extension AVPlayer.TimeControlStatus {
    var logName: String {
        switch self {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting to play"
        case .playing: "playing"
        @unknown default: "status \(rawValue)"
        }
    }
}

extension AVPlayerItem.Status {
    var logName: String {
        switch self {
        case .unknown: "unknown"
        case .readyToPlay: "ready to play"
        case .failed: "failed"
        @unknown default: "status \(rawValue)"
        }
    }
}
#endif

private extension UInt32 {
    /// `dvh1`, `hvc1`, …
    var fourCharacterCode: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: self >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
