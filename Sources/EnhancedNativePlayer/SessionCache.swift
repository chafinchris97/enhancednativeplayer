import Foundation
import Logging

/// A session's working directory, `<base>/<UUID>/`, and the lock that marks it as in use.
///
/// The lock is `<base>/<UUID>.lock`, held with `flock` for as long as the session runs. The
/// kernel drops it when the process ends, however it ends, so a directory whose lock can be
/// taken belongs to a session that is gone: one stopped by a crash, a reinstall or the system
/// ending the app never got to delete its directory. `removeStale(in:)` deletes those.
///
/// The lock sits beside the directory, not inside it, and is taken before the directory is
/// made, so a sweep never sees a new session's directory without its lock.
final class SessionDirectory: Sendable {
    let url: URL
    private let lockURL: URL
    private let descriptor: Mutex<Int32>

    init(base: URL) throws {
        let name = UUID().uuidString
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        lockURL = base.appendingPathComponent(name + SessionCache.lockSuffix)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockURL.path]) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        descriptor = Mutex(fd)
        url = base.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            remove()
            throw error
        }
    }

    /// Deletes the directory, then lets go of the lock. Later calls do nothing.
    func remove() {
        descriptor.withLock { fd in
            guard fd >= 0 else { return }
            try? FileManager.default.removeItem(at: url)
            unlink(lockURL.path)
            close(fd)
            fd = -1
        }
    }

    deinit { remove() }
}

enum SessionCache {
    static let lockSuffix = ".lock"

    static func base(for configuration: EnhancedPlayerConfiguration) -> URL {
        configuration.cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EnhancedNativePlayer", isDirectory: true)
    }

    /// Deletes what sessions that are no longer running left in `base`: each `<UUID>/` whose
    /// lock nobody holds, and stray `<UUID>.lock` files. Anything not named for a session is
    /// left alone, so a `cacheDirectory` shared with other files keeps them.
    ///
    /// - Returns: How many sessions' files were deleted.
    @discardableResult
    static func removeStale(in base: URL, logger: Logger? = nil) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return 0 }
        let names = Set(entries.compactMap { entry -> String? in
            let name = entry.hasSuffix(lockSuffix) ? String(entry.dropLast(lockSuffix.count)) : entry
            return UUID(uuidString: name) != nil ? name : nil
        })
        var removed = 0
        for name in names {
            let directory = base.appendingPathComponent(name, isDirectory: true)
            let lockPath = base.appendingPathComponent(name + lockSuffix).path
            let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            // Held: that session is running, in this process or another.
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                    removed += 1
                } catch {
                    logger?.warning("Could not delete the leftover session directory \(name): \(error.localizedDescription)")
                    continue
                }
            }
            unlink(lockPath)
        }
        if removed > 0 { logger?.notice("Deleted \(removed) session director\(removed == 1 ? "y" : "ies") left by playback that did not stop") }
        return removed
    }
}
