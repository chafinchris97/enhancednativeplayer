import Foundation
import Network

/// A minimal HTTP/1.1 server on Network.framework, listening on one loopback port.
///
/// Requests on a connection are answered one after another, with keep-alive; separate
/// connections are answered side by side. Bodies are sent with a Content-Length, and
/// files in chunks, each sent once the one before it has been taken by the socket.
final class HTTPListener: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> Response

    private struct State {
        var ready: CheckedContinuation<Int, any Error>?
        var started = false
        var closed = false
        var nextConnection = 0
        var connections: [Int: (connection: HTTPConnection, task: Task<Void, Never>)] = [:]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "EnhancedNativePlayer.HTTPListener")
    private let serverName: String
    private let handler: Handler
    private let onFailure: @Sendable (any Error) -> Void
    private let state = Mutex(State())

    /// `port` 0 picks an ephemeral one. `onFailure` is called when the listener closes on
    /// its own after it started.
    init(port: Int, serverName: String, handler: @escaping Handler, onFailure: @escaping @Sendable (any Error) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw EnhancedPlayerError.serverFailedToStart }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        listener = try NWListener(using: parameters)
        self.serverName = serverName
        self.handler = handler
        self.onFailure = onFailure
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] newState in
            self?.handle(newState)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let closed = state.withLock { state in
                if !state.closed { state.ready = continuation }
                return state.closed
            }
            if closed {
                continuation.resume(throwing: EnhancedPlayerError.cancelled)
            } else {
                listener.start(queue: queue)
            }
        }
    }

    /// Stops accepting connections and closes each open one once the response it is
    /// sending, if any, has gone out.
    func shutdown() {
        let (ready, connections) = state.withLock { state in
            state.closed = true
            defer { state.ready = nil }
            return (state.ready, state.connections.values.map(\.connection))
        }
        listener.cancel()
        ready?.resume(throwing: EnhancedPlayerError.cancelled)
        for connection in connections { connection.close() }
    }

    /// Shuts down and waits for every connection to close.
    func shutdownAndWait() async {
        shutdown()
        while let task = state.withLock({ $0.connections.values.first?.task }) {
            await task.value
        }
    }

    private func handle(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            let port = Int(listener.port?.rawValue ?? 0)
            let ready = state.withLock { state in
                state.started = true
                defer { state.ready = nil }
                return state.ready
            }
            if port > 0 {
                ready?.resume(returning: port)
            } else {
                ready?.resume(throwing: EnhancedPlayerError.serverFailedToStart)
                listener.cancel()
            }
        case .failed(let error), .waiting(let error):
            let (ready, failedAfterStart) = state.withLock { state in
                defer {
                    state.ready = nil
                    // The cancel below must not report the failure a second time.
                    state.closed = true
                }
                return (state.ready, state.started && !state.closed)
            }
            listener.cancel()
            if let ready {
                ready.resume(throwing: error)
            } else if failedAfterStart {
                onFailure(error)
            }
        case .cancelled:
            let (ready, cancelledAfterStart) = state.withLock { state in
                defer { state.ready = nil }
                return (state.ready, state.started && !state.closed)
            }
            ready?.resume(throwing: EnhancedPlayerError.cancelled)
            if cancelledAfterStart { onFailure(EnhancedPlayerError.cancelled) }
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(nwConnection, serverName: serverName)
        let handler = handler
        let added = state.withLock { state -> Int? in
            guard !state.closed else { return nil }
            state.nextConnection += 1
            let id = state.nextConnection
            let task = Task { [weak self] in
                await connection.run(handler: handler)
                self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
            }
            state.connections[id] = (connection, task)
            return id
        }
        if added == nil { nwConnection.cancel() }
    }
}

/// One accepted connection, answering its requests in order.
final class HTTPConnection: Sendable {
    private struct State {
        var busy = false
        var closing = false
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "EnhancedNativePlayer.HTTPConnection")
    private let serverName: String
    private let state = Mutex(State())

    /// The most read from the socket at once, and the size of each chunk of a file sent.
    private static let readSize = 256 << 10
    private static let fileChunkSize = 1 << 20

    init(_ connection: NWConnection, serverName: String) {
        self.connection = connection
        self.serverName = serverName
    }

    /// Closes the connection now if it is between requests, or else once the current
    /// response has been sent.
    func close() {
        let idle = state.withLock { state in
            state.closing = true
            return !state.busy
        }
        if idle { connection.cancel() }
    }

    func run(handler: @Sendable (HTTPRequest) async -> Response) async {
        connection.stateUpdateHandler = { [connection] newState in
            if case .failed = newState { connection.cancel() }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }

        var buffer = Data()
        while true {
            let request: HTTPRequest
            do {
                guard let next = try await nextRequest(&buffer) else { return }
                request = next
            } catch let failure as HTTPRequestParser.Failure {
                try? await write(Response(status: failure.status), keepAlive: false)
                return
            } catch {
                return
            }

            let response: Response
            if request.method == "GET" {
                response = await handler(request)
            } else {
                response = Response(status: .methodNotAllowed, headers: [("Allow", "GET")])
            }
            let keepAlive = request.keepAlive && !state.withLock { $0.closing }
            do {
                try await write(response, keepAlive: keepAlive)
            } catch {
                return
            }
            guard keepAlive else { return }
        }
    }

    /// Reads up to the next complete request and past its body. Returns nil once the
    /// client has closed, or when the connection is closing between requests.
    private func nextRequest(_ buffer: inout Data) async throws -> HTTPRequest? {
        let idle = state.withLock { state in
            state.busy = false
            return !state.closing
        }
        guard idle else { return nil }
        while true {
            if !buffer.isEmpty {
                let open = state.withLock { state in
                    guard !state.closing else { return false }
                    state.busy = true
                    return true
                }
                guard open else { return nil }
            }
            if let (request, headLength) = try HTTPRequestParser.parse(buffer) {
                buffer = Data(buffer.dropFirst(headLength))
                // GET bodies carry nothing; read past one all the same.
                var remaining = request.contentLength
                while remaining > 0 {
                    if buffer.isEmpty {
                        guard let more = try await receive() else { return nil }
                        buffer = more
                    }
                    let taken = min(remaining, buffer.count)
                    buffer = Data(buffer.dropFirst(taken))
                    remaining -= taken
                }
                return request
            }
            guard let more = try await receive() else { return nil }
            buffer.append(more)
        }
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func write(_ response: Response, keepAlive: Bool) async throws {
        var head = "HTTP/1.1 \(response.status.code) \(response.status.reason)\r\n"
        for header in response.headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Date: \(HTTPDate.now())\r\n"
        head += "Server: \(serverName)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        switch response.body {
        case .bytes(let data):
            var message = Data(head.utf8)
            message.append(data)
            try await send(message)
        case .file(let handle, _, let completion):
            var delivered = false
            defer {
                try? handle.close()
                completion(delivered)
            }
            try await send(Data(head.utf8))
            while let chunk = try handle.read(upToCount: Self.fileChunkSize), !chunk.isEmpty {
                try await send(chunk)
            }
            delivered = true
        }
    }
}

/// The IMF-fixdate form of the Date header, "Sun, 06 Nov 1994 08:49:37 GMT".
enum HTTPDate {
    // DateFormatter is thread-safe for formatting.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }
}
