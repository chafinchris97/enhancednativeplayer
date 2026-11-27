import Foundation
import Logging

/// What a reader of the file is for, which decides how its reads are fetched.
enum ReadRole: Sendable, CustomStringConvertible {
    /// The probe and the init builders: headers and indexes, a few jumps each.
    case lookup
    /// The remux runs and the drawn video's decoder, which read on through the file and
    /// hand that reading to the prefetcher.
    case playback
    /// Subtitle reads, which wander behind and around the playhead.
    case subtitles

    var description: String {
        switch self {
        case .lookup: "lookup"
        case .playback: "playback"
        case .subtitles: "subtitles"
        }
    }
}

/// Random access to a remote file, one connection per reader plus a prefetcher.
///
/// The file is read in fixed-size blocks that are shared by every reader of the session:
/// the probe, the video remux, the audio remux and the init builders all demux the same
/// interleaved bytes, so a block fetched for one is a cache hit for the others. Recent
/// blocks stay in memory; older ones spill to disk up to a byte budget, which is what lets
/// the audio remux trail the video remux by a few segments without downloading the file twice.
///
/// Each connection is one request from a position to the end of the file, read only as far
/// ahead as needed and paused, by not reading, once it is. Each reader has its own, so a
/// jump to an index or a subtitle read never waits for another reader's connection to move.
/// Once a playback reader has read on for a few blocks, its connection becomes the
/// prefetcher, which reads further ahead than a reader's own connection does, and the
/// reader reads from the cache. The connection carries on rather than a new one opening:
/// a server slow to answer a new position would make each handover a stall of its own,
/// right after the one a seek already caused. A reader waits on any connection that is about
/// to bring the block it wants, whoever's it is, rather than fetch it twice.
///
/// Lookup and subtitle readers jump more than they read on, so their connections ask for
/// bounded ranges instead, starting at one block after a jump and growing as the reader reads
/// on. Each is kept open once its response is read, and the next range, wherever it is, goes
/// out on the same socket without a new handshake.
///
/// A connection a reader waits on that brings less than `trickleFloor` in `trickleWindow` is
/// replaced by a new one at the same place: a stalled route or an overloaded server node
/// often keeps a connection alive at a trickle while a new one gets full speed.
///
/// A server that answers 429 or 503 gets no new requests until its `Retry-After` has passed,
/// and from then on no more connections at once than it had open, less one. A reader waiting
/// on a block takes the place of a connection nobody waits on when the limit is reached.
///
/// After a redirect, later connections go straight to where it led, back to the file's own
/// URL if that stops working.
final class RemoteFile: @unchecked Sendable {
    let url: URL
    let length: Int64
    let blockSize: Int

    private let headers: [String: String]
    private let directory: URL
    private let logger: Logger
    private let queue: DispatchQueue
    private let maxDiskBlocks: Int
    private let maxMemoryBlocks = 16
    /// How far the prefetcher reads past the furthest block playback asked of it.
    private static let prefetchAhead = 64
    private var prefetchAhead: Int { Self.prefetchAhead }
    /// How far a reader's own connection reads past its furthest block, once the reader
    /// has shown it reads on; right after a jump it reads `firstReadAhead`.
    private let readerAhead = 8
    private let firstReadAhead = 2
    /// A block this close past a connection's position is waited for on it.
    private let reach = 16
    /// Blocks a playback reader reads on its own connection before it becomes the prefetcher.
    private let handOver = 4
    /// A connection paused this long is closed; it opens again when a reader needs it.
    private let idleClose = Duration.seconds(15)
    /// A connection a reader waits on that brings fewer bytes than this in a window is replaced.
    /// Set before the first read; tests shorten the window.
    var trickleWindow = Duration.seconds(20)
    var trickleFloor = 2 << 20
    /// The longest `Retry-After` waited for; a longer one is retried after this.
    private static let maxRetryAfter: TimeInterval = 60

    private let condition = NSCondition()
    private var memory: [Int: Data] = [:]
    private var memoryOrder: [Int] = []
    private var disk: [Int: UInt64] = [:]
    private var useClock: UInt64 = 0
    private var failures: [Int: Error] = [:]
    private var closed = false
    /// Where connections go: the file's URL, or where it last redirected to.
    private var target: URL
    /// How many connections the server takes at once, once it has throttled; nil until then.
    private var connectionLimit: Int?
    /// No connection opens before this, after the server asked to wait.
    private var holdUntil: ContinuousClock.Instant?

    /// One connection and where it reads. Guarded by `condition`.
    fileprivate final class Fetch: @unchecked Sendable {
        var name: String
        var maxAhead: Int
        /// Whether its read-ahead starts small after a move and grows with what's read.
        var ramps: Bool
        /// Whether it asks for bounded ranges on a kept-open socket instead of the rest of the file.
        let bounded: Bool
        var connection: RangeConnection?
        /// A bounded connection whose response was read to its end, kept for the next request.
        var idle: RangeConnection?
        /// The block after the last one its bounded range asked for.
        var requestEnd = 0
        /// When the throughput window opened, while a reader waits on it, and the bytes since.
        var windowStart: ContinuousClock.Instant?
        var windowBytes = 0
        /// Tells the current connection's callbacks from those of one already closed.
        var generation = 0
        /// The block it delivers next, or where it opens if it has no connection.
        var position = 0
        /// The bytes received so far of the block at `position`.
        var partial = Data()
        var connecting = false
        var reading = false
        var backingOff = false
        var attempt = 0
        /// Where it was last moved to, and the furthest block asked of it since; -1 when
        /// nothing has been.
        var runStart = 0
        var demand = -1
        var waiters = 0
        var pausedAt: ContinuousClock.Instant?
        var retired = false

        init(name: String, maxAhead: Int, ramps: Bool, bounded: Bool = false) {
            self.name = name
            self.maxAhead = maxAhead
            self.ramps = ramps
            self.bounded = bounded
        }
    }

    /// A reader's handle: its role and its own connection.
    final class Reader: @unchecked Sendable {
        let role: ReadRole
        /// Replaced by a new one when its connection becomes the prefetcher.
        fileprivate var fetch: Fetch

        fileprivate init(role: ReadRole, fetch: Fetch) {
            self.role = role
            self.fetch = fetch
        }
    }

    /// Replaced when a reader's connection becomes the prefetcher.
    private var prefetch: Fetch
    /// Every connection that may be reading: the prefetcher, each reader's, and the one
    /// `open` made to learn the length, which reads the start of the file for the probe.
    private var fetches: [Fetch]
    private var nextReader = 0

    private init(url: URL, length: Int64, blockSize: Int, headers: [String: String], directory: URL, diskBudget: Int64, queue: DispatchQueue, logger: Logger) {
        self.url = url
        self.target = url
        self.length = length
        self.blockSize = blockSize
        self.headers = headers
        self.directory = directory
        self.queue = queue
        self.logger = logger
        self.maxDiskBlocks = max(0, Int(diskBudget / Int64(blockSize)))
        prefetch = Fetch(name: "prefetch", maxAhead: Self.prefetchAhead, ramps: false)
        fetches = [prefetch]
    }

    var blockCount: Int { Int((length + Int64(blockSize) - 1) / Int64(blockSize)) }

    /// Opens a connection at the start of the file, which also yields its length.
    static func open(url: URL, headers: [String: String], directory: URL, blockSize: Int = 1 << 20, diskBudget: Int64, logger: Logger) async throws -> RemoteFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "ENP.source")
        let connection = RangeConnection(url: url, headers: headers, offset: 0, queue: queue)
        let head: RangeConnection.Head
        do {
            head = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.start { continuation.resume(with: $0) }
                }
            } onCancel: {
                connection.cancel()
            }
        } catch {
            connection.cancel()
            throw Self.playerError(error, url: url)
        }
        let file = RemoteFile(url: url, length: head.total, blockSize: blockSize, headers: headers, directory: directory, diskBudget: diskBudget, queue: queue, logger: logger)
        file.adopt(connection, answeredAt: head.url)
        return file
    }

    private static func playerError(_ error: Error, url: URL) -> Error {
        switch error {
        case RangeConnection.Failure.notPartial: EnhancedPlayerError.rangeRequestsUnsupported(url)
        case RangeConnection.Failure.status(let status): EnhancedPlayerError.http(status: status, url: url)
        case RangeConnection.Failure.throttled(let status, _): EnhancedPlayerError.http(status: status, url: url)
        case RangeConnection.Failure.cancelled: EnhancedPlayerError.cancelled
        default: EnhancedPlayerError.network(String(describing: error))
        }
    }

    private func adopt(_ connection: RangeConnection, answeredAt answered: URL) {
        condition.lock()
        defer { condition.unlock() }
        noteAnswered(answered)
        let start = Fetch(name: "start", maxAhead: readerAhead, ramps: true)
        start.connection = connection
        start.demand = 0
        fetches.append(start)
        logger.debug("Source connection \(start.name) opened at block 0")
        readNext(start, start.generation)
    }

    /// A handle for one reader, with its own connection. Close it when the reader is done.
    func makeReader(role: ReadRole) -> Reader {
        condition.lock()
        defer { condition.unlock() }
        nextReader += 1
        let fetch = Fetch(name: "\(role) \(nextReader)", maxAhead: readerAhead, ramps: true, bounded: role != .playback)
        let reader = Reader(role: role, fetch: fetch)
        fetches.append(reader.fetch)
        return reader
    }

    func closeReader(_ reader: Reader) {
        condition.lock()
        defer { condition.unlock() }
        retire(reader.fetch)
    }

    /// Returns block `index`, fetching it if needed. Blocks the calling thread.
    func block(_ index: Int, for reader: Reader, token: CancellationToken) throws -> Data {
        let asked = ContinuousClock.now
        /// Why the block wasn't in memory, for the slow-read log.
        var missed: String?
        var waitingOn: Fetch?
        condition.lock()
        defer {
            waitingOn?.waiters -= 1
            condition.unlock()
        }
        while true {
            if closed || token.isCancelled { throw EnhancedPlayerError.cancelled }
            if let data = memory[index] {
                touchMemory(index)
                readerReached(index, reader)
                logIfSlow(index, since: asked, missed)
                return data
            }
            if disk[index] != nil {
                useClock += 1
                disk[index] = useClock
                let reading = ContinuousClock.now
                if let data = try? Data(contentsOf: blockURL(index)) {
                    insertMemory(data, for: index)
                    readerReached(index, reader)
                    logIfSlow(index, since: asked, missed ?? "read from the disk cache in \(Self.ms(ContinuousClock.now - reading))")
                    return data
                }
                disk[index] = nil
            }
            if let error = failures.removeValue(forKey: index) { throw error }

            let fetch: Fetch
            if let bringing = fetches.first(where: { isBringing($0, index) }) {
                fetch = bringing
                fetch.demand = max(fetch.demand, index)
                if missed == nil {
                    missed = "waited on the \(fetch.name) connection \(index - fetch.position) blocks short of it"
                }
            } else {
                fetch = reader.fetch
                if missed == nil {
                    missed = fetch.connection == nil
                        ? "opened the \(fetch.name) connection at it"
                        : "moved the \(fetch.name) connection from block \(fetch.position)"
                }
                move(fetch, to: index, demand: index)
            }
            if fetch !== waitingOn {
                waitingOn?.waiters -= 1
                if fetch.waiters == 0 { fetch.windowStart = nil }
                fetch.waiters += 1
                waitingOn = fetch
            }
            if fetch === reader.fetch { handOverIfReadingOn(reader) }
            resume(fetch)
            replaceIfTrickling(fetch)
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
    }

    /// A reader waiting this long for a block is logged, with where the block came from.
    static let slowBlock = Duration.milliseconds(50)
    private let slowReads = LogThrottle(interval: .seconds(1))

    private func logIfSlow(_ index: Int, since asked: ContinuousClock.Instant, _ missed: String?) {
        let waited = ContinuousClock.now - asked
        guard waited > Self.slowBlock, let missed else { return }
        slowReads.log(logger, .warning, key: "slow") {
            let open = fetches.filter { $0.connection != nil }.count
            return "Source block \(index) took \(Self.ms(waited)) to read: \(missed); \(open) connections open, \(memory.count) blocks in memory, \(disk.count) on disk"
        }
    }

    private static func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }

    func close() {
        condition.lock()
        closed = true
        fetches.forEach(retire)
        fetches.removeAll()
        memory.removeAll()
        memoryOrder.removeAll()
        condition.broadcast()
        condition.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Where connections read (condition locked)

    private func isCached(_ index: Int) -> Bool {
        memory[index] != nil || disk[index] != nil
    }

    private func ahead(_ fetch: Fetch) -> Int {
        guard fetch.ramps else { return fetch.maxAhead }
        // A bounded range after a jump is the one block asked for, so it is read to its end,
        // and its socket free for the next one, by the time the reader jumps again.
        if fetch.bounded { return min(fetch.maxAhead, fetch.demand - fetch.runStart) }
        return min(fetch.maxAhead, max(firstReadAhead, fetch.demand - fetch.runStart + 1))
    }

    /// Whether the connection should be reading at its position.
    private func wantsMore(_ fetch: Fetch) -> Bool {
        guard !fetch.retired, fetch.demand >= 0, fetch.position < blockCount else { return false }
        return fetch.position <= fetch.demand + ahead(fetch)
    }

    /// Whether a reader wanting `index` should wait on this connection.
    private func isBringing(_ fetch: Fetch, _ index: Int) -> Bool {
        !fetch.retired && fetch.demand >= 0 && index >= fetch.position && index <= fetch.position + reach
    }

    /// A reader got block `index` from the cache. The next block it lacks, if close, should
    /// be on its way before the reader gets there.
    private func readerReached(_ index: Int, _ reader: Reader) {
        var next = index + 1
        while next < blockCount, next <= index + prefetchAhead, isCached(next) { next += 1 }
        guard next < blockCount, next <= index + prefetchAhead else { return }
        if let bringing = fetches.first(where: { isBringing($0, next) }) {
            bringing.demand = max(bringing.demand, index)
            if bringing === reader.fetch { handOverIfReadingOn(reader) }
            resume(bringing)
        } else if next - index <= readerAhead {
            // About to run out with nothing on the way: its own connection fetches the gap.
            move(reader.fetch, to: next, demand: next)
        }
    }

    /// Once a playback reader has read on for a few blocks on its own connection, that
    /// connection becomes the prefetcher and the reader gets a new one, unopened.
    ///
    /// The prefetcher stays as it is only if it brings the first block past the reader's
    /// connection that isn't cached. Blocks it read earlier may have been evicted since:
    /// after a restart behind the playhead, the reader is inside the stretch the prefetcher
    /// already passed, and a prefetcher left further on would leave the reader's own
    /// connection to fetch it all.
    private func handOverIfReadingOn(_ reader: Reader) {
        let own = reader.fetch
        guard reader.role == .playback, own.connection != nil, own.position - own.runStart >= handOver else { return }
        var missing = own.position + reach
        while missing < blockCount, missing < prefetch.position, isCached(missing) { missing += 1 }
        if missing >= blockCount || isBringing(prefetch, missing) { return }
        logger.debug("Source connection \(own.name) at block \(own.position) becomes the prefetcher")
        retire(prefetch)
        let fresh = Fetch(name: own.name, maxAhead: readerAhead, ramps: true)
        own.name = prefetch.name
        own.maxAhead = prefetchAhead
        own.ramps = false
        prefetch = own
        reader.fetch = fresh
        fetches.append(fresh)
        condition.broadcast()
    }

    private func move(_ fetch: Fetch, to index: Int, demand: Int) {
        if fetch.bounded, fetch.connection != nil, !fetch.connecting, fetch.partial.isEmpty, fetch.position >= fetch.requestEnd {
            // Its range has all arrived, though its end may not have been read: the socket is free.
            park(fetch)
        }
        if fetch.connection != nil, fetch.position != index {
            logger.debug("Source connection \(fetch.name) moved from block \(fetch.position) to \(index)")
        }
        if fetch.position != index || fetch.connection == nil { closeConnection(fetch) }
        fetch.position = index
        fetch.runStart = index
        fetch.demand = demand
        fetch.attempt = 0
        resume(fetch)
    }

    /// Reads on at the position, opening the connection there if it isn't open.
    private func resume(_ fetch: Fetch) {
        guard !closed, !fetch.backingOff else { return }
        if fetch.connection == nil {
            while fetch.position < blockCount, isCached(fetch.position) { fetch.position += 1 }
            guard wantsMore(fetch), mayOpen(fetch) else { return }
            open(fetch)
        } else if !fetch.connecting, !fetch.reading {
            // A bounded range is read to its end, which frees its socket for the next one.
            if wantsMore(fetch) || fetch.bounded {
                readNext(fetch, fetch.generation)
            } else {
                pause(fetch)
            }
        }
    }

    /// Whether the server's wait and connection limit let the connection open now.
    private func mayOpen(_ fetch: Fetch) -> Bool {
        if let holdUntil {
            guard ContinuousClock.now >= holdUntil else { return false }
            self.holdUntil = nil
        }
        guard let limit = connectionLimit else { return true }
        let open = fetches.filter { $0 !== fetch && $0.connection != nil }
        if open.count < limit { return true }
        guard fetch.waiters > 0, let spare = open.first(where: { $0.waiters == 0 }) else { return false }
        logger.debug("Source connection \(spare.name) closed for \(fetch.name), which a reader waits on, at the server's limit of \(limit)")
        closeConnection(spare)
        return true
    }

    private func open(_ fetch: Fetch) {
        fetch.generation += 1
        let id = fetch.generation
        let offset = Int64(fetch.position) * Int64(blockSize)
        var end: Int64?
        if fetch.bounded {
            let last = min(blockCount - 1, max(fetch.position, fetch.demand + ahead(fetch)))
            end = min(length, Int64(last + 1) * Int64(blockSize))
            fetch.requestEnd = last + 1
        }
        let reusing = fetch.idle
        fetch.idle = nil
        let connection = RangeConnection(url: target, headers: headers, offset: offset, end: end, reusing: reusing, queue: queue)
        fetch.connection = connection
        fetch.connecting = true
        fetch.partial = Data()
        fetch.pausedAt = nil
        logger.debug("Source connection \(fetch.name) opened at block \(fetch.position)")
        connection.start { [weak self, fetch] result in self?.opened(fetch, result, id: id) }
    }

    private func closeConnection(_ fetch: Fetch) {
        fetch.connection?.cancel()
        fetch.connection = nil
        fetch.generation += 1
        fetch.connecting = false
        fetch.reading = false
        fetch.backingOff = false
        fetch.pausedAt = nil
        fetch.partial = Data()
        fetch.windowStart = nil
    }

    /// Keeps a bounded connection whose response was read to its end for the next request.
    private func park(_ fetch: Fetch) {
        let connection = fetch.connection
        fetch.connection = nil
        closeConnection(fetch)
        fetch.idle?.cancel()
        fetch.idle = nil
        guard let connection else { return }
        guard connectionLimit == nil else { return connection.cancel() }
        fetch.idle = connection
        queue.asyncAfter(deadline: .now() + .seconds(Int(idleClose.components.seconds))) { [weak self, fetch, connection] in
            guard let self else { return }
            self.condition.lock()
            defer { self.condition.unlock() }
            guard fetch.idle === connection else { return }
            fetch.idle = nil
            connection.cancel()
        }
    }

    /// Replaces the connection a reader waits on if it has brought too little for a while.
    private func replaceIfTrickling(_ fetch: Fetch) {
        guard fetch.connection != nil, !fetch.connecting, !fetch.backingOff else {
            fetch.windowStart = nil
            return
        }
        let now = ContinuousClock.now
        guard let start = fetch.windowStart else {
            fetch.windowStart = now
            fetch.windowBytes = 0
            return
        }
        guard now - start >= trickleWindow else { return }
        let bytes = fetch.windowBytes
        fetch.windowStart = now
        fetch.windowBytes = 0
        guard bytes < trickleFloor else { return }
        logger.warning("Source connection \(fetch.name) at block \(fetch.position) brought \(bytes >> 10) KB in \(Self.ms(trickleWindow)) while a reader waited; replaced by a new one")
        closeConnection(fetch)
        resume(fetch)
    }

    private func retire(_ fetch: Fetch) {
        closeConnection(fetch)
        fetch.idle?.cancel()
        fetch.idle = nil
        fetch.retired = true
        fetches.removeAll { $0 === fetch }
    }

    private func readNext(_ fetch: Fetch, _ id: Int) {
        guard let connection = fetch.connection, id == fetch.generation, !fetch.reading else { return }
        fetch.reading = true
        fetch.pausedAt = nil
        connection.read { [weak self, fetch] result in self?.received(fetch, result, id: id) }
    }

    /// Far enough ahead: stop reading, and close the connection if it stays that way.
    private func pause(_ fetch: Fetch) {
        fetch.windowStart = nil
        guard fetch.pausedAt == nil else { return }
        let now = ContinuousClock.now
        fetch.pausedAt = now
        let id = fetch.generation
        queue.asyncAfter(deadline: .now() + .seconds(Int(idleClose.components.seconds))) { [weak self, fetch] in
            guard let self else { return }
            self.condition.lock()
            defer { self.condition.unlock() }
            guard id == fetch.generation, fetch.pausedAt == now, fetch.connection != nil else { return }
            self.logger.debug("Source connection \(fetch.name) idle at block \(fetch.position), closed")
            self.closeConnection(fetch)
        }
    }

    /// After a redirect, connections go straight to where it led.
    private func noteAnswered(_ answered: URL) {
        guard answered != target else { return }
        logger.debug("Source answered at \(answered.host ?? "another host") after a redirect; connections go there")
        target = answered
    }

    // MARK: - Connection callbacks (on the queue)

    private func opened(_ fetch: Fetch, _ result: Result<RangeConnection.Head, Error>, id: Int) {
        condition.lock()
        defer { condition.unlock() }
        guard id == fetch.generation, !closed else { return }
        fetch.connecting = false
        switch result {
        case .success(let head):
            if head.total != length {
                logger.warning("Source length changed from \(length) to \(head.total) bytes")
            }
            noteAnswered(head.url)
            resume(fetch)
        case .failure(let error):
            failed(fetch, error)
        }
    }

    private func received(_ fetch: Fetch, _ result: Result<Data?, Error>, id: Int) {
        condition.lock()
        defer { condition.unlock() }
        guard id == fetch.generation, !closed else { return }
        fetch.reading = false
        switch result {
        case .success(let data?):
            fetch.attempt = 0
            fetch.windowBytes += data.count
            take(data, into: fetch)
            condition.broadcast()
            if !fetch.bounded, fetch.connection != nil, fetch.partial.isEmpty, fetch.position < blockCount, isCached(fetch.position) {
                // It reached blocks another connection brought: read on past them, not through them.
                // A bounded range is short and reads on to its end instead, which keeps its socket.
                closeConnection(fetch)
                resume(fetch)
            } else {
                resume(fetch)
            }
        case .success(nil) where fetch.bounded:
            // The range was read to its end; the next one goes out on the same socket.
            park(fetch)
            resume(fetch)
        case .success(nil):
            if fetch.position < blockCount {
                failed(fetch, RangeConnection.Failure.closedEarly)
            } else {
                closeConnection(fetch)
            }
        case .failure(let error):
            failed(fetch, error)
        }
    }

    /// Splits received bytes into blocks. Each byte is copied once, into the block it
    /// belongs to: re-copying what's left of the data after every block would cost a copy
    /// of the remainder per block.
    private func take(_ data: Data, into fetch: Fetch) {
        var offset = data.startIndex
        while fetch.position < blockCount, offset < data.endIndex {
            let size = blockLength(fetch.position)
            let count = min(size - fetch.partial.count, data.endIndex - offset)
            if fetch.partial.isEmpty, count == size {
                store(data.subdata(in: offset..<offset + count), for: fetch.position)
            } else {
                if fetch.partial.isEmpty { fetch.partial.reserveCapacity(size) }
                fetch.partial.append(data[offset..<offset + count])
                guard fetch.partial.count == size else { break }
                store(fetch.partial, for: fetch.position)
                fetch.partial = Data()
            }
            offset += count
            fetch.position += 1
        }
    }

    private func failed(_ fetch: Fetch, _ error: Error) {
        closeConnection(fetch)
        let reason = String(describing: error)
        guard fetch.waiters > 0 || wantsMore(fetch) else {
            // It had read far enough ahead and nobody waits on it: a server drops a
            // response it can't send for a while. Opened again when a reader needs it.
            logger.debug("Source connection \(fetch.name) at block \(fetch.position) closed (\(reason)), idle")
            return
        }
        // Where a redirect led may stop working, as signed links expire: go back to the file's URL.
        if case RangeConnection.Failure.status(let status) = error, (400..<500).contains(status), target != url {
            logger.notice("Source redirect target answered HTTP \(status); going back to the file's URL")
            target = url
            resume(fetch)
            return
        }
        // A client error won't clear up by retrying; anything else (a slow or briefly
        // unreachable server, a timeout, a 5xx) is retried for as long as it's wanted.
        let permanent: Bool
        switch error {
        case RangeConnection.Failure.status(let status): permanent = (400..<500).contains(status) && status != 408 && status != 429
        case RangeConnection.Failure.notPartial, RangeConnection.Failure.unsupportedURL, RangeConnection.Failure.tooManyRedirects: permanent = true
        default: permanent = false
        }
        if permanent, fetch.attempt >= 3 {
            logger.error("Source block \(fetch.position) failed after \(fetch.attempt + 1) attempts: \(reason)")
            failures[fetch.position] = Self.playerError(error, url: url)
            condition.broadcast()
            return
        }
        var delay = min(0.5 * Double(1 << min(fetch.attempt, 4)), 8)
        if case RangeConnection.Failure.throttled(let status, let retryAfter) = error {
            noteThrottled(status: status, retryAfter: retryAfter)
            if let retryAfter { delay = max(delay, min(retryAfter, Self.maxRetryAfter)) }
        }
        fetch.attempt += 1
        fetch.backingOff = true
        let id = fetch.generation
        logger.warning("Source connection \(fetch.name) at block \(fetch.position) attempt \(fetch.attempt) failed (\(reason)), retrying in \(delay) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self, fetch] in
            guard let self else { return }
            self.condition.lock()
            defer { self.condition.unlock() }
            guard id == fetch.generation else { return }
            fetch.backingOff = false
            self.resume(fetch)
        }
    }

    /// The server asked for fewer or later requests: nothing opens before its `Retry-After`,
    /// and never more connections at once than were open when it asked, less one.
    private func noteThrottled(status: Int, retryAfter: TimeInterval?) {
        if let retryAfter {
            let until = ContinuousClock.now + .milliseconds(Int(min(retryAfter, Self.maxRetryAfter) * 1000))
            holdUntil = max(holdUntil ?? until, until)
        }
        // The connection it refused is closed by now; it counts as one of those it had.
        let open = fetches.filter { $0.connection != nil }.count + 1
        let limit = max(1, open - 1)
        if limit < connectionLimit ?? .max {
            connectionLimit = limit
            logger.notice("Source server answered HTTP \(status) with \(open) connections open; at most \(limit) from now on")
        }
        for fetch in fetches {
            fetch.idle?.cancel()
            fetch.idle = nil
        }
    }

    // MARK: - Cache (condition locked)

    private func blockLength(_ index: Int) -> Int {
        Int(min(Int64(blockSize), length - Int64(index) * Int64(blockSize)))
    }

    private func store(_ data: Data, for index: Int) {
        guard !isCached(index) else { return }
        insertMemory(data, for: index)
        guard maxDiskBlocks > 0 else { return }
        if (try? data.write(to: blockURL(index))) != nil {
            useClock += 1
            disk[index] = useClock
            evictDisk()
        }
    }

    private func insertMemory(_ data: Data, for index: Int) {
        memory[index] = data
        touchMemory(index)
        while memoryOrder.count > maxMemoryBlocks {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private func touchMemory(_ index: Int) {
        if let position = memoryOrder.lastIndex(of: index) { memoryOrder.remove(at: position) }
        memoryOrder.append(index)
    }

    private func evictDisk() {
        guard disk.count > maxDiskBlocks else { return }
        let victims = disk.sorted { $0.value < $1.value }.prefix(disk.count - maxDiskBlocks)
        for (index, _) in victims {
            disk[index] = nil
            try? FileManager.default.removeItem(at: blockURL(index))
        }
    }

    private func blockURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(index).block")
    }
}

/// One reader's position in a `RemoteFile`, the opaque behind a custom `AVIOContext`.
/// Its connection closes with it.
final class RemoteCursor {
    let file: RemoteFile
    let token: CancellationToken
    private let reader: RemoteFile.Reader
    private(set) var position: Int64 = 0
    private var currentIndex = -1
    private var current = Data()

    init(file: RemoteFile, token: CancellationToken, role: ReadRole) {
        self.file = file
        self.token = token
        reader = file.makeReader(role: role)
    }

    deinit { file.closeReader(reader) }

    /// Fills `buffer`, returning bytes read, `AVERROR_EOF`, or a negative error.
    func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int32 {
        if token.isCancelled { return FF.errorExit }
        if position >= file.length { return FF.errorEOF }
        let index = Int(position / Int64(file.blockSize))
        do {
            if index != currentIndex {
                current = try file.block(index, for: reader, token: token)
                currentIndex = index
            }
        } catch EnhancedPlayerError.cancelled {
            return FF.errorExit
        } catch {
            return -EIO
        }
        let offset = Int(position - Int64(index) * Int64(file.blockSize))
        let count = min(capacity, current.count - offset)
        guard count > 0 else { return FF.errorEOF }
        current.withUnsafeBytes { raw in
            buffer.update(from: raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: count)
        }
        position += Int64(count)
        return Int32(count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        let mode = whence & ~FF.seekForce
        if mode == FF.seekSize { return file.length }
        let target: Int64
        switch mode {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = file.length + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }
}
