import Foundation
import Testing
@testable import EnhancedNativePlayer

struct SessionCacheTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("enp-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A killed process leaves its directory (older builds, without a lock file, too) and its
    /// unheld lock; both go. A running session and files not named for a session stay.
    @Test func sweepDeletesOnlyStoppedSessions() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let orphan = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan.appendingPathComponent("source"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: orphan.appendingPathComponent("source/0.block"))

        let killedName = UUID().uuidString
        let killed = base.appendingPathComponent(killedName, isDirectory: true)
        try FileManager.default.createDirectory(at: killed, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: base.appendingPathComponent(killedName + ".lock").path, contents: nil)

        let strayLock = base.appendingPathComponent(UUID().uuidString + ".lock")
        FileManager.default.createFile(atPath: strayLock.path, contents: nil)

        let other = base.appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherFile = base.appendingPathComponent("settings.plist")
        FileManager.default.createFile(atPath: otherFile.path, contents: Data([0]))

        let running = try SessionDirectory(base: base)
        defer { running.remove() }
        try Data([4]).write(to: running.url.appendingPathComponent("segment.mp4"))

        #expect(SessionCache.removeStale(in: base) == 2)
        #expect(!exists(orphan))
        #expect(!exists(killed))
        #expect(!exists(base.appendingPathComponent(killedName + ".lock")))
        #expect(!exists(strayLock))
        #expect(exists(running.url.appendingPathComponent("segment.mp4")))
        #expect(exists(other))
        #expect(exists(otherFile))
    }

    /// A stopped session leaves nothing; its directory is then free for a sweep to ignore.
    @Test func removeDeletesDirectoryAndLock() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let session = try SessionDirectory(base: base)
        try Data([1]).write(to: session.url.appendingPathComponent("segment.mp4"))
        session.remove()
        session.remove()
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    /// Two sessions in one process each hold their own lock.
    @Test func sessionsInOneProcessKeepEachOthersFiles() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try SessionDirectory(base: base)
        let second = try SessionDirectory(base: base)
        defer { first.remove(); second.remove() }
        #expect(SessionCache.removeStale(in: base) == 0)
        #expect(exists(first.url) && exists(second.url))

        first.remove()
        #expect(SessionCache.removeStale(in: base) == 0)
        #expect(!exists(first.url) && exists(second.url))
    }

    #if canImport(UIKit) && !os(watchOS)
    @Test func publicCleanupUsesTheConfiguredDirectory() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let orphan = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        var configuration = EnhancedPlayerConfiguration()
        configuration.cacheDirectory = base
        await EnhancedPlayer.removeCachedFiles(configuration: configuration)
        #expect(!exists(orphan))
    }
    #endif
}
