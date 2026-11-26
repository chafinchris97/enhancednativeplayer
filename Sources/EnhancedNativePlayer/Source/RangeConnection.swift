import Foundation
import Network

/// One HTTP/1.1 GET of a file from `offset` to its end, read only as fast as the caller asks.
///
/// Not reading is how it pauses: the socket's buffers fill, TCP holds the server back, and
/// the response carries on where it stopped once reading resumes. One open-ended request
/// replaces the series of ranges a client would otherwise ask for, so the server's wait
/// before a response's first byte comes once per position read from, not once per range.
///
/// Redirects are followed. Every callback runs on `queue`; only one read is outstanding
/// at a time.
final class RangeConnection: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case status(Int)
        /// The server answered the range with the whole file.
        case notPartial
        case malformed(String)
        case closedEarly
        case timedOut
        case tooManyRedirects
        case unsupportedURL
        case cancelled

        var description: String {
            switch self {
            case .status(let status): "HTTP \(status)"
            case .notPartial: "the server ignored the range and sent the whole file"
            case .malformed(let what): "malformed response: \(what)"
            case .closedEarly: "the server closed the connection before the end of the response"
            case .timedOut: "no data for \(Int(RangeConnection.timeout)) s"
            case .tooManyRedirects: "more than \(RangeConnection.maxRedirects) redirects"
            case .unsupportedURL: "only http and https URLs can be read"
            case .cancelled: "cancelled"
            }
        }
    }

    /// How long a response may send nothing while it is being read.
    static let timeout: TimeInterval = 30
    static let maxRedirects = 5
    private static let maxHeadBytes = 64 << 10
    private static let readBytes = 1 << 20

    private let queue: DispatchQueue
    private let headers: [String: String]
    private let offset: Int64
    private var url: URL
    private var redirects = 0
    private var connection: NWConnection?
    private var onHead: ((Result<Head, Error>) -> Void)?
    private var reading: ((Result<Data?, Error>) -> Void)?
    /// Received bytes not handed out yet: the head while it's parsed, then the body.
    private var buffer = Data()
    /// Body bytes still to come, when the response says how many.
    private var remaining: Int64?
    private var chunks: ChunkDecoder?
    private var peerClosed = false
    private var finished = false
    private var failure: Error?
    private var timer: DispatchWorkItem?

    init(url: URL, headers: [String: String], offset: Int64, queue: DispatchQueue) {
        self.url = url
        self.headers = headers
        self.offset = offset
        self.queue = queue
    }

    struct Head {
        /// The file's length.
        let total: Int64
        /// Where the request was answered, after any redirects.
        let url: URL
    }

    /// Connects and sends the request. `onHead` gets the file's length and where it was
    /// answered once a 206 response for `offset` arrives, or the failure.
    func start(onHead: @escaping @Sendable (Result<Head, Error>) -> Void) {
        queue.async { [self] in
            self.onHead = onHead
            connect()
        }
    }

    /// Hands over the next body bytes, or nil at the end of the response.
    func read(_ completion: @escaping @Sendable (Result<Data?, Error>) -> Void) {
        queue.async { [self] in
            precondition(reading == nil, "one read at a time")
            reading = completion
            if let failure {
                deliver(.failure(failure))
            } else if onHead == nil {
                pump()
            }
        }
    }

    func cancel() {
        queue.async { [self] in fail(Failure.cancelled) }
    }

    // MARK: - On the queue

    private func connect() {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return fail(Failure.unsupportedURL) }
        let secure = scheme == "https"
        let port = url.port ?? (secure ? 443 : 80)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return fail(Failure.unsupportedURL) }
        let parameters = secure ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : NWParameters.tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                self.send(on: connection, host: host, port: port, secure: secure)
            case .waiting(let error), .failed(let error):
                // Waiting means there's no route right now; the reader's retry covers that.
                self.fail(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
        armTimer()
    }

    private func send(on connection: NWConnection, host: String, port: Int, secure: Bool) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?\(query)" }
        var hostField = host.contains(":") ? "[\(host)]" : host
        if port != (secure ? 443 : 80) { hostField += ":\(port)" }

        var lines = ["GET \(target) HTTP/1.1", "Host: \(hostField)"]
        let reserved: Set<String> = ["host", "range", "connection", "accept-encoding", "content-length", "transfer-encoding"]
        for (name, value) in headers where !reserved.contains(name.lowercased()) {
            lines.append("\(name): \(value)")
        }
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            lines.append("User-Agent: EnhancedNativePlayer")
        }
        lines += ["Accept: */*", "Accept-Encoding: identity", "Range: bytes=\(offset)-", "Connection: close"]
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: request, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection, let error else { return }
            self.fail(error)
        })
        receiveHead(on: connection)
    }

    private func receiveHead(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeadBytes) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection, self.onHead != nil else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer[self.buffer.startIndex..<end.lowerBound]
                self.buffer = Data(self.buffer[end.upperBound...])
                self.peerClosed = isComplete
                self.parse(head: head)
            } else if let error {
                self.fail(error)
            } else if isComplete {
                self.fail(Failure.closedEarly)
            } else if self.buffer.count > Self.maxHeadBytes {
                self.fail(Failure.malformed("the response head is over \(Self.maxHeadBytes >> 10) KB"))
            } else {
                self.receiveHead(on: connection)
            }
        }
    }

    private func parse(head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            return fail(Failure.malformed("status line \(lines.first ?? "")"))
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        if [301, 302, 303, 307, 308].contains(status), let location = fields["location"] {
            redirects += 1
            guard redirects <= Self.maxRedirects else { return fail(Failure.tooManyRedirects) }
            guard let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                return fail(Failure.malformed("redirect to \(location)"))
            }
            connection?.cancel()
            connection = nil
            buffer = Data()
            peerClosed = false
            url = next
            return connect()
        }
        guard status == 206 else {
            return fail((200..<300).contains(status) ? Failure.notPartial : Failure.status(status))
        }
        // Content-Range: bytes <first>-<last>/<total>
        guard let range = fields["content-range"], range.lowercased().hasPrefix("bytes "),
              let slash = range.lastIndex(of: "/"), let total = Int64(range[range.index(after: slash)...]),
              let dash = range.firstIndex(of: "-"),
              let first = Int64(range[range.index(range.startIndex, offsetBy: 6)..<dash].trimmingCharacters(in: .whitespaces)),
              let last = Int64(range[range.index(after: dash)..<slash]) else {
            return fail(Failure.malformed("Content-Range \(fields["content-range"] ?? "missing")"))
        }
        guard first == offset, last >= first else {
            return fail(Failure.malformed("Content-Range \(range) for a request from byte \(offset)"))
        }
        if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            chunks = ChunkDecoder()
        } else {
            remaining = last - first + 1
        }
        timer?.cancel()
        timer = nil
        let callback = onHead
        onHead = nil
        callback?(.success(Head(total: total, url: url)))
        if reading != nil { pump() }
    }

    /// Hands what's buffered to the waiting read, or receives more for it.
    private func pump() {
        guard reading != nil, failure == nil else { return }
        if finished { return deliver(.success(nil)) }
        var out: Data
        if chunks != nil {
            do { out = try chunks!.decode(&buffer) } catch { return fail(error) }
        } else {
            out = buffer
            buffer = Data()
            if let left = remaining {
                if Int64(out.count) > left { out = out.prefix(Int(left)) }
                remaining = left - Int64(out.count)
            }
        }
        if !out.isEmpty { return deliver(.success(out)) }
        if remaining == 0 || chunks?.done == true {
            finished = true
            connection?.cancel()
            connection = nil
            return deliver(.success(nil))
        }
        if peerClosed {
            // Without a length or chunks, the body runs to the close.
            if remaining == nil, chunks == nil {
                finished = true
                return deliver(.success(nil))
            }
            return fail(Failure.closedEarly)
        }
        guard let connection else { return fail(Failure.closedEarly) }
        armTimer()
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readBytes) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data { self.buffer.append(data) }
            if isComplete { self.peerClosed = true }
            if let error, self.buffer.isEmpty { return self.fail(error) }
            self.pump()
        }
    }

    private func deliver(_ result: Result<Data?, Error>) {
        timer?.cancel()
        timer = nil
        let callback = reading
        reading = nil
        callback?(result)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        if let callback = onHead {
            onHead = nil
            callback(.failure(error))
        }
        if reading != nil { deliver(.failure(error)) }
    }

    private func armTimer() {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail(Failure.timedOut) }
        timer = item
        queue.asyncAfter(deadline: .now() + Self.timeout, execute: item)
    }
}

/// Undoes `Transfer-Encoding: chunked`, which a server may use even for a range.
struct ChunkDecoder {
    private var left = 0
    private var expectsLineEnd = false
    private(set) var done = false

    /// Takes what it can decode from the front of `buffer` and returns the payload in it.
    mutating func decode(_ buffer: inout Data) throws -> Data {
        var out = Data()
        var consumed = 0
        let bytes = [UInt8](buffer)
        while !done {
            if left > 0 {
                let take = min(left, bytes.count - consumed)
                guard take > 0 else { break }
                out.append(contentsOf: bytes[consumed..<consumed + take])
                consumed += take
                left -= take
                if left == 0 { expectsLineEnd = true }
                continue
            }
            guard let lineEnd = Self.lineEnd(in: bytes, from: consumed) else {
                if bytes.count - consumed > 4096 { throw RangeConnection.Failure.malformed("chunk size line") }
                break
            }
            let line = bytes[consumed..<lineEnd]
            consumed = lineEnd + 2
            if expectsLineEnd {
                guard line.isEmpty else { throw RangeConnection.Failure.malformed("chunk end") }
                expectsLineEnd = false
                continue
            }
            let sizeText = String(decoding: line.prefix { $0 != UInt8(ascii: ";") }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw RangeConnection.Failure.malformed("chunk size \(sizeText)") }
            if size == 0 { done = true } else { left = size }
        }
        buffer = Data(bytes[consumed...])
        return out
    }

    private static func lineEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }
}
