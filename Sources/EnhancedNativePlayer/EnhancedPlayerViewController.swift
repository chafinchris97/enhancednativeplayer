#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import AVKit
import Logging
import UIKit

/// Plays a remote file through `AVPlayerViewController`, remuxed to HLS on the fly.
///
/// ```swift
/// let player = EnhancedPlayerViewController(url: fileURL)
/// player.modalPresentationStyle = .fullScreen
/// present(player, animated: true)
/// ```
///
/// AVPlayerViewController must not be subclassed, so it is embedded as a child.
/// On tvOS the display mode is matched to the stream before playback starts. An HDR
/// file whose master AVPlayer refuses for the display falls back to the SDR relabel. Dismissing
/// this controller ends playback, resets the display mode, stops the local server and
/// deletes every cached segment.
@MainActor
public final class EnhancedPlayerViewController: UIViewController {
    public let playerViewController = AVPlayerViewController()
    public private(set) var player: AVPlayer?
    private var session: EnhancedPlaybackSession?
    /// Called on the main actor if the file cannot be opened or playback fails.
    public var onError: ((Error) -> Void)?

    private let url: URL
    private let configuration: EnhancedPlayerConfiguration
    private let startPosition: TimeInterval?
    private var startTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var waitingObservation: NSKeyValueObservation?
    private var errorLogObserver: NSObjectProtocol?
    private var pgsRenderer: PGSSubtitleRenderer?
    private var forcedSubtitles: ForcedSubtitleSelector?
    private var stopped = false
    private var audioSessionActive = false
    #if os(tvOS)
    /// Kept because the view has no window any more by the time it has disappeared.
    private var displayManager: AVDisplayManager?
    #endif

    /// - Parameters:
    ///   - url: Remote file reachable with HTTP range requests.
    ///   - startPosition: Resume point in seconds.
    public init(url: URL, configuration: EnhancedPlayerConfiguration = .init(), startPosition: TimeInterval? = nil) {
        self.url = url
        self.configuration = configuration
        self.startPosition = startPosition
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(playerViewController)
        playerViewController.view.frame = view.bounds
        playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)
        #if os(tvOS)
        playerViewController.appliesPreferredDisplayCriteriaAutomatically = false
        #endif
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The display manager belongs to the window, which viewDidLoad does not have yet.
        guard startTask == nil, !stopped else { return }
        Logger.player.info("Opening \(url.lastPathComponent)")
        startTask = Task { [weak self, url, configuration] in
            do {
                let session = try await EnhancedPlaybackSession.start(url: url, configuration: configuration)
                guard let self, !self.stopped else {
                    await session.stop()
                    return
                }
                self.session = session
                try await self.matchDisplay(to: session)
                guard !self.stopped else { return }
                Logger.player.info("Display ready, starting AVPlayer")
                self.activateAudioSession()
                self.begin(session, master: session.masterPlaylistURL)
            } catch {
                Logger.player.error("Playback did not start: \(error)")
                guard let self, !self.stopped, !(error is CancellationError) else { return }
                self.onError?(error)
            }
        }
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || (parent?.isBeingDismissed ?? false) || (navigationController?.isBeingDismissed ?? false) {
            stop()
        }
    }

    /// Ends playback and releases the session. Safe to call more than once.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        startTask?.cancel()
        statusObservation = nil
        waitingObservation = nil
        if let errorLogObserver { NotificationCenter.default.removeObserver(errorLogObserver) }
        errorLogObserver = nil
        pgsRenderer?.stop()
        pgsRenderer = nil
        forcedSubtitles?.stop()
        forcedSubtitles = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerViewController.player = nil
        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #if os(tvOS)
        displayManager?.preferredDisplayCriteria = nil
        displayManager = nil
        #endif
        if let session {
            Task { await session.stop() }
        }
        session = nil
    }

    /// Asks for the display mode the stream prefers and waits until the display has
    /// switched. Without "Match Content" enabled in Settings no switch can happen, so
    /// there is nothing to wait for.
    private func matchDisplay(to session: EnhancedPlaybackSession) async throws {
        #if os(tvOS)
        guard let manager = view.window?.avDisplayManager else { return }
        guard let criteria = try? await AVURLAsset(url: session.masterPlaylistURL).load(.preferredDisplayCriteria), !stopped else { return }
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

    /// tvOS cannot report the display's mode: `potentialEDRHeadroom` reads 1 in every mode
    /// and `currentEDRHeadroom` stays at 1 for a while after HDR video. So an HDR file is
    /// always offered its HDR master, and AVPlayer's refusal is what says the display is SDR.
    private func begin(_ session: EnhancedPlaybackSession, master: URL) {
        let item = AVPlayerItem(url: master)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playerViewController.player = player
        forcedSubtitles?.stop()
        forcedSubtitles = session.hasForcedSubtitles ? ForcedSubtitleSelector(session: session, player: player, item: item) : nil
        if session.hasPGSTracks, let overlay = playerViewController.contentOverlayView {
            let renderer = pgsRenderer ?? PGSSubtitleRenderer(session: session, container: overlay)
            pgsRenderer = renderer
            renderer.attach(player: player, item: item)
        }

        // What AVPlayer itself reports while loading: the server only sees what it asks for.
        waitingObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            Logger.player.info("AVPlayer timeControlStatus \(player.timeControlStatus.rawValue), waiting reason \(reason)")
        }
        if let errorLogObserver { NotificationCenter.default.removeObserver(errorLogObserver) }
        errorLogObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { _ in
            guard let event = item.errorLog()?.events.last else { return }
            Logger.player.warning("AVPlayer error log: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") \(event.uri ?? "")")
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                Logger.player.info("AVPlayerItem status \(item.status.rawValue)\(item.error.map { ": \($0)" } ?? "")")
                guard self.player?.currentItem === item, item.status == .failed, let error = item.error else { return }
                if master == session.masterPlaylistURL, let sdrMaster = session.sdrMasterPlaylistURL, DisplayRefusal.matches(error) {
                    let nsError = error as NSError
                    Logger.player.info("HDR master refused (\(nsError.domain) \(nsError.code)), playing the SDR master")
                    self.player?.pause()
                    self.begin(session, master: sdrMaster)
                } else {
                    self.onError?(error)
                }
            }
        }
        if let startPosition, startPosition > 0 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        } else {
            player.play()
        }
    }
}
#endif
