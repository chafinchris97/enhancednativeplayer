import Foundation

/// Thread-safe cancellation flag shared between async code and the blocking FFmpeg threads.
/// A child token reports cancelled as soon as its parent is.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let parent: CancellationToken?

    init(parent: CancellationToken? = nil) {
        self.parent = parent
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value || (parent?.isCancelled ?? false)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        if isCancelled { throw EnhancedPlayerError.cancelled }
    }
}

/// Runs blocking work (FFmpeg) off the Swift concurrency pool.
func runBlocking<T: Sendable>(label: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            continuation.resume(with: Result { try body() })
        }
        thread.name = label
        thread.stackSize = 4 << 20
        thread.start()
    }
}
