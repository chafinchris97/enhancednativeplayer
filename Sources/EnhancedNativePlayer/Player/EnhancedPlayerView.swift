#if canImport(UIKit) && !os(watchOS)
import AVKit
import MediaAccessibility
import Observation
import SwiftUI
import UIKit

/// Shows an `EnhancedPlayer` with the system player controls, the way `VideoPlayer` shows an `AVPlayer`.
///
/// ```swift
/// EnhancedPlayerView(player: player)
///     .metadata(title: "Dune", description: "…", artwork: .url(posterURL))
///     .chapters([
///         Chapter(title: "Opening", start: 0),
///         Chapter(title: "Arrakis", start: 754),
///     ])
///     .ignoresSafeArea()
/// ```
///
/// Playback starts its session when the view appears and ends it when the view goes away,
/// wherever the view is: a full-screen cover, a sheet, a navigation push or a whole window.
///
/// Keep the player in `@State` (or in a model that outlives the view). A player created anew
/// each time the parent's body runs would start a new session each time.
public struct EnhancedPlayerView: View {
    private let player: EnhancedPlayer
    private var metadata: PlayerMetadata?
    private var chapters: [Chapter]?

    public init(player: EnhancedPlayer) {
        self.player = player
    }

    public var body: some View {
        PlayerRepresentable(player: player, metadata: metadata, chapters: chapters)
    }

    /// What the info panel and Now Playing show. Every value is optional; a later call replaces
    /// the whole set, and only what changed is rewritten.
    public func metadata(
        title: String? = nil,
        subtitle: String? = nil,
        description: String? = nil,
        artwork: Artwork? = nil,
        genre: String? = nil,
        contentRating: String? = nil,
        releaseDate: Date? = nil
    ) -> EnhancedPlayerView {
        var view = self
        view.metadata = PlayerMetadata(
            title: title,
            subtitle: subtitle,
            description: description,
            artwork: artwork,
            genre: genre,
            contentRating: contentRating,
            releaseDate: releaseDate
        )
        return view
    }

    /// Replaces the file's own chapters, which show when this isn't used. An empty array
    /// shows no chapters. Shown in the tvOS transport bar; iOS has no chapter UI.
    public func chapters(_ chapters: [Chapter]) -> EnhancedPlayerView {
        var view = self
        view.chapters = chapters
        return view
    }
}

private struct PlayerRepresentable: UIViewControllerRepresentable {
    let player: EnhancedPlayer
    let metadata: PlayerMetadata?
    let chapters: [Chapter]?

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        player.setPresentation(metadata: metadata, chapters: chapters)
        return PlayerHostViewController(player: player)
    }

    func updateUIViewController(_ controller: PlayerHostViewController, context: Context) {
        controller.show(player)
        player.setPresentation(metadata: metadata, chapters: chapters)
    }

    static func dismantleUIViewController(_ controller: PlayerHostViewController, coordinator: ()) {
        controller.dismantle()
    }
}

/// Embeds `AVPlayerViewController`, which must not be subclassed, and tells the player when
/// it is on screen. Its window is what display matching needs, and its overlay is where PGS
/// and ASS subtitles are drawn.
@MainActor
final class PlayerHostViewController: UIViewController {
    let playerViewController = AVPlayerViewController()
    private var player: EnhancedPlayer
    #if os(tvOS)
    /// The track the subtitles menu's On turns back on, kept while subtitles are off.
    private var lastSubtitleIndex: Int?
    /// What was just picked in the subtitles menu (nil inside for off), shown until the
    /// player's selection catches up, which comes after AVPlayer's notification.
    private var chosenSubtitle: Int??
    private var subtitlesMenu: SubtitlesMenu?
    #endif

    init(player: EnhancedPlayer) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(playerViewController)
        playerViewController.view.frame = view.bounds
        playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)
        #if os(tvOS)
        // The player sets the display criteria itself, and waits for the switch before playing.
        playerViewController.appliesPreferredDisplayCriteriaAutomatically = false
        playerViewController.delegate = self
        // Once the user turns subtitles off in AVKit's own menu, its switch stays off whatever
        // the player selects after, until the user turns it on there. Offering that menu no
        // tracks takes it away, and the player's own menu in the transport bar takes its place.
        playerViewController.allowedSubtitleOptionLanguages = []
        updateSubtitlesMenu()
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The display manager belongs to the window, which viewDidLoad does not have yet.
        player.attach(self)
    }

    /// Leaving starts here, while the view is still on screen. SwiftUI's navigation stack
    /// sets neither `isMovingFromParent` nor `isBeingDismissed` on a pop, and `dismantle`
    /// only comes once the view underneath is showing, so any disappearance counts.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.willLeave(self)
    }

    /// A different player was passed to the view.
    func show(_ player: EnhancedPlayer) {
        guard player !== self.player else { return }
        self.player.detach(self)
        self.player = player
        if view.window != nil { player.attach(self) }
    }

    /// SwiftUI removed the view.
    func dismantle() {
        player.detach(self)
    }
}

#if os(tvOS)
extension PlayerHostViewController {
    /// The subtitles menu's items, built once per track list and changed in place after that:
    /// AVKit redraws an open menu when an item it shows changes its state or subtitle, not
    /// when the transport bar's items are replaced.
    @MainActor
    final class SubtitlesMenu {
        let names: [String]
        let on: UIAction
        let off: UIAction
        let languages: UIMenu
        let tracks: [UIAction]
        let menu: UIMenu
        /// The track On turns on and Language shows: the selected one, or the last one while off.
        var shown = 0

        init(names: [String], choose: @escaping @MainActor (Int?) -> Void, style: UIMenu?) {
            self.names = names
            // On reads `shown` when it is chosen, so it is set after init.
            var menuRef: SubtitlesMenu?
            on = UIAction(title: "On", attributes: .keepsMenuPresented) { _ in choose(menuRef?.shown ?? 0) }
            off = UIAction(title: "Off", attributes: .keepsMenuPresented) { _ in choose(nil) }
            tracks = names.indices.map { index in UIAction(title: names[index]) { _ in choose(index) } }
            languages = UIMenu(title: "Language", options: .singleSelection, children: tracks)
            // No .singleSelection: with it the menu keeps its own checked item from the last tap,
            // apart from the items' state, and a selection made elsewhere leaves two checked.
            // Without it a pick closes the menu, which .keepsMenuPresented on On and Off prevents.
            let toggle = UIMenu(options: .displayInline, children: [on, off])
            menu = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: [toggle, languages] + (style.map { [$0] } ?? []))
            menuRef = self
        }

        /// Moves the checkmarks and the Language subtitle to `selected` (nil for off).
        func show(_ selected: Int?, last: Int?) {
            shown = selected ?? last.flatMap { names.indices.contains($0) ? $0 : nil } ?? 0
            set(on, selected == nil ? .off : .on)
            set(off, selected == nil ? .on : .off)
            for (index, track) in tracks.enumerated() { set(track, index == shown ? .on : .off) }
            if languages.subtitle != names[shown] { languages.subtitle = names[shown] }
        }

        private func set(_ action: UIAction, _ state: UIMenuElement.State) {
            if action.state != state { action.state = state }
        }
    }

    /// Puts the subtitles menu in the transport bar when the track list changes, and moves its
    /// checkmarks whenever the selection changes.
    private func updateSubtitlesMenu() {
        let (names, playerSelection) = withObservationTracking {
            (player.subtitleTrackNames, player.selectedSubtitleTrackIndex)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateSubtitlesMenu() }
        }
        guard !names.isEmpty else {
            subtitlesMenu = nil
            playerViewController.transportBarCustomMenuItems = []
            return
        }
        if subtitlesMenu?.names != names {
            var style: UIMenu?
            if #available(tvOS 26, *) { style = styleMenu() }
            let menu = SubtitlesMenu(names: names, choose: { [weak self] index in self?.chooseSubtitle(index) }, style: style)
            subtitlesMenu = menu
            playerViewController.transportBarCustomMenuItems = [menu.menu]
        }
        if chosenSubtitle == .some(playerSelection) { chosenSubtitle = nil }
        let selected = chosenSubtitle ?? playerSelection
        if let selected { lastSubtitleIndex = selected }
        subtitlesMenu?.show(selected, last: lastSubtitleIndex)
    }

    /// A pick in the subtitles menu: the menu shows it at once, before AVPlayer has applied it.
    private func chooseSubtitle(_ index: Int?) {
        chosenSubtitle = .some(index)
        if let index { player.selectSubtitleTrack(index: index) } else { player.turnOffSubtitles() }
        updateSubtitlesMenu()
    }

    /// The system's caption styles. Choosing one changes it for every app, as in AVKit's menu.
    @available(tvOS 26, *)
    private func styleMenu() -> UIMenu? {
        guard let ids = MACaptionAppearanceCopyProfileIDs() as? [String], !ids.isEmpty else { return nil }
        let active = MACaptionAppearanceCopyActiveProfileID() as String
        let name = { (id: String) in MACaptionAppearanceCopyProfileName(id as CFString) as String }
        var styles: [UIAction] = []
        var menuRef: UIMenu?
        for id in ids {
            styles.append(UIAction(title: name(id), state: id == active ? .on : .off) { _ in
                MACaptionAppearanceSetActiveProfileID(id as CFString)
                // The active style isn't observed, so the checkmarks and subtitle move here.
                for (styleID, style) in zip(ids, styles) { style.state = styleID == id ? .on : .off }
                menuRef?.subtitle = name(id)
            })
        }
        let menu = UIMenu(title: "Style", subtitle: ids.contains(active) ? name(active) : nil, options: .singleSelection, children: styles)
        menuRef = menu
        return menu
    }
}

extension PlayerHostViewController: @preconcurrency AVPlayerViewControllerDelegate {
    /// A scrub or skip in the system controls: the player may move it to a nearby keyframe.
    func playerViewController(_ playerViewController: AVPlayerViewController, timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        player.seekTarget(afterUserNavigatedFrom: oldTime, to: targetTime)
    }
}
#endif
#endif
