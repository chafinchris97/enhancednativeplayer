import Foundation
import Network
import Testing
@testable import EnhancedNativePlayer

struct ChunkDecoderTests {
    @Test func decodesChunksSplitAnywhere() throws {
        let body = Data("4\r\nWiki\r\n6;ext=1\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\n\r\n".utf8)
        // Every split point, so a size line, a payload or a line end can arrive in pieces.
        for split in 0...body.count {
            var decoder = ChunkDecoder()
            var buffer = Data(body.prefix(split))
            var out = try decoder.decode(&buffer)
            buffer.append(body.dropFirst(split))
            out += try decoder.decode(&buffer)
            #expect(String(decoding: out, as: UTF8.self) == "Wikipedia in \r\n\r\nchunks.", "split at \(split)")
            #expect(decoder.done)
        }
    }

    @Test func rejectsABadSize() {
        var decoder = ChunkDecoder()
        var buffer = Data("zz\r\nab\r\n".utf8)
        #expect(throws: RangeConnection.Failure.self) { try decoder.decode(&buffer) }
    }
}

/// `RangeConnection` against a loopback server that answers each request with a canned
/// response picked by its path.
@Suite(.serialized)
struct RangeConnectionTests {
    let file = Data((0..<10_000).map { UInt8($0 % 251) })

    @Test func readsFromTheOffsetToTheEnd() async throws {
        try await withServer { port in
            let (total, body) = try await fetch("http://127.0.0.1:\(port)/plain", offset: 1234)
            #expect(total == Int64(file.count))
            #expect(body == file.dropFirst(1234))
        }
    }

    @Test func followsARedirectAndDecodesChunks() async throws {
        try await withServer { port in
            let (head, body) = try await fetchAnswered("http://127.0.0.1:\(port)/redirect", offset: 500)
            #expect(head.total == Int64(file.count))
            #expect(head.url.path == "/chunked")
            #expect(body == file.dropFirst(500))
        }
    }

    @Test func aWholeFileAnswerIsNotARange() async throws {
        try await withServer { port in
            await #expect(throws: RangeConnection.Failure.self) {
                _ = try await fetch("http://127.0.0.1:\(port)/whole", offset: 0)
            }
        }
    }

    @Test func aCloseBeforeTheEndIsAFailure() async throws {
        try await withServer { port in
            await #expect(throws: RangeConnection.Failure.self) {
                _ = try await fetch("http://127.0.0.1:\(port)/short", offset: 0)
            }
        }
    }

    // MARK: - Helpers

    private func fetch(_ url: String, offset: Int64) async throws -> (Int64, Data) {
        let (head, body) = try await fetchAnswered(url, offset: offset)
        return (head.total, body)
    }

    private func fetchAnswered(_ url: String, offset: Int64) async throws -> (RangeConnection.Head, Data) {
        let queue = DispatchQueue(label: "test.range")
        let connection = RangeConnection(url: URL(string: url)!, headers: ["X-Test": "1"], offset: offset, queue: queue)
        defer { connection.cancel() }
        let head = try await withCheckedThrowingContinuation { continuation in
            connection.start { continuation.resume(with: $0) }
        }
        var body = Data()
        while let data = try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Data?, Error>) in
            connection.read { continuation.resume(with: $0) }
        }) {
            body += data
        }
        return (head, body)
    }

    private func response(for head: String) -> Data {
        let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let range = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
        let offset = range.flatMap { Int($0.dropFirst("range: bytes=".count).prefix { $0 != "-" }) } ?? 0
        let body = file.dropFirst(offset)
        let contentRange = "Content-Range: bytes \(offset)-\(file.count - 1)/\(file.count)"
        switch target {
        case "/plain":
            return Data("HTTP/1.1 206 Partial Content\r\n\(contentRange)\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        case "/redirect":
            return Data("HTTP/1.1 302 Found\r\nLocation: /chunked\r\nContent-Length: 0\r\n\r\n".utf8)
        case "/chunked":
            var out = Data("HTTP/1.1 206 Partial Content\r\n\(contentRange)\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            var rest = Data(body)
            while !rest.isEmpty {
                let piece = rest.prefix(777)
                out += Data("\(String(piece.count, radix: 16))\r\n".utf8) + piece + Data("\r\n".utf8)
                rest = Data(rest.dropFirst(piece.count))
            }
            return out + Data("0\r\n\r\n".utf8)
        case "/whole":
            return Data("HTTP/1.1 200 OK\r\nContent-Length: \(file.count)\r\n\r\n".utf8) + file
        default:
            return Data("HTTP/1.1 206 Partial Content\r\n\(contentRange)\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body.prefix(100)
        }
    }

    private func withServer(_ body: (UInt16) async throws -> Void) async throws {
        let queue = DispatchQueue(label: "test.server")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            var head = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let data { head += data }
                    guard error == nil else { return connection.cancel() }
                    guard head.range(of: Data("\r\n\r\n".utf8)) != nil else { return receive() }
                    let reply = response(for: String(decoding: head, as: UTF8.self))
                    connection.send(content: reply, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            receive()
        }
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
        defer { listener.cancel() }
        try await body(port)
    }
}
