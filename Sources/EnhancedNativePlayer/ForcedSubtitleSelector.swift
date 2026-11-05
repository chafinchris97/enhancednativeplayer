@preconcurrency import AVFoundation
import Logging

/// Turns on the forced subtitle track for the selected audio's language. The renditions carry
/// no FORCED attribute, since AVPlayer matches forced tracks on the audio's LANGUAGE and that
/// holds a label here, so the selection is made by hand: when the audio changes, and at the
/// start, while subtitles are off or on a forced track. A track the user picked is left alone.
///
/// While AVPlayer applies its selection criteria, the system subtitle setting decides what is
/// drawn: with subtitles off it draws only FORCED renditions, so a selected forced track stays
/// blank. Selecting one therefore turns the automatic criteria off for the player.
@MainActor
final class ForcedSubtitleSelector {
    private let session: EnhancedPlaybackSession
    private weak var player: AVPlayer?
    private var observer: NSObjectProtocol?
    private var audioName: String?
    private var task: Task<Void, Never>?

    init(session: EnhancedPlaybackSession, player: AVPlayer, item: AVPlayerItem) {
        self.session = session
        self.player = player
        observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(item) }
        }
        update(item)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        task?.cancel()
    }

    private func update(_ item: AVPlayerItem) {
        task?.cancel()
        task = Task { [weak self] in
            // The groups only exist once the master playlist has been read.
            guard let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, !Task.isCancelled
            else { return }
            let selection = item.currentMediaSelection
            guard let audio = selection.selectedMediaOption(in: audible)?.renditionName, audio != self.audioName else { return }
            self.audioName = audio
            let current = selection.selectedMediaOption(in: legible)
            if let name = current?.renditionName, !self.session.isForcedSubtitle(named: name) { return }
            let wanted = self.session.forcedSubtitleName(forAudioNamed: audio)
            guard wanted != current?.renditionName else { return }
            let option = wanted.flatMap { name in legible.options.first { $0.renditionName == name } }
            Logger.player.info("Forced subtitles for \(audio): \(option?.renditionName ?? "none")")
            if option != nil { self.player?.appliesMediaSelectionCriteriaAutomatically = false }
            item.select(option, in: legible)
        }
    }
}
