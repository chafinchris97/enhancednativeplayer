#if canImport(UIKit) && !os(watchOS)
@preconcurrency import AVFoundation
import AVKit
import Logging
import Observation
import UIKit

/// Plays a remote MKV or MP4 through AVPlayer, remuxed to HLS on the fly. Show it with
/// `EnhancedPlayerView`, the way `AVPlayer` is shown with `VideoPlayer`.
///
/// ```swift
/// struct MovieView: View {
///     @State private var player = EnhancedPlayer(url: movieURL)
///
///     var body: some View {
///         EnhancedPlayerView(player: player)
///             .ignoresSafeArea()
///             .onAppear {
///                 player.play()
///             }
///     }
/// }
/// ```
///
/// Creating a player starts nothing. When its view appears, the player probes the file, starts
/// the local server and, on tvOS, matches the display mode; `play()` takes effect once that is
/// done. When the view goes away the server stops, the cache is deleted and the display mode
/// and audio session are reset. The player keeps its position, so showing it again resumes.
///
/// Every setting works before playback starts and after: before, it says how playback starts
/// (`seek` sets the start position, `selectAudioTrack` the starting track); after, it acts at once.
///
/// Times are seconds in the file's own timeline. Track indices count from 0 in file order;
/// subtitle indices count external subtitles first, in the order they were passed.
@MainActor
@Observable
public final class EnhancedPlayer {
    public enum Status: Equatable, Sendable {
        /// Not shown, or stopped.
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
    /// Seconds in the file's timeline.
    public private(set) var currentTime: TimeInterval = 0
    /// Length in seconds, known once the file is open.
    public private(set) var duration: TimeInterval?
    /// The audio track playing, or the one playback will start with.
    public private(set) var selectedAudioTrackIndex: Int?
    /// The subtitle track showing, or the one playback will start with. Nil: subtitles are off.
    public private(set) var selectedSubtitleTrackIndex: Int?
    /// The file's own chapters, known once the file is open. Shown unless the view sets others.
    public private(set) var fileChapters: [Chapter] = []

    private let url: URL
    private let configuration: EnhancedPlayerConfiguration
    private let externalSubtitles: [ExternalSubtitle]
    private let trickplay: Trickplay?
    /// For `deinit`, which can't reach the main actor's state.
    private let sessionForCleanup = Mutex<EnhancedPlaybackSession?>(nil)

    @ObservationIgnored private weak var host: PlayerHostViewController?
    @ObservationIgnored private var session: EnhancedPlaybackSession?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var item: AVPlayerItem?
    /// Set once the current item's starting tracks and position are in place.
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var wantsToPlay = false
    /// Where playback starts, in the file's timeline.
    @ObservationIgnored private var startPosition: TimeInterval?
    @ObservationIgnored private var startSelection = StartSelection()
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var waitingObservation: NSKeyValueObservation?
    @ObservationIgnored private var pgsRenderer: PGSSubtitleRenderer?
    @ObservationIgnored private var assRenderer: ASSSubtitleRenderer?
    @ObservationIgnored private var forcedSubtitles: ForcedSubtitleSelector?
    @ObservationIgnored private var audioSessionActive = false
    #if os(tvOS)
    /// Kept because the view has no window any more by the time it goes away.
    @ObservationIgnored private var displayManager: AVDisplayManager?
    /// Whether the display switched mode for this session, so leaving switches it back.
    @ObservationIgnored private var didSwitchDisplay = false
    #endif

    // What the view shows around the playback.
    @ObservationIgnored private var metadata: PlayerMetadata?
    @ObservationIgnored private var customChapters: [Chapter]?
    @ObservationIgnored private var artworkCache: [Artwork: Data] = [:]
    @ObservationIgnored private var failedArtwork: Set<Artwork> = []
    @ObservationIgnored private var artworkLoads: [Artwork: Task<Void, Never>] = [:]
    @ObservationIgnored private var appliedMetadata: MetadataState?
    @ObservationIgnored private var appliedChapters: ChapterState?

    /// - Parameters:
    ///   - url: Remote file reachable with HTTP range requests.
    ///   - headers: Sent with every request for the file, external subtitles and artwork.
    ///   - subtitles: External subtitle files, listed before the file's own tracks.
    ///   - trickplay: Sprite sheets of thumbnails for scrubbing.
    ///     Sheets are fetched with `headers` as they are needed.
    ///   - configuration: Engine tuning. Its headers merge under `headers`.
    public init(url: URL, headers: [String: String] = [:], subtitles: [ExternalSubtitle] = [], trickplay: Trickplay? = nil, configuration: EnhancedPlayerConfiguration = EnhancedPlayerConfiguration()) {
        var configuration = configuration
        configuration.httpHeaders.merge(headers) { _, new in new }
        self.url = url
        self.configuration = configuration
        self.externalSubtitles = subtitles
        self.trickplay = trickplay
    }

    deinit {
        // The view normally ends the session; this is the backstop.
        if let session = sessionForCleanup.withLock({ $0 }) {
            Task { await session.stop() }
        }
    }

    // MARK: Playback

    /// Starts or resumes playback. Before the file is open, playback starts as soon as it can.
    public func play() {
        wantsToPlay = true
        if isReady { avPlayer.play() }
    }

    public func pause() {
        wantsToPlay = false
        if isReady { avPlayer.pause() }
        if status == .loading, !isReady { return }
        if status != .ended, status != .failed, status != .idle { status = .paused }
    }

    /// Jumps to `seconds` in the file's timeline. Before playback starts, sets where it starts.
    public func seek(toSeconds seconds: TimeInterval) {
        currentTime = seconds
        guard isReady, let session else {
            startPosition = seconds
            return
        }
        let target = CMTime(seconds: max(0, seconds - session.originSeconds), preferredTimescale: 600)
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if status == .ended { status = .paused }
    }

    /// Ends playback now: the server stops, the cache is deleted and the display mode is reset.
    /// Showing the view again starts a new session from the same position.
    public func stop() {
        teardown()
    }

    // MARK: Tracks

    /// Selects the audio track at `index`, counting the file's audio tracks from 0.
    public func selectAudioTrack(index: Int) {
        if let session, !session.audioTrackNames.indices.contains(index) {
            Logger.player.warning("Audio track \(index) does not exist (\(session.audioTrackNames.count) tracks)")
            return
        }
        guard isReady, let item, let session else {
            startSelection.audio = index
            selectedAudioTrackIndex = index
            return
        }
        let name = session.audioTrackNames[index]
        Task { await self.select(named: name, characteristic: .audible, in: item) }
    }

    /// Selects the subtitle track at `index`: external subtitles first, then the file's own.
    public func selectSubtitleTrack(index: Int) {
        if let session, !session.subtitleTrackNames.indices.contains(index) {
            Logger.player.warning("Subtitle track \(index) does not exist (\(session.subtitleTrackNames.count) tracks)")
            return
        }
        guard isReady, let item, let session else {
            startSelection.subtitle = .track(index)
            selectedSubtitleTrackIndex = index
            return
        }
        let name = session.subtitleTrackNames[index]
        avPlayer.appliesMediaSelectionCriteriaAutomatically = false
        Task { await self.select(named: name, characteristic: .legible, in: item) }
    }

    /// Turns subtitles off. A forced track for the audio's language still shows.
    public func turnOffSubtitles() {
        guard isReady, let item else {
            startSelection.subtitle = .off
            selectedSubtitleTrackIndex = nil
            return
        }
        avPlayer.appliesMediaSelectionCriteriaAutomatically = false
        Task { await self.select(named: nil, characteristic: .legible, in: item) }
    }

    private func select(named name: String?, characteristic: AVMediaCharacteristic, in item: AVPlayerItem) async {
        // The groups only exist once the master playlist has been read.
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic), self.item === item else { return }
        let option = name.flatMap { name in group.options.first { $0.renditionName == name } }
        if name != nil, option == nil {
            Logger.player.warning("No rendition named \(name!)")
            return
        }
        item.select(option, in: group)
    }

    // MARK: Presentation

    /// What the view shows around the playback, applied to every item. Only what changed is rewritten.
    func setPresentation(metadata: PlayerMetadata?, chapters: [Chapter]?) {
        self.metadata = metadata
        customChapters = chapters
        if let item { applyPresentation(to: item) }
    }

    private struct MetadataState: Equatable {
        var metadata: PlayerMetadata?
        var hasArtwork: Bool
    }

    private struct ChapterState: Equatable {
        var chapters: [Chapter]
        var loadedArtwork: Set<Artwork>
    }

    private func applyPresentation(to item: AVPlayerItem) {
        applyMetadata(to: item)
        applyChapters(to: item)
    }

    private func applyMetadata(to item: AVPlayerItem) {
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
        let chapters = customChapters ?? fileChapters
        let artworks = Set(chapters.compactMap(\.artwork))
        artworks.forEach(loadArtwork)
        // Titles go up at once; images together once they have all arrived, not one by one.
        if appliedChapters?.chapters == chapters, artworks.contains(where: { artworkLoads[$0] != nil }) { return }
        let state = ChapterState(chapters: chapters, loadedArtwork: artworks.filter { artworkData($0) != nil })
        guard state != appliedChapters else { return }
        appliedChapters = state
        let markers = MetadataItems.chapterMarkers(
            chapters,
            origin: session.originSeconds,
            movieEnd: session.originSeconds + session.duration,
            artwork: { self.artworkData($0) }
        )
        item.navigationMarkerGroups = markers.isEmpty ? [] : [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
        #endif
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
        let headers = configuration.httpHeaders
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
                Logger.player.warning("Artwork not loaded: \(url.absoluteString)")
                self.failedArtwork.insert(artwork)
            }
            if let item = self.item { self.applyPresentation(to: item) }
        }
    }

    // MARK: View

    /// The view appeared: show the player there and start a session unless one is running.
    func attach(_ host: PlayerHostViewController) {
        let previous = self.host
        if let previous, previous !== host { previous.playerViewController.player = nil }
        self.host = host
        host.playerViewController.player = avPlayer
        if previous !== host, let session, let item { installRenderers(session: session, item: item, recreate: true) }
        guard session == nil, startTask == nil else { return }
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
        status = .loading
        error = nil
        Logger.player.info("Opening \(url.lastPathComponent)")
        startTask = Task { [weak self, url, configuration, externalSubtitles, trickplay] in
            do {
                let session = try await EnhancedPlaybackSession.start(url: url, configuration: configuration, externalSubtitles: externalSubtitles, trickplay: trickplay)
                guard let self, !Task.isCancelled else {
                    await session.stop()
                    return
                }
                self.session = session
                self.sessionForCleanup.withLock { $0 = session }
                self.sessionDidOpen(session)
                try await self.matchDisplay(to: session)
                guard !Task.isCancelled, self.session === session else { return }
                Logger.player.info("Display ready, starting AVPlayer")
                self.activateAudioSession()
                self.begin(session, master: session.masterPlaylistURL)
            } catch {
                Logger.player.error("Playback did not start: \(error)")
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.fail(error)
            }
        }
    }

    private func sessionDidOpen(_ session: EnhancedPlaybackSession) {
        duration = session.duration
        fileChapters = session.fileChapters
        if let audio = startSelection.audio, !session.audioTrackNames.indices.contains(audio) {
            Logger.player.warning("Audio track \(audio) does not exist (\(session.audioTrackNames.count) tracks); starting with the default")
            startSelection.audio = nil
        }
        if case .track(let subtitle) = startSelection.subtitle, !session.subtitleTrackNames.indices.contains(subtitle) {
            Logger.player.warning("Subtitle track \(subtitle) does not exist (\(session.subtitleTrackNames.count) tracks); starting with the default")
            startSelection.subtitle = nil
        }
        session.setStartSelection(startSelection)
        selectedAudioTrackIndex = session.defaultAudioIndex(startSelection)
        selectedSubtitleTrackIndex = session.defaultSubtitleIndex(startSelection)
    }

    private func fail(_ error: any Error) {
        self.error = error
        status = .failed
    }

    /// Ends the session and keeps the position for the next one.
    private func teardown() {
        startTask?.cancel()
        startTask = nil
        if isReady, status != .ended, startPosition == nil { startPosition = currentTime }
        if status == .ended { startPosition = nil }
        isReady = false
        removeItemObservers()
        waitingObservation = nil
        pgsRenderer?.stop()
        pgsRenderer = nil
        assRenderer?.stop()
        assRenderer = nil
        forcedSubtitles?.stop()
        forcedSubtitles = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        item = nil
        appliedMetadata = nil
        appliedChapters = nil
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
        Logger.player.info("Resetting the display criteria (switched: \(didSwitchDisplay), window: \(window != nil))")
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
            Logger.player.info("Display reset: \(outcome.map { "\($0)" } ?? "cancelled") (\(seen)), removing the cover")
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
            manager.preferredDisplayCriteria = criteria
            return
        }
        if manager.isDisplayModeSwitchInProgress {
            // Nothing has been asked for yet, so this is AVKit's stale count (see DisplayModeSwitch).
            Logger.player.notice("isDisplayModeSwitchInProgress is already true before any switch was requested; following the switch notifications instead")
        }
        // Recording starts before the request so a quick switch's start is not missed.
        let recorder = DisplayModeSwitchRecorder()
        defer { recorder.invalidate() }
        manager.preferredDisplayCriteria = criteria
        Logger.player.info("Waiting for the display mode switch")
        let outcome = try await DisplayModeSwitch.wait(events: { recorder.events })
        let seen = recorder.events.map { "\($0)" }.joined(separator: ", ")
        didSwitchDisplay = outcome != .neverStarted
        switch outcome {
        case .switched: Logger.player.info("Display mode switch ended (\(seen))")
        case .neverStarted: Logger.player.info("No display mode switch started")
        case .neverEnded: Logger.player.warning("Display mode switch did not end within 15 s (\(seen)), starting anyway")
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
            Logger.player.warning("Audio session not activated: \(error)")
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
        appliedMetadata = nil
        appliedChapters = nil
        applyPresentation(to: item)
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
        // The master already marks the chosen tracks DEFAULT. Selecting them as well covers
        // the system's language preference choosing another.
        if let audio = startSelection.audio {
            await select(named: session.audioTrackNames[audio], characteristic: .audible, in: item)
        }
        switch startSelection.subtitle {
        case .track(let index):
            avPlayer.appliesMediaSelectionCriteriaAutomatically = false
            await select(named: session.subtitleTrackNames[index], characteristic: .legible, in: item)
        case .off:
            avPlayer.appliesMediaSelectionCriteriaAutomatically = false
            await select(named: nil, characteristic: .legible, in: item)
        case nil:
            break
        }
        guard self.item === item else { return }
        if let startPosition, startPosition > 0 {
            let target = CMTime(seconds: max(0, startPosition - session.originSeconds), preferredTimescale: 600)
            _ = await avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.item === item else { return }
        }
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

    private func installRenderers(session: EnhancedPlaybackSession, item: AVPlayerItem, recreate: Bool) {
        if recreate {
            pgsRenderer?.stop()
            pgsRenderer = nil
            assRenderer?.stop()
            assRenderer = nil
        }
        guard let overlay = host?.playerViewController.contentOverlayView else { return }
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
        waitingObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            Logger.player.info("AVPlayer timeControlStatus \(player.timeControlStatus.rawValue), waiting reason \(reason)")
            Task { @MainActor [weak self] in self?.updateStatus() }
        }
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.item === item else { return }
                Logger.player.info("AVPlayerItem status \(item.status.rawValue)\(item.error.map { ": \($0)" } ?? "")")
                switch item.status {
                case .readyToPlay:
                    // The start position held for the SDR fallback; from here on, time moves.
                    if self.isReady { self.startPosition = nil }
                case .failed:
                    guard let error = item.error else { return }
                    if master == session.masterPlaylistURL, let sdrMaster = session.sdrMasterPlaylistURL, DisplayRefusal.matches(error) {
                        let nsError = error as NSError
                        Logger.player.info("HDR master refused (\(nsError.domain) \(nsError.code)), playing the SDR master")
                        self.begin(session, master: sdrMaster)
                    } else {
                        self.fail(error)
                    }
                default:
                    break
                }
            }
        })
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { _ in
            guard let event = item.errorLog()?.events.last else { return }
            Logger.player.warning("AVPlayer error log: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") \(event.uri ?? "")")
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
                self.currentTime = time.seconds + session.originSeconds
            }
        }
    }

    private func removeItemObservers() {
        itemObservations = []
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers = []
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
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
            if let name = selection.selectedMediaOption(in: audible)?.renditionName {
                selectedAudioTrackIndex = session.audioTrackNames.firstIndex(of: name)
            }
            selectedSubtitleTrackIndex = selection.selectedMediaOption(in: legible)?.renditionName.flatMap { session.subtitleTrackNames.firstIndex(of: $0) }
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
        chapters.resolvingEnds(movieEnd: movieEnd).map { chapter, end in
            var items = [item(.commonIdentifierTitle, chapter.title as NSString)]
            if let data = chapter.artwork.flatMap(artwork) { items.append(artworkItem(data)) }
            let start = CMTime(seconds: max(0, chapter.start - origin), preferredTimescale: 1000)
            let duration = CMTime(seconds: end - max(chapter.start, origin), preferredTimescale: 1000)
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
#endif
