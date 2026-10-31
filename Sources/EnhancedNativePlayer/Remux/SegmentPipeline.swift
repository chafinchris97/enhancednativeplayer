import Foundation
import Logging

/// Something that writes segments for one run, on the run's own thread.
protocol SegmentProducer: Sendable {
    func produce(_ run: RemuxRun) throws
}

/// One remux pass from `startSegment` forward. Lives on a dedicated thread.
final class RemuxRun: @unchecked Sendable {
    let id: UInt64
    let track: Int
    let startSegment: Int
    let directory: URL
    let token: CancellationToken
    private weak var pipeline: SegmentPipeline?

    fileprivate init(id: UInt64, track: Int, startSegment: Int, directory: URL, token: CancellationToken, pipeline: SegmentPipeline) {
        self.id = id
        self.track = track
        self.startSegment = startSegment
        self.directory = directory
        self.token = token
        self.pipeline = pipeline
    }

    /// Stores a finished segment and hands it to any waiting request.
    func publish(segment: Int, data: Data) throws {
        try token.throwIfCancelled()
        guard let pipeline else { throw EnhancedPlayerError.cancelled }
        let url = directory.appendingPathComponent(pipeline.fileName(segment: segment, track: track))
        let temporary = url.appendingPathExtension("partial")
        try data.write(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: url)
        pipeline.runDidPublish(self, segment: segment, file: url)
    }

    /// Blocks while `segment` would be more than `segmentsAhead` past the newest request.
    func waitForWindow(before segment: Int) throws {
        guard let pipeline else { throw EnhancedPlayerError.cancelled }
        try pipeline.waitForWindow(self, segment: segment)
    }
}

/// Serves segments of one kind (video, or the selected audio track) and drives the
/// remux run behind them.
///
/// - A request for a segment that is ready is answered from the cache; the handler
///   deletes the file once it is sent.
/// - A request within `segmentsAhead` of the segment being written waits for it, and
///   moves the window so a paused run resumes.
/// - Anything else (a seek past the window, a segment already sent, a different
///   audio track) stops the run, deletes its segments and starts a new run there.
final class SegmentPipeline: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let track: Int
        let continuation: CheckedContinuation<URL, Error>
    }

    let name: String
    private let directory: URL
    private let segmentCount: Int
    private let segmentsAhead: Int
    private let producer: @Sendable (Int) -> SegmentProducer
    private let fileNamer: @Sendable (Int, Int) -> String
    private let parentToken: CancellationToken
    private let logger: Logger

    private let condition = NSCondition()
    private var run: RemuxRun?
    private var track = 0
    private var producing = 0
    private var latest = -1
    private var runEnded = false
    private var runError: Error?
    private var ready: [Int: URL] = [:]
    private var waiters: [Int: [Waiter]] = [:]
    private var nextID: UInt64 = 0
    private var stopped = false

    init(
        name: String,
        directory: URL,
        segmentCount: Int,
        segmentsAhead: Int,
        token: CancellationToken,
        logger: Logger,
        fileName: @escaping @Sendable (_ segment: Int, _ track: Int) -> String,
        producer: @escaping @Sendable (_ track: Int) -> SegmentProducer
    ) {
        self.name = name
        self.directory = directory
        self.segmentCount = segmentCount
        self.segmentsAhead = segmentsAhead
        self.parentToken = token
        self.logger = logger
        self.fileNamer = fileName
        self.producer = producer
    }

    func fileName(segment: Int, track: Int) -> String { fileNamer(segment, track) }

    /// Returns the file for `segment`, starting or restarting the remux as needed.
    /// The caller sends it and then calls `didSend(_:)`.
    func segment(_ index: Int, track requestedTrack: Int = 0) async throws -> URL {
        guard index >= 0, index < segmentCount else { throw EnhancedPlayerError.segmentOutOfRange(index) }
        let waiterID = nextWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                condition.lock()
                defer { condition.unlock() }
                if stopped {
                    continuation.resume(throwing: EnhancedPlayerError.cancelled)
                    return
                }
                if run != nil, requestedTrack != track {
                    logger.info("\(name): track \(track) → \(requestedTrack), restarting at \(index)")
                    restart(at: index, track: requestedTrack)
                } else if let url = ready.removeValue(forKey: index) {
                    advance(to: index)
                    continuation.resume(returning: url)
                    return
                } else if needsRestart(for: index) {
                    logger.info("\(name): segment \(index) is outside the window (producing \(producing)), restarting")
                    restart(at: index, track: requestedTrack)
                } else {
                    advance(to: index)
                }
                waiters[index, default: []].append(Waiter(id: waiterID, track: requestedTrack, continuation: continuation))
            }
        } onCancel: {
            cancelWaiter(waiterID, segment: index)
        }
    }

    /// A segment response ended. Once the player has the bytes the file is deleted;
    /// if the send broke off, the segment goes back to the cache for the retry.
    func didFinishSending(_ url: URL, segment: Int, delivered: Bool) {
        if !delivered {
            condition.lock()
            let current = run.map { url.deletingLastPathComponent().standardizedFileURL == $0.directory.standardizedFileURL } ?? false
            if current, !stopped, ready[segment] == nil, FileManager.default.fileExists(atPath: url.path) {
                ready[segment] = url
                condition.unlock()
                return
            }
            condition.unlock()
        }
        try? FileManager.default.removeItem(at: url)
    }

    func stop() {
        condition.lock()
        stopped = true
        run?.token.cancel()
        run = nil
        for url in ready.values { try? FileManager.default.removeItem(at: url) }
        ready.removeAll()
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        pending.forEach { $0.continuation.resume(throwing: EnhancedPlayerError.cancelled) }
    }

    // MARK: - Called by runs (run thread)

    fileprivate func runDidPublish(_ run: RemuxRun, segment: Int, file: URL) {
        condition.lock()
        guard run.id == self.run?.id else {
            condition.unlock()
            try? FileManager.default.removeItem(at: file)
            return
        }
        producing = segment + 1
        let pending = waiters.removeValue(forKey: segment) ?? []
        if pending.isEmpty { ready[segment] = file }
        condition.broadcast()
        condition.unlock()
        logger.debug("\(name): segment \(segment) ready")
        // Duplicate requests for one segment share the file; the first send deletes it,
        // and an open file stays readable after unlink.
        pending.forEach { $0.continuation.resume(returning: file) }
    }

    fileprivate func waitForWindow(_ run: RemuxRun, segment: Int) throws {
        condition.lock()
        defer { condition.unlock() }
        if run.id == self.run?.id { producing = segment }
        while !run.token.isCancelled, run.id == self.run?.id, segment > latest + segmentsAhead {
            _ = condition.wait(until: Date().addingTimeInterval(0.5))
        }
        try run.token.throwIfCancelled()
    }

    private func runDidEnd(_ run: RemuxRun, error: Error?) {
        condition.lock()
        var failed: [Waiter] = []
        if run.id == self.run?.id {
            runEnded = true
            if let error, !(error is CancellationError), !isCancellation(error) {
                runError = error
                logger.error("\(name): remux failed: \(error.localizedDescription)")
            }
            // Nothing will produce the segments still awaited from this run.
            failed = waiters.values.flatMap { $0 }
            waiters.removeAll()
        } else {
            try? FileManager.default.removeItem(at: run.directory)
        }
        condition.broadcast()
        condition.unlock()
        let reason = error.flatMap { isCancellation($0) ? nil : $0 } ?? EnhancedPlayerError.segmentOutOfRange(-1)
        failed.forEach { $0.continuation.resume(throwing: reason) }
    }

    // MARK: - Private (condition locked)

    private func needsRestart(for index: Int) -> Bool {
        guard run != nil, !runEnded, runError == nil else { return true }
        return index < producing || index > producing + segmentsAhead
    }

    private func advance(to index: Int) {
        latest = max(latest, index)
        // Segments the player skipped over are stale; keep one behind for out-of-order fetches.
        for (segment, url) in ready where segment < index - 1 {
            try? FileManager.default.removeItem(at: url)
            ready[segment] = nil
        }
        condition.broadcast()
    }

    private func restart(at index: Int, track newTrack: Int) {
        run?.token.cancel()
        for url in ready.values { try? FileManager.default.removeItem(at: url) }
        ready.removeAll()

        // Requests that the new run will not answer are failed now.
        var keep: [Int: [Waiter]] = [:]
        var dropped: [Waiter] = []
        for (segment, list) in waiters {
            for waiter in list {
                if waiter.track == newTrack, segment >= index, segment <= index + segmentsAhead {
                    keep[segment, default: []].append(waiter)
                } else {
                    dropped.append(waiter)
                }
            }
        }
        waiters = keep
        dropped.forEach { $0.continuation.resume(throwing: EnhancedPlayerError.cancelled) }

        nextID += 1
        let runDirectory = directory.appendingPathComponent("run-\(nextID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let newRun = RemuxRun(id: nextID, track: newTrack, startSegment: index, directory: runDirectory, token: CancellationToken(parent: parentToken), pipeline: self)
        run = newRun
        track = newTrack
        producing = index
        latest = index
        runEnded = false
        runError = nil

        let producer = producer(newTrack)
        let thread = Thread { [weak self] in
            var failure: Error?
            do { try producer.produce(newRun) } catch { failure = error }
            self?.runDidEnd(newRun, error: failure)
        }
        thread.name = "ENP.\(name).run-\(nextID)"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private var waiterCounter: UInt64 = 0

    private func nextWaiterID() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        waiterCounter += 1
        return waiterCounter
    }

    private func cancelWaiter(_ id: UInt64, segment: Int) {
        condition.lock()
        var cancelled: Waiter?
        if var list = waiters[segment], let position = list.firstIndex(where: { $0.id == id }) {
            cancelled = list.remove(at: position)
            waiters[segment] = list.isEmpty ? nil : list
        }
        condition.unlock()
        cancelled?.continuation.resume(throwing: CancellationError())
    }

    private func isCancellation(_ error: Error) -> Bool {
        if case EnhancedPlayerError.cancelled = error { return true }
        return error is CancellationError
    }
}
