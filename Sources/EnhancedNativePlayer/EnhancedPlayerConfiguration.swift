import Foundation
import Logging

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
    /// Each session works in its own subdirectory and deletes it when it stops. One left by a
    /// session that never stopped (the app was killed) is deleted when a player is made or
    /// playback starts. Only session subdirectories are touched, so the directory can hold
    /// other files.
    public var cacheDirectory: URL?
    /// Disk budget for downloaded source blocks shared by the video and audio remux.
    public var sourceCacheBytes: Int64 = 768 << 20
    /// Where the engine logs. Nil (the default) logs to the unified system log, subsystem
    /// `EnhancedNativePlayer`, which Console.app shows. Pass a logger to send the lines through
    /// your own handlers instead, `Logger(label: "EnhancedNativePlayer")` for the ones your app
    /// bootstrapped; its level filters what the engine logs.
    ///
    /// Every line has `category` metadata naming the part of the engine it comes from (`player`,
    /// `avplayer`, `display`, `source`, `server`, `remux`, `video`, `subtitles`, `trickplay`,
    /// `ffmpeg`), and lines logged for a playback have `session` metadata, a short ID that is new
    /// for each one. The engine stores and sends nothing itself.
    public var logger: Logger?

    public init() {}
}
