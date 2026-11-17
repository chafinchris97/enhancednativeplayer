import Foundation
import Network
import Testing
@testable import EnhancedNativePlayer

struct HTTPRequestParserTests {
    @Test func parsesAGet() throws {
        let raw = Data("GET /video_3.mp4?runtimeTicks=120000&x=a%20b HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: */*\r\n\r\nGET /next".utf8)
        let (request, length) = try #require(try HTTPRequestParser.parse(raw))
        #expect(request.method == "GET")
        #expect(request.path == "/video_3.mp4")
        #expect(request.query == ["runtimeTicks": "120000", "x": "a b"])
        #expect(request.header("host") == "127.0.0.1")
        #expect(request.keepAlive)
        #expect(String(decoding: raw.dropFirst(length), as: UTF8.self) == "GET /next")
    }

    @Test func waitsForTheWholeHead() throws {
        #expect(try HTTPRequestParser.parse(Data("GET /master.m3u8 HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }

    @Test func keepAliveFollowsTheVersion() throws {
        func keepAlive(_ head: String) throws -> Bool {
            try #require(try HTTPRequestParser.parse(Data(head.utf8))).request.keepAlive
        }
        #expect(try !keepAlive("GET / HTTP/1.1\r\nConnection: close\r\n\r\n"))
        #expect(try !keepAlive("GET / HTTP/1.0\r\n\r\n"))
        #expect(try keepAlive("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n"))
    }

    @Test func absoluteFormTarget() throws {
        let (request, _) = try #require(try HTTPRequestParser.parse(Data("GET http://127.0.0.1:80/audio_1_init.mp4 HTTP/1.1\r\n\r\n".utf8)))
        #expect(request.path == "/audio_1_init.mp4")
    }

    @Test func rejectsBadHeads() {
        #expect(throws: HTTPRequestParser.Failure.malformed) { try HTTPRequestParser.parse(Data("GARBAGE\r\n\r\n".utf8)) }
        #expect(throws: HTTPRequestParser.Failure.malformed) { try HTTPRequestParser.parse(Data("GET / HTTP/2\r\n\r\n".utf8)) }
        #expect(throws: HTTPRequestParser.Failure.unsupportedTransferEncoding) {
            try HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
        #expect(throws: HTTPRequestParser.Failure.headTooLarge) {
            try HTTPRequestParser.parse(Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.maxHeadBytes + 1))
        }
    }
}

@Suite(.serialized)
struct HTTPListenerTests {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    private func listener(port: Int = 0, handler: @escaping HTTPListener.Handler) throws -> HTTPListener {
        try HTTPListener(port: port, serverName: "Test", handler: handler, onFailure: { _ in })
    }

    @Test func answersRequestsOnOneConnection() async throws {
        let requests = Mutex<[HTTPRequest]>([])
        let server = try listener { request in
            requests.withLock { $0.append(request) }
            return request.path == "/master.m3u8" ? .playlist("#EXTM3U\n") : Response(status: .notFound)
        }
        let port = try await server.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        for _ in 0..<3 {
            let (data, response) = try await Self.session.data(from: base.appendingPathComponent("master.m3u8"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
            #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            #expect(http.value(forHTTPHeaderField: "Server") == "Test")
            #expect(String(decoding: data, as: UTF8.self) == "#EXTM3U\n")
        }
        let (_, missing) = try await Self.session.data(from: base.appendingPathComponent("nothing.mp4"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        #expect(requests.withLock { $0.count } == 4)
        await server.shutdownAndWait()
    }

    @Test func onlyGet() async throws {
        let server = try listener { _ in .playlist("#EXTM3U\n") }
        let port = try await server.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
        request.httpMethod = "POST"
        request.httpBody = Data("body".utf8)
        let (_, response) = try await Self.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 405)
        await server.shutdownAndWait()
    }

    @Test func streamsAFileAndReportsDelivery() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("enp-http-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = Data((0..<(3 << 20) + 12345).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try contents.write(to: file)
        let delivered = Mutex<[Bool]>([])
        let server = try listener { _ in
            (try? Response.segment(file, audio: false) { ok in delivered.withLock { $0.append(ok) } }) ?? Response(status: .internalServerError)
        }
        let port = try await server.start()
        let (data, response) = try await Self.session.data(from: URL(string: "http://127.0.0.1:\(port)/video_0.mp4")!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(contents.count)")
        #expect(data == contents)
        await server.shutdownAndWait()
        #expect(delivered.withLock { $0 } == [true])
    }

    @Test func answersConnectionsSideBySide() async throws {
        let server = try listener { request in
            if request.path == "/slow" { try? await Task.sleep(for: .seconds(1)) }
            return .playlist(request.path)
        }
        let port = try await server.start()
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let (data, _) = try await Self.session.data(from: URL(string: "http://127.0.0.1:\(port)/slow?n=\(index)")!)
                    #expect(String(decoding: data, as: UTF8.self) == "/slow")
                }
            }
            try await group.waitForAll()
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        await server.shutdownAndWait()
    }

    @Test func shutdownWaitsForTheResponseInFlight() async throws {
        let server = try listener { _ in
            try? await Task.sleep(for: .milliseconds(500))
            return .playlist("late")
        }
        let port = try await server.start()
        let fetch = Task { try await Self.session.data(from: URL(string: "http://127.0.0.1:\(port)/master.m3u8")!) }
        try await Task.sleep(for: .milliseconds(100))
        await server.shutdownAndWait()
        let (data, _) = try await fetch.value
        #expect(String(decoding: data, as: UTF8.self) == "late")
        await #expect(throws: (any Error).self) {
            _ = try await Self.session.data(from: URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
        }
    }

    @Test func listensAgainOnTheSamePort() async throws {
        let first = try listener { _ in .playlist("one") }
        let port = try await first.start()
        first.shutdown()
        var second: HTTPListener?
        for _ in 0..<20 where second == nil {
            let candidate = try listener(port: port) { _ in .playlist("two") }
            if (try? await candidate.start()) == port {
                second = candidate
            } else {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let server = try #require(second)
        let (data, _) = try await Self.session.data(from: URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
        #expect(String(decoding: data, as: UTF8.self) == "two")
        await first.shutdownAndWait()
        await server.shutdownAndWait()
    }

    @Test func pipelinedRequestsOverARawSocket() async throws {
        let server = try listener { request in .playlist(request.path) }
        let port = try await server.start()
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        let raw = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(raw.utf8), completion: .idempotent)
        var received = Data()
        while true {
            let (data, done): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
            if let data { received.append(data) }
            if done { break }
        }
        let text = String(decoding: received, as: UTF8.self)
        #expect(text.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
        #expect(text.hasSuffix("\r\n\r\n/b"))
        #expect(text.contains("Connection: close"))
        await server.shutdownAndWait()
    }
}
