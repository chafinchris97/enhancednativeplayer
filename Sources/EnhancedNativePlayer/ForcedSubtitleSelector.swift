@preconcurrency import AVFoundation
import Logging

/// Turns on the forced subtitle track for the selected audio's language. The renditions carry
/// no FORCED attribute, since AVPlayer matches forced tracks on the audio's LANGUAGE and that
/// holds a label here, so the selection is made by hand: once the item is ready to play, and
/// when the audio changes after that, while subtitles are off or on a forced track. A track the
/// user picked is left alone. Nothing is selected while the item loads: a selection change then
/// can leave AVPlayer without its track list (no Dolby Vision profile, no video info) until a seek.
///
/// The player keeps AVPlayer's automatic selection criteria off, so the selection is AVPlayer's
/// DEFAULT renditions at the start and whatever is selected here or by the user after that.
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
            item.selectSubtitle(option, in: legible)
        }
    }
}

extension AVPlayerItem {
    /// Selects `option` in the subtitle group, or turns subtitles off for nil. A track is
    /// selected twice: on tvOS a single selection of the track the menu already shows (one that
    /// was deselected, so the menu kept it with the switch off) draws it but leaves the switch off.
    func selectSubtitle(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        select(option, in: group)
        if option != nil { select(option, in: group) }
    }
}
