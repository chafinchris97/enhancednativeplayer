import Foundation

public struct EnhancedPlayerConfiguration: Sendable {
    /// `hls_time`: the target segment duration. Segments are cut on keyframes, so
    /// actual durations follow ffmpeg's hls muxer around this target.
    public var segmentDuration: Double = 6
    /// How many segments a remux may run ahead of the newest request before it
    /// pauses. A request further ahead than this restarts the remux there.
    public var segmentsAhead: Int = 3
    /// Headers sent with every range request to the source (auth tokens, ...).
    public var httpHeaders: [String: String] = [:]
    /// Where segments and source blocks are cached. Defaults to the Caches directory.
    /// Each session works in its own subdirectory and deletes it when it stops.
    public var cacheDirectory: URL?
    /// Disk budget for downloaded source blocks shared by the video and audio remux.
    public var sourceCacheBytes: Int64 = 768 << 20

    public init() {}
}
