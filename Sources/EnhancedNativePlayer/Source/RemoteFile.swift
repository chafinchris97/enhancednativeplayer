import Foundation

/// Random access to a remote file through HTTP range requests.
///
/// The file is fetched in fixed-size blocks that are shared by every reader of the
/// session: the probe, the video remux, the audio remux and the init builders all
/// demux the same interleaved bytes, so a block fetched for one is a cache hit for
/// the others. Recent blocks stay in memory; older ones spill to disk up to a byte
/// budget, which is what lets the audio remux trail the video remux by a few
/// segments without downloading the file twice.
final class RemoteFile: @unchecked Sendable {
    let url: URL
    let length: Int64
    let blockSize: Int

    private let session: URLSession
    private let headers: [String: String]
    private let directory: URL
    private let maxDiskBlocks: Int
    private let maxMemoryBlocks = 16
    private let maxConcurrentFetches = 6

    private let condition = NSCondition()
    private var memory: [Int: Data] = [:]
    private var memoryOrder: [Int] = []
    private var disk: [Int: UInt64] = [:]
    private var useClock: UInt64 = 0
    private var inflight: [Int: URLSessionDataTask] = [:]
    private var failures: [Int: Error] = [:]
    private var closed = false

    private init(url: URL, length: Int64, blockSize: Int, session: URLSession, headers: [String: String], directory: URL, diskBudget: Int64) {
        self.url = url
        self.length = length
        self.blockSize = blockSize
        self.session = session
        self.headers = headers
        self.directory = directory
        self.maxDiskBlocks = max(0, Int(diskBudget / Int64(blockSize)))
    }

    var blockCount: Int { Int((length + Int64(blockSize) - 1) / Int64(blockSize)) }

    /// Opens the file with a range request for the first block, which also yields its length.
    static func open(url: URL, headers: [String: String], directory: URL, blockSize: Int = 1 << 20, diskBudget: Int64) async throws -> RemoteFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(blockSize - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EnhancedPlayerError.network("not an HTTP response") }
        guard http.statusCode == 206 else {
            if (200..<300).contains(http.statusCode) { throw EnhancedPlayerError.rangeRequestsUnsupported(url) }
            throw EnhancedPlayerError.http(status: http.statusCode, url: url)
        }
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else {
            throw EnhancedPlayerError.rangeRequestsUnsupported(url)
        }
        let file = RemoteFile(url: url, length: total, blockSize: blockSize, session: session, headers: headers, directory: directory, diskBudget: diskBudget)
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
        condition.lock()
        defer { condition.unlock() }
        while true {
            if closed || token.isCancelled { throw EnhancedPlayerError.cancelled }
            if let data = memory[index] {
                touchMemory(index)
                return data
            }
            if disk[index] != nil {
                useClock += 1
                disk[index] = useClock
                if let data = try? Data(contentsOf: blockURL(index)) {
                    insertMemory(data, for: index)
                    return data
                }
                disk[index] = nil
            }
            if let error = failures.removeValue(forKey: index) { throw error }
            if inflight[index] == nil { startFetch(index, attempt: 0) }
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
    }

    /// Starts background fetches for blocks that are not cached yet.
    func prefetch(_ indices: Range<Int>) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        for index in indices where index >= 0 && index < blockCount {
            if inflight.count >= maxConcurrentFetches { break }
            if memory[index] != nil || disk[index] != nil || inflight[index] != nil { continue }
            startFetch(index, attempt: 0)
        }
    }

    func close() {
        condition.lock()
        closed = true
        let tasks = Array(inflight.values)
        inflight.removeAll()
        memory.removeAll()
        memoryOrder.removeAll()
        condition.broadcast()
        condition.unlock()
        tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Private (call with the condition locked)

    private func startFetch(_ index: Int, attempt: Int) {
        let start = Int64(index) * Int64(blockSize)
        let end = min(length, start + Int64(blockSize)) - 1
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let expected = Int(end - start + 1)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.finishFetch(index, attempt: attempt, expected: expected, data: data, response: response, error: error)
        }
        inflight[index] = task
        task.resume()
    }

    private func finishFetch(_ index: Int, attempt: Int, expected: Int, data: Data?, response: URLResponse?, error: Error?) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard !closed else { return }
        inflight[index] = nil
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let data, error == nil, status == 206, data.count == expected {
            store(data, for: index)
            return
        }
        if attempt < 3 {
            startFetch(index, attempt: attempt + 1)
            return
        }
        if let error {
            failures[index] = EnhancedPlayerError.network(error.localizedDescription)
        } else if status != 206 {
            failures[index] = EnhancedPlayerError.http(status: status, url: url)
        } else {
            failures[index] = EnhancedPlayerError.network("short read for block \(index)")
        }
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

/// One reader's position in a `RemoteFile`, the opaque behind a custom `AVIOContext`.
final class RemoteCursor {
    let file: RemoteFile
    let token: CancellationToken
    private(set) var position: Int64 = 0
    private var currentIndex = -1
    private var current = Data()
    private var lastIndex = Int.min
    private let readAhead = 8

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
                if index == lastIndex + 1 {
                    // Sequential access: keep the pipe full.
                    file.prefetch((index + 1)..<(index + 1 + readAhead))
                }
                lastIndex = index
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
