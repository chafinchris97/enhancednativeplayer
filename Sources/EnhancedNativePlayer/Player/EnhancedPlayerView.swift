#if canImport(UIKit) && !os(watchOS)
import AVKit
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
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The display manager belongs to the window, which viewDidLoad does not have yet.
        player.attach(self)
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
#endif
