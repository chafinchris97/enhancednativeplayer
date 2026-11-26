import Foundation
import Logging

/// Random access to a remote file through HTTP range requests.
///
/// The file is read in fixed-size blocks that are shared by every reader of the session:
/// the probe, the video remux, the audio remux and the init builders all demux the same
/// interleaved bytes, so a block fetched for one is a cache hit for the others. Recent
/// blocks stay in memory; older ones spill to disk up to a byte budget, which is what lets
/// the audio remux trail the video remux by a few segments without downloading the file twice.
///
/// Blocks arrive through a few sequential streams rather than one request each, the way
/// a media player reads a file: a stream starts where a reader asked, reads ahead of the
/// furthest block asked of it in requests that grow from a couple of blocks (a probe's
/// jump) to many (playback), and pauses once it is far enough ahead. Hosts that ration
/// connections, as CDNs often do, refuse a client that opens many short ones.
final class RemoteFile: @unchecked Sendable {
    let url: URL
    let length: Int64
    let blockSize: Int

    private let session: URLSession
    private let headers: [String: String]
    private let directory: URL
    private let logger: Logger
    private let maxDiskBlocks: Int
    private let maxMemoryBlocks = 16
    /// Streams, and so connections to the source, open at once.
    static let maxStreams = 2
    /// How far a stream reads past the furthest block asked of it before pausing.
    private let readAhead = 32
    /// A block this close past a stream's frontier is waited for instead of opening another stream.
    private let reach = 8
    /// Blocks in a stream's first request, and the most in one; each request doubles the last.
    private let firstChunk = 2
    private let maxChunk = 32
    /// A failed stream is retried while a reader waits on it or asked of it this recently.
    private let wantedFor = Duration.seconds(10)

    private let condition = NSCondition()
    private var memory: [Int: Data] = [:]
    private var memoryOrder: [Int] = []
    private var disk: [Int: UInt64] = [:]
    private var useClock: UInt64 = 0
    private var failures: [Int: Error] = [:]
    private var streams: [Stream] = []
    private var tasks: [Int: Stream] = [:]
    private var closed = false

    /// One sequential read of the file, a request at a time.
    /// Guarded by `condition`, like the rest of the file's state.
    private final class Stream: @unchecked Sendable {
        /// The next block it delivers.
        var frontier: Int
        /// The furthest block asked of it.
        var demand: Int
        var lastUse: ContinuousClock.Instant
        var waiters = 0
        var task: URLSessionDataTask?
        /// The block the current request ends before.
        var end = 0
        var partial = Data()
        var failedStatus: Int?
        var chunk: Int
        var attempt = 0
        var backingOff = false
        var cancelled = false

        init(at index: Int, chunk: Int) {
            frontier = index
            demand = index
            lastUse = .now
            self.chunk = chunk
        }

        var busy: Bool { task != nil || backingOff }
    }

    private init(url: URL, length: Int64, blockSize: Int, session: URLSession, headers: [String: String], directory: URL, diskBudget: Int64, logger: Logger) {
        self.url = url
        self.length = length
        self.blockSize = blockSize
        self.session = session
        self.headers = headers
        self.directory = directory
        self.logger = logger
        self.maxDiskBlocks = max(0, Int(diskBudget / Int64(blockSize)))
    }

    var blockCount: Int { Int((length + Int64(blockSize) - 1) / Int64(blockSize)) }

    /// Opens the file with a range request for the first block, which also yields its length.
    static func open(url: URL, headers: [String: String], directory: URL, blockSize: Int = 1 << 20, diskBudget: Int64, logger: Logger) async throws -> RemoteFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxStreams
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let delegate = SessionDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ENP.source"
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)

        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(blockSize - 1)", forHTTPHeaderField: "Range")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            session.invalidateAndCancel()
            throw EnhancedPlayerError.network("not an HTTP response")
        }
        guard http.statusCode == 206 else {
            session.invalidateAndCancel()
            if (200..<300).contains(http.statusCode) { throw EnhancedPlayerError.rangeRequestsUnsupported(url) }
            throw EnhancedPlayerError.http(status: http.statusCode, url: url)
        }
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else {
            session.invalidateAndCancel()
            throw EnhancedPlayerError.rangeRequestsUnsupported(url)
        }
        let file = RemoteFile(url: url, length: total, blockSize: blockSize, session: session, headers: headers, directory: directory, diskBudget: diskBudget, logger: logger)
        delegate.file = file
        file.seed(data)
        return file
    }

    private func seed(_ data: Data) {
        condition.lock()
        store(data, for: 0)
        condition.unlock()
    }

    /// Returns block `index`, fetching it if needed. Blocks the calling thread.
    func block(_ index: Int, token: CancellationToken) throws -> Data {
        let asked = ContinuousClock.now
        /// Why the block wasn't in memory, for the slow-read log.
        var missed: String?
        /// The stream this reader waits on.
        var waitingOn: Stream?
        condition.lock()
        defer {
            waitingOn?.waiters -= 1
            condition.unlock()
        }
        while true {
            if closed || token.isCancelled { throw EnhancedPlayerError.cancelled }
            touch(index)
            if let data = memory[index] {
                touchMemory(index)
                logIfSlow(index, since: asked, missed)
                return data
            }
            if disk[index] != nil {
                useClock += 1
                disk[index] = useClock
                let reading = ContinuousClock.now
                if let data = try? Data(contentsOf: blockURL(index)) {
                    insertMemory(data, for: index)
                    logIfSlow(index, since: asked, missed ?? "read from the disk cache in \(Self.ms(ContinuousClock.now - reading))")
                    return data
                }
                disk[index] = nil
            }
            if let error = failures.removeValue(forKey: index) { throw error }
            let stream: Stream
            if let reaching = streams.first(where: { index >= $0.frontier && index <= $0.frontier + reach }) {
                stream = reaching
                if missed == nil {
                    missed = "waited on the stream \(index - reaching.frontier) blocks short of it (\(streams.count) open)"
                }
            } else {
                stream = openStream(at: index)
                if missed == nil { missed = "no stream was reading near it, opened one (\(streams.count) open)" }
            }
            if stream !== waitingOn {
                waitingOn?.waiters -= 1
                stream.waiters += 1
                waitingOn = stream
            }
            pump(stream)
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
            "Source block \(index) took \(Self.ms(waited)) to read: \(missed); \(memory.count) blocks in memory, \(disk.count) on disk"
        }
    }

    private static func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }

    func close() {
        condition.lock()
        closed = true
        let open = streams
        streams.removeAll()
        tasks.removeAll()
        memory.removeAll()
        memoryOrder.removeAll()
        condition.broadcast()
        condition.unlock()
        open.forEach { $0.task?.cancel() }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Session callbacks (on the session's serial queue)

    fileprivate func received(_ response: URLResponse, for task: URLSessionDataTask) -> URLSession.ResponseDisposition {
        condition.lock()
        defer { condition.unlock() }
        guard let stream = tasks[task.taskIdentifier] else { return .allow }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 206 else {
            stream.failedStatus = status
            return .cancel
        }
        return .allow
    }

    fileprivate func received(_ data: Data, for task: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        guard let stream = tasks[task.taskIdentifier], stream.task === task else { return }
        stream.partial.append(data)
        stream.attempt = 0
        var delivered = false
        while stream.frontier < stream.end {
            let size = blockLength(stream.frontier)
            guard stream.partial.count >= size else { break }
            store(Data(stream.partial.prefix(size)), for: stream.frontier)
            stream.partial = Data(stream.partial.dropFirst(size))
            stream.frontier += 1
            delivered = true
        }
        if delivered { condition.broadcast() }
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard let stream = tasks.removeValue(forKey: task.taskIdentifier), stream.task === task else { return }
        stream.task = nil
        stream.partial = Data()
        guard !closed, !stream.cancelled else { return }
        let status = stream.failedStatus
        stream.failedStatus = nil
        if error == nil, status == nil, stream.frontier >= stream.end {
            stream.chunk = min(maxChunk, stream.chunk * 2)
            pump(stream)
            return
        }
        let reason = status.map { "HTTP \($0)" }
            ?? error.map { $0.localizedDescription }
            ?? "the response ended at block \(stream.frontier) of \(stream.end)"
        guard stream.waiters > 0 || ContinuousClock.now - stream.lastUse < wantedFor else {
            // Nobody reads there any more: leave it idle rather than add load to a
            // struggling server. A reader that comes back restarts it.
            logger.debug("Source stream at block \(stream.frontier) failed (\(reason)), idle")
            return
        }
        // A client error won't clear up by retrying; anything else (a slow or briefly
        // unreachable server, a timeout, a 5xx) is retried for as long as it's wanted.
        if let status, (400..<500).contains(status), status != 408, status != 429, stream.attempt >= 3 {
            logger.error("Source block \(stream.frontier) failed after \(stream.attempt + 1) attempts: \(reason)")
            failures[stream.frontier] = EnhancedPlayerError.http(status: status, url: url)
            cancel(stream)
            return
        }
        let delay = min(0.5 * Double(1 << min(stream.attempt, 4)), 8)
        stream.attempt += 1
        stream.chunk = firstChunk
        stream.backingOff = true
        logger.warning("Source stream at block \(stream.frontier) attempt \(stream.attempt) failed (\(reason)), retrying in \(delay) s")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self, stream] in
            guard let self else { return }
            self.condition.lock()
            defer { self.condition.unlock() }
            stream.backingOff = false
            self.pump(stream)
        }
    }

    // MARK: - Private (call with the condition locked)

    /// Records that `index` was asked of the streams heading there, which keeps them reading.
    private func touch(_ index: Int) {
        for stream in streams where index <= stream.frontier + reach && index >= stream.frontier - readAhead - maxChunk {
            stream.demand = max(stream.demand, index)
            stream.lastUse = .now
            pump(stream)
        }
    }

    private func openStream(at index: Int) -> Stream {
        if streams.count >= Self.maxStreams {
            let idle = streams.filter { $0.waiters == 0 }
            if let victim = (idle.isEmpty ? streams : idle).min(by: { $0.lastUse < $1.lastUse }) {
                cancel(victim)
            }
        }
        let stream = Stream(at: index, chunk: firstChunk)
        streams.append(stream)
        logger.debug("Source stream opened at block \(index)")
        return stream
    }

    private func cancel(_ stream: Stream) {
        stream.cancelled = true
        if let task = stream.task {
            tasks[task.taskIdentifier] = nil
            task.cancel()
        }
        stream.task = nil
        streams.removeAll { $0 === stream }
    }

    /// Starts the stream's next request if it's idle and not far enough ahead yet.
    private func pump(_ stream: Stream) {
        guard !closed, !stream.cancelled, !stream.busy else { return }
        while stream.frontier < blockCount, memory[stream.frontier] != nil || disk[stream.frontier] != nil {
            stream.frontier += 1
        }
        guard stream.frontier < blockCount, stream.frontier <= stream.demand + readAhead else { return }
        stream.end = min(blockCount, stream.frontier + stream.chunk)
        let start = Int64(stream.frontier) * Int64(blockSize)
        let last = min(length, Int64(stream.end) * Int64(blockSize)) - 1
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(start)-\(last)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        stream.task = task
        stream.partial = Data()
        tasks[task.taskIdentifier] = stream
        task.resume()
    }

    private func blockLength(_ index: Int) -> Int {
        Int(min(Int64(blockSize), length - Int64(index) * Int64(blockSize)))
    }

    private func store(_ data: Data, for index: Int) {
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

/// Hands the session's callbacks to its file; the session holds its delegate strongly.
private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var file: RemoteFile?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(file?.received(response, for: dataTask) ?? .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        file?.received(data, for: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        file?.completed(task, error: error)
    }
}

/// One reader's position in a `RemoteFile`, the opaque behind a custom `AVIOContext`.
final class RemoteCursor {
    let file: RemoteFile
    let token: CancellationToken
    private(set) var position: Int64 = 0
    private var currentIndex = -1
    private var current = Data()

    init(file: RemoteFile, token: CancellationToken) {
        self.file = file
        self.token = token
    }

    /// Fills `buffer`, returning bytes read, `AVERROR_EOF`, or a negative error.
    func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int32 {
        if token.isCancelled { return FF.errorExit }
        if position >= file.length { return FF.errorEOF }
        let index = Int(position / Int64(file.blockSize))
        do {
            if index != currentIndex {
                current = try file.block(index, token: token)
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
