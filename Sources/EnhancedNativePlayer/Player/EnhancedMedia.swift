import Foundation

/// What to play: the file and everything that goes with it. Load it with `EnhancedPlayer.load`.
///
/// ```swift
/// let media = EnhancedMedia(
///     url: movieURL,
///     title: "Dune",
///     artwork: .url(posterURL),
///     subtitles: [ExternalSubtitle(url: srtURL, language: "en")]
/// )
/// ```
///
/// Every value but `url` is optional. All of it is fixed for one load: loading the same file
/// with other values starts it again.
public struct EnhancedMedia: Hashable, Sendable {
    /// Remote file reachable with HTTP range requests.
    public var url: URL
    /// Sent with every request for the file, external subtitles, trickplay sheets and artwork,
    /// over the configuration's headers.
    public var headers: [String: String]

    // What the info panel and Now Playing show.
    public var title: String?
    public var subtitle: String?
    public var description: String?
    public var artwork: Artwork?
    public var genre: String?
    public var contentRating: String?
    public var releaseDate: Date?

    /// Replaces the file's own chapters, which show when this is nil. An empty array shows
    /// no chapters. Shown in the tvOS transport bar; iOS has no chapter UI.
    public var chapters: [Chapter]?
    /// External subtitle files, listed before the file's own tracks.
    public var subtitles: [ExternalSubtitle]
    /// Sprite sheets of thumbnails for scrubbing.
    public var trickplay: Trickplay?

    public init(
        url: URL,
        headers: [String: String] = [:],
        title: String? = nil,
        subtitle: String? = nil,
        description: String? = nil,
        artwork: Artwork? = nil,
        genre: String? = nil,
        contentRating: String? = nil,
        releaseDate: Date? = nil,
        chapters: [Chapter]? = nil,
        subtitles: [ExternalSubtitle] = [],
        trickplay: Trickplay? = nil
    ) {
        self.url = url
        self.headers = headers
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.artwork = artwork
        self.genre = genre
        self.contentRating = contentRating
        self.releaseDate = releaseDate
        self.chapters = chapters
        self.subtitles = subtitles
        self.trickplay = trickplay
    }

    /// What the info panel and Now Playing show, nil when nothing is set.
    var metadata: PlayerMetadata? {
        let metadata = PlayerMetadata(
            title: title,
            subtitle: subtitle,
            description: description,
            artwork: artwork,
            genre: genre,
            contentRating: contentRating,
            releaseDate: releaseDate
        )
        return metadata == PlayerMetadata() ? nil : metadata
    }
}

/// An audio or subtitle track of the loaded media, as the player's track lists report it.
/// Valid for the load it came from: select one from the player's current lists.
public struct MediaTrack: Identifiable, Hashable, Sendable {
    /// The track's place in its list: the file's audio tracks in file order; for subtitles,
    /// external files first, in the order they were passed, then the file's own tracks.
    public var index: Int
    /// The name the menus show, e.g. "English (Forced)" or "English (2)". Unique in its list.
    public var name: String
    /// The language tag the file or the external subtitle gives, e.g. "eng" or "pt-BR".
    public var language: String?
    /// For subtitles: shown only where the dialogue isn't in the audio's language.
    public var isForced: Bool
    /// For subtitles: from a separate file rather than the media file itself.
    public var isExternal: Bool

    public var id: Int { index }

    public init(index: Int, name: String, language: String? = nil, isForced: Bool = false, isExternal: Bool = false) {
        self.index = index
        self.name = name
        self.language = language
        self.isForced = isForced
        self.isExternal = isExternal
    }
}

extension Duration {
    /// In seconds, for AVFoundation's clocks.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
