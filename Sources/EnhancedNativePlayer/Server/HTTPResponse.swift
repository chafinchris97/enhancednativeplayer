import Foundation

/// What the local server answers one request with.
struct Response: Sendable {
    struct Status: Sendable, Equatable {
        let code: Int
        let reason: String

        static let ok = Status(code: 200, reason: "OK")
        static let badRequest = Status(code: 400, reason: "Bad Request")
        static let notFound = Status(code: 404, reason: "Not Found")
        static let methodNotAllowed = Status(code: 405, reason: "Method Not Allowed")
        static let requestHeaderFieldsTooLarge = Status(code: 431, reason: "Request Header Fields Too Large")
        static let internalServerError = Status(code: 500, reason: "Internal Server Error")
        static let notImplemented = Status(code: 501, reason: "Not Implemented")
    }

    enum Body: Sendable {
        case bytes(Data)
        /// A file sent in chunks from its handle, which the connection closes once done.
        /// `completion` is called exactly once, with whether every byte was handed to the socket.
        case file(FileHandle, size: Int, completion: @Sendable (Bool) -> Void)

        var count: Int {
            switch self {
            case .bytes(let data): data.count
            case .file(_, let size, _): size
            }
        }
    }

    var status: Status
    var headers: [(name: String, value: String)]
    var body: Body

    init(status: Status, headers: [(name: String, value: String)] = [], body: Body = .bytes(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

extension Response {
    static func playlist(_ text: String) -> Response {
        Response(
            status: .ok,
            headers: [("Content-Type", "application/vnd.apple.mpegurl"), ("Cache-Control", "no-cache")],
            body: .bytes(Data(text.utf8))
        )
    }

    static func webVTT(_ text: String) -> Response {
        Response(status: .ok, headers: [("Content-Type", "text/vtt")], body: .bytes(Data(text.utf8)))
    }

    static func mp4(_ data: Data, audio: Bool) -> Response {
        Response(status: .ok, headers: [("Content-Type", audio ? "audio/mp4" : "video/mp4")], body: .bytes(data))
    }

    /// Streams a segment file, then reports whether it reached the client.
    static func segment(_ url: URL, audio: Bool, completion: @escaping @Sendable (Bool) -> Void) throws -> Response {
        let handle = try FileHandle(forReadingFrom: url)
        let size: Int
        do {
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            try? handle.close()
            throw error
        }
        return Response(
            status: .ok,
            headers: [("Content-Type", audio ? "audio/mp4" : "video/mp4")],
            body: .file(handle, size: size, completion: completion)
        )
    }
}
