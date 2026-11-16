import Foundation

/// An image for the info panel or a chapter. A `.url` is downloaded with the media's headers
/// and kept for the session; pass `.data` when the app already has the image in its own cache.
public enum Artwork: Hashable, Sendable {
    case url(URL)
    case data(Data)
}

/// A chapter marker. Times are in the file's own timeline, the clock the player's
/// `currentTime` and `seek(to:)` use.
public struct Chapter: Hashable, Sendable {
    public var title: String
    public var start: Duration
    /// Nil: the next chapter's start, or the end of the movie for the last one.
    public var end: Duration?
    public var artwork: Artwork?

    public init(title: String, start: Duration, end: Duration? = nil, artwork: Artwork? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.artwork = artwork
    }
}

/// What the info panel and Now Playing show, from `EnhancedMedia`.
struct PlayerMetadata: Hashable, Sendable {
    var title: String?
    var subtitle: String?
    var description: String?
    var artwork: Artwork?
    var genre: String?
    var contentRating: String?
    var releaseDate: Date?
}

extension [Chapter] {
    /// Each chapter's end filled in: its own, the next one's start, or `movieEnd`.
    func resolvingEnds(movieEnd: Duration) -> [(chapter: Chapter, end: Duration)] {
        let sorted = self.sorted { $0.start < $1.start }
        return sorted.enumerated().compactMap { index, chapter in
            let end = chapter.end ?? (index + 1 < sorted.count ? sorted[index + 1].start : movieEnd)
            return end > chapter.start ? (chapter, end) : nil
        }
    }
}
