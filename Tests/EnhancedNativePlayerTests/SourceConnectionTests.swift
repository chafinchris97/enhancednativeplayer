import Foundation
import Logging
import Network
import Testing
@testable import EnhancedNativePlayer

/// Kept-open sockets, `Retry-After` and the throughput floor, against a loopback server that
/// keeps connections open between requests.
@Suite(.serialized)
struct SourceConnectionTests {
    /// 256 blocks, each starting with its own number, so a block served from the wrong place shows.
    let file: Data = {
        let pattern = Data((0..<(64 << 10)).map { UInt8(truncatingIfNeeded: $0 % 251) })
        var file = Data(capacity: 256 * pattern.count)
        for block in 0..<256 {
            file += withUnsafeBytes(of: UInt32(block).bigEndian) { Data($0) } + pattern.dropFirst(4)
        }
        return file
    }()

    // MARK: - RangeConnection

    @Test func aBoundedRangeLeavesItsSocketForTheNext() async throws {
        let server = try await KeepAliveServer(file: file)
        defer { server.stop() }
        let queue = DispatchQueue(label: "test.keepalive")
        let first = RangeConnection(url: server.url, headers: [:], offset: 1000, end: 5000, queue: queue)
        #expect(try await read(first) == file[1000..<5000])
        let second = RangeConnection(url: server.url, headers: [:], offset: 300_000, end: 310_000, reusing: first, queue: queue)
        #expect(try await read(second) == file[300_000..<310_000])
        second.cancel()
        #expect(server.connections == 1)
        #expect(server.requests == 2)
    }

    @Test func aReusedSocketTheServerClosedIsReplaced() async throws {
        let server = try await KeepAliveServer(file: file) { _, _ in .serveThenClose }
        defer { server.stop() }
        let queue = DispatchQueue(label: "test.keepalive")
        let first = RangeConnection(url: server.url, headers: [:], offset: 0, end: 2000, queue: queue)
        #expect(try await read(first) == file[0..<2000])
        try await Task.sleep(for: .milliseconds(200))
        let second = RangeConnection(url: server.url, headers: [:], offset: 2000, end: 4000, reusing: first, queue: queue)
        #expect(try await read(second) == file[2000..<4000])
        #expect(server.connections == 2)
    }

    @Test func aThrottledAnswerCarriesItsRetryAfter() async throws {
        let server = try await KeepAliveServer(file: file) { _, _ in .throttle(retryAfter: "7") }
        defer { server.stop() }
        let connection = RangeConnection(url: server.url, headers: [:], offset: 0, end: 10, queue: DispatchQueue(label: "test.keepalive"))
        do {
            _ = try await read(connection)
            Issue.record("a 429 was read as a body")
        } catch RangeConnection.Failure.throttled(let status, let retryAfter) {
            #expect(status == 429)
            #expect(retryAfter == 7)
        }
    }

    @Test func retryAfterReadsSecondsAndDates() {
        #expect(RangeConnection.retryAfter("120") == 120)
        #expect(RangeConnection.retryAfter("-1") == nil)
        #expect(RangeConnection.retryAfter("soon") == nil)
        #expect(RangeConnection.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let later = RangeConnection.retryAfter(formatter.string(from: Date().addingTimeInterval(30))) ?? 0
        #expect(later > 25 && later <= 30)
    }

    // MARK: - RemoteFile

    @Test func aLookupReaderJumpsOnOneSocket() async throws {
        let server = try await KeepAliveServer(file: file)
        defer { server.stop() }
        let remote = try await openFile(server)
        defer { remote.close() }
        let reader = remote.makeReader(role: .lookup)
        defer { remote.closeReader(reader) }
        // Far enough apart, and from the start connection, that no connection brings the next.
        for index in [200, 120, 240, 160] {
            let data = try remote.block(index, for: reader, token: CancellationToken())
            #expect(data == file[index * blockSize..<(index + 1) * blockSize], "block \(index)")
        }
        // The one that learned the length, and the lookup reader's, which every jump went out on.
        #expect(server.connections == 2)
        #expect(server.requests == 5)
    }

    @Test func aThrottlingServerIsWaitedFor() async throws {
        let server = try await KeepAliveServer(file: file) { request, range in
            range.end != nil && request == 1 ? .throttle(retryAfter: "1") : .serve
        }
        defer { server.stop() }
        let remote = try await openFile(server)
        defer { remote.close() }
        let reader = remote.makeReader(role: .lookup)
        defer { remote.closeReader(reader) }
        let start = ContinuousClock.now
        let data = try remote.block(40, for: reader, token: CancellationToken())
        #expect(data == file[40 * blockSize..<41 * blockSize])
        #expect(ContinuousClock.now - start >= .seconds(1))
    }

    @Test func aTricklingConnectionIsReplaced() async throws {
        let server = try await KeepAliveServer(file: file) { request, range in
            range.end != nil && request == 1 ? .trickle : .serve
        }
        defer { server.stop() }
        let remote = try await openFile(server)
        defer { remote.close() }
        remote.trickleWindow = .milliseconds(600)
        let reader = remote.makeReader(role: .lookup)
        defer { remote.closeReader(reader) }
        let start = ContinuousClock.now
        let data = try remote.block(40, for: reader, token: CancellationToken())
        #expect(data == file[40 * blockSize..<41 * blockSize])
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(server.connections == 3)
    }

    // MARK: - Helpers

    private let blockSize = 64 << 10

    private func openFile(_ server: KeepAliveServer) async throws -> RemoteFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ENP-source-test-\(UUID().uuidString)")
        return try await RemoteFile.open(url: server.url, headers: [:], directory: directory, blockSize: blockSize, diskBudget: 0, logger: Logger(label: "test"))
    }

    private func read(_ connection: RangeConnection) async throws -> Data {
        _ = try await withCheckedThrowingContinuation { continuation in
            connection.start { continuation.resume(with: $0) }
        }
        var body = Data()
        while let data = try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Data?, Error>) in
            connection.read { continuation.resume(with: $0) }
        }) {
            body += data
        }
        return body
    }
}

/// Answers ranges of `file` on connections it keeps open, unless `answer` says otherwise.
/// `answer` gets the request's number across the server, from 0, and its range.
final class KeepAliveServer: @unchecked Sendable {
    enum Answer {
        case serve
        /// Serve, then close the connection without saying so.
        case serveThenClose
        case throttle(retryAfter: String)
        /// Send the head and a few bytes, then nothing.
        case trickle
    }

    struct Range {
        let start: Int
        let end: Int?
    }

    let file: Data
    private let answer: @Sendable (Int, Range) -> Answer
    private let queue = DispatchQueue(label: "test.keepalive.server")
    private let listener: NWListener
    private let lock = NSLock()
    private var connectionCount = 0
    private var requestCount = 0
    private var open: [NWConnection] = []
    private(set) var url: URL!

    var connections: Int { lock.withLock { connectionCount } }
    var requests: Int { lock.withLock { requestCount } }

    init(file: Data, answer: @escaping @Sendable (Int, Range) -> Answer = { _, _ in .serve }) async throws {
        self.file = file
        self.answer = answer
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let listener = listener
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // Only ever touched on `queue`.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        url = URL(string: "http://127.0.0.1:\(port)/file")
    }

    func stop() {
        listener.cancel()
        lock.withLock { open }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            connectionCount += 1
            open.append(connection)
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer += data }
            guard error == nil, !(isComplete && buffer.isEmpty) else { return connection.cancel() }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return self.receive(on: connection, buffer: buffer) }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let rest = Data(buffer[end.upperBound...])
            self.respond(to: head, on: connection) { self.receive(on: connection, buffer: rest) }
        }
    }

    private func respond(to head: String, on connection: NWConnection, then next: @escaping () -> Void) {
        let line = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") } ?? "range: bytes=0-"
        let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(spec.first ?? "0") ?? 0
        let last = spec.count > 1 ? Int(spec[1]) : nil
        let range = Range(start: start, end: last.map { $0 + 1 })
        let number = lock.withLock {
            requestCount += 1
            return requestCount - 1
        }
        let stop = min(file.count, range.end ?? file.count)
        let body = file[start..<stop]
        let ok = Data("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(stop - 1)/\(file.count)\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        switch answer(number, range) {
        case .serve:
            connection.send(content: ok + body, completion: .contentProcessed { _ in next() })
        case .serveThenClose:
            connection.send(content: ok + body, completion: .contentProcessed { _ in connection.cancel() })
        case .throttle(let retryAfter):
            let refusal = Data("HTTP/1.1 429 Too Many Requests\r\nRetry-After: \(retryAfter)\r\nContent-Length: 0\r\n\r\n".utf8)
            connection.send(content: refusal, completion: .contentProcessed { _ in next() })
        case .trickle:
            connection.send(content: ok + body.prefix(100), completion: .contentProcessed { _ in })
        }
    }
}
