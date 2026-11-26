import EPLibavutil
import FFmpegLogBridge
import Foundation
import Logging
import os

/// The part of the engine a log line comes from. Every line carries it as its `category`
/// metadata, and the default logger uses it as the unified log's category, so Console.app
/// filters on it (`category:video`).
enum LogCategory: String, Sendable {
    /// `EnhancedPlayer`: loading, state, tracks, the app and audio session around playback.
    case player
    /// AVPlayer's own reports: its status, stalls, access and error logs.
    case avplayer
    /// Display mode matching and the switch back.
    case display
    /// Range reads of the remote file.
    case source
    /// The local HLS server and its requests.
    case server
    /// The segment pipelines.
    case remux
    /// Video the engine decodes and draws, and the SDR master's tone mapping.
    case video
    /// PGS, ASS, external and forced subtitles.
    case subtitles
    case trickplay
    /// libavformat and libavcodec's own messages.
    case ffmpeg
}

extension Logging.Logger {
    /// The logger used when `EnhancedPlayerConfiguration.logger` is nil: the unified system
    /// log, subsystem `EnhancedNativePlayer`, one category per `LogCategory`. Console.app shows
    /// it on a device without Xcode attached.
    static let systemDefault = Logging.Logger(label: "EnhancedNativePlayer") { SystemLogHandler(subsystem: $0) }

    /// This logger with its lines tagged as coming from `category`.
    func category(_ category: LogCategory) -> Logging.Logger {
        var logger = self
        logger[metadataKey: LogMetadata.category] = .string(category.rawValue)
        return logger
    }
}

enum LogMetadata {
    static let category = "category"
    /// A short random ID per playback session, on every line logged for it.
    static let session = "session"

    static func newSessionID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

/// A swift-log handler over `os.Logger`. The `category` metadata becomes the unified log's
/// category, the session ID leads the text and other metadata follows it as `key=value`.
/// Messages are public: they hold file names, segment numbers and errors, and `<private>`
/// would hide all of it in Console.app. Nothing the engine logs holds a header's value.
struct SystemLogHandler: LogHandler {
    let subsystem: String
    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata.merging(event.metadata ?? [:]) { $1 }
        let category = merged.removeValue(forKey: LogMetadata.category).map { "\($0)" } ?? "general"
        let session = merged.removeValue(forKey: LogMetadata.session).map { "[\($0)] " } ?? ""
        let rest = merged.isEmpty ? "" : " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let text = "\(session)\(event.message)\(rest)"
        let log = Self.logger(subsystem: subsystem, category: category)
        switch event.level {
        case .trace, .debug: log.debug("\(text, privacy: .public)")
        case .info: log.info("\(text, privacy: .public)")
        case .notice, .warning: log.notice("\(text, privacy: .public)")
        case .error: log.error("\(text, privacy: .public)")
        case .critical: log.fault("\(text, privacy: .public)")
        }
    }

    private static let loggers = Mutex<[String: os.Logger]>([:])

    private static func logger(subsystem: String, category: String) -> os.Logger {
        loggers.withLock { loggers in
            let key = "\(subsystem)/\(category)"
            if let logger = loggers[key] { return logger }
            let logger = os.Logger(subsystem: subsystem, category: category)
            loggers[key] = logger
            return logger
        }
    }
}

/// Lets a message that repeats through once per interval, and says how many were held back
/// in between: a decoder failing on every packet logs one line every few seconds, not one per
/// packet. Messages are told apart by a key the caller picks.
final class LogThrottle: Sendable {
    private let interval: Duration
    private let state = Mutex<[String: (last: ContinuousClock.Instant, held: Int)]>([:])

    init(interval: Duration = .seconds(10)) {
        self.interval = interval
    }

    /// Logs the message unless one with the same key went out less than an interval ago.
    func log(_ logger: Logging.Logger, _ level: Logging.Logger.Level, key: String, _ message: () -> String) {
        guard logger.logLevel <= level else { return }
        let now = ContinuousClock.now
        let held: Int? = state.withLock { state in
            if let entry = state[key], now - entry.last < interval {
                state[key]!.held += 1
                return nil
            }
            let held = state[key]?.held ?? 0
            state[key] = (now, 0)
            return held
        }
        guard let held else { return }
        let suffix = held > 0 ? " (\(held) more like it since the last)" : ""
        logger.log(level: level, "\(message())\(suffix)")
    }
}

/// libav*'s messages, which otherwise go to stderr and are lost without Xcode attached.
/// Warnings and worse go to the `ffmpeg` category of the session that started last: the
/// callback is the process's, not a session's. A message that repeats is throttled.
enum FFmpegLog {
    private static let current = Mutex<Logging.Logger?>(nil)
    private static let throttle = LogThrottle()
    private static let installed: Void = ep_log_install(AV_LOG_WARNING, sink)

    static func route(to logger: Logging.Logger) {
        current.withLock { $0 = logger.category(.ffmpeg) }
        _ = installed
    }

    private static let sink: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { level, line in
        guard let line, let logger = current.withLock({ $0 }) else { return }
        // The context's address ("[matroska,webm @ 0x1067a4c80]") differs per session and says nothing.
        let text = String(cString: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #" @ 0x[0-9a-f]+\]"#, with: "]", options: .regularExpression)
        guard !text.isEmpty else { return }
        let swiftLevel: Logging.Logger.Level = switch level {
        case ...AV_LOG_FATAL: .critical
        case ...AV_LOG_ERROR: .error
        default: .warning
        }
        // Expected for zlib-compressed PGS and ASS tracks, which the engine inflates itself.
        let expected = text.contains("Unsupported encoding type")
        throttle.log(logger, expected ? .debug : swiftLevel, key: text.filter { !$0.isNumber }) { text }
    }
}
