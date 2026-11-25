@preconcurrency import AVFoundation
import Logging

/// Turns on the forced subtitle track for the selected audio's language. The renditions carry
/// no FORCED attribute, since AVPlayer matches forced tracks on the audio's LANGUAGE and that
/// holds a label here, so the selection is made by hand: once the item is ready to play, and
/// when the audio changes after that, while subtitles are off or on a forced track. A track the
/// user picked is left alone. Nothing is selected while the item loads: a selection change then
/// can leave AVPlayer without its track list (no Dolby Vision profile, no video info) until a seek.
///
/// AVPlayer's automatic selection criteria are on, but they don't override an explicit
/// selection: it is AVPlayer's DEFAULT renditions at the start and whatever is selected here,
/// through the API or by the user after that. A forced track leaves the caption display type alone.
@MainActor
final class ForcedSubtitleSelector {
    private let session: EnhancedPlaybackSession
    private weak var player: AVPlayer?
    private var observer: NSObjectProtocol?
    private var audioName: String?
    private var task: Task<Void, Never>?
    private var isReady = false

    init(session: EnhancedPlaybackSession, player: AVPlayer, item: AVPlayerItem) {
        self.session = session
        self.player = player
        observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(item) }
        }
    }

    /// Called when `item` is ready to play: the first selection is made from here on.
    func itemIsReady(_ item: AVPlayerItem) {
        guard !isReady else { return }
        isReady = true
        update(item)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        task?.cancel()
    }

    private func update(_ item: AVPlayerItem) {
        guard isReady else { return }
        task?.cancel()
        task = Task { [weak self] in
            // The groups only exist once the master playlist has been read.
            guard let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, !Task.isCancelled
            else { return }
            let selection = item.currentMediaSelection
            let current = selection.selectedMediaOption(in: legible)?.renditionName
            guard let audio = selection.selectedMediaOption(in: audible)?.renditionName, audio != self.audioName else { return }
            self.audioName = audio
            // A track the user picked is left alone.
            if let current, !self.session.isForcedSubtitle(named: current) { return }
            let wanted = self.session.forcedSubtitleName(forAudioNamed: audio)
            guard wanted != current else { return }
            let option = wanted.flatMap { name in legible.options.first { $0.renditionName == name } }
            Logger.player.info("Forced subtitles for \(audio): \(option?.renditionName ?? "none")")
            item.select(option, in: legible)
        }
    }
}
