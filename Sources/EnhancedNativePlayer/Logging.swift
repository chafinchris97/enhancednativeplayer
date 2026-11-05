import Foundation
import Logging
import os

extension Logging.Logger {
    /// The library's logger. It writes to the unified system log (subsystem
    /// `EnhancedNativePlayer`), so Console.app shows it on a device without Xcode attached.
    static let player: Logging.Logger = {
        var logger = Logging.Logger(label: "EnhancedNativePlayer") { label in
            SystemLogHandler(log: os.Logger(subsystem: label, category: "player"))
        }
        logger.logLevel = .info
        return logger
    }()
}

/// A swift-log handler over `os.Logger`. Messages are public: they hold file names,
/// segment numbers and errors, and `<private>` would hide all of it in Console.app.
struct SystemLogHandler: LogHandler {
    let log: os.Logger
    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        let text = merged.isEmpty
            ? "\(event.message)"
            : "\(event.message) \(merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
        switch event.level {
        case .trace, .debug: log.debug("\(text, privacy: .public)")
        case .info: log.info("\(text, privacy: .public)")
        case .notice, .warning: log.notice("\(text, privacy: .public)")
        case .error: log.error("\(text, privacy: .public)")
        case .critical: log.fault("\(text, privacy: .public)")
        }
    }
}
