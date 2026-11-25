#if canImport(UIKit) && !os(watchOS)
import AVKit
import SwiftUI
import UIKit

/// Shows an `EnhancedPlayer` with the system player controls, the way `VideoPlayer` shows an `AVPlayer`.
///
/// ```swift
/// EnhancedPlayerView(player)
///     .ignoresSafeArea()
///     .task(id: media) {
///         try? await player.load(media)
///         player.play()
///     }
/// ```
///
/// What the info panel, Now Playing and the chapter list show comes from the loaded
/// `EnhancedMedia`. Showing the view opens the loaded media and going away ends its session,
/// wherever the view is: a full-screen cover, a sheet, a navigation push or a whole window.
///
/// Keep the player in `@State` (or in a model that outlives the view). A player created anew
/// each time the parent's body runs would start a new session each time.
public struct EnhancedPlayerView: View {
    private let player: EnhancedPlayer

    public init(_ player: EnhancedPlayer) {
        self.player = player
    }

    public var body: some View {
        PlayerRepresentable(player: player)
    }
}

private struct PlayerRepresentable: UIViewControllerRepresentable {
    let player: EnhancedPlayer

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        PlayerHostViewController(player: player)
    }

    func updateUIViewController(_ controller: PlayerHostViewController, context: Context) {
        controller.show(player)
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
        playerViewController.delegate = self
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
extension PlayerHostViewController: @preconcurrency AVPlayerViewControllerDelegate {
    /// A scrub or skip in the system controls: the player may move it to a nearby keyframe.
    func playerViewController(_ playerViewController: AVPlayerViewController, timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        player.seekTarget(afterUserNavigatedFrom: oldTime, to: targetTime)
    }
}
#endif
#endif
