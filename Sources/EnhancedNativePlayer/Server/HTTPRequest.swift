import Foundation

/// One HTTP/1.x request head.
struct HTTPRequest: Sendable, Equatable {
    var method: String
    /// The target's path, percent-decoded.
    var path: String
    /// The query parameters, percent-decoded; the first of a repeated name wins.
    var query: [String: String]
    var headers: [(name: String, value: String)]
    /// Whether the client wants the connection kept open after the response.
    var keepAlive: Bool
    /// The length of the body that follows the head.
    var contentLength: Int

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.query == rhs.query
            && lhs.keepAlive == rhs.keepAlive && lhs.contentLength == rhs.contentLength
            && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }
}

enum HTTPRequestParser {
    /// The longest request head accepted.
    static let maxHeadBytes = 64 << 10

    enum Failure: Error, Equatable {
        case malformed
        case headTooLarge
        case unsupportedTransferEncoding

        var status: Response.Status {
            switch self {
            case .malformed: .badRequest
            case .headTooLarge: .requestHeaderFieldsTooLarge
            case .unsupportedTransferEncoding: .notImplemented
            }
        }
    }

    /// Parses the request head at the front of `buffer`. Returns nil while the head is
    /// incomplete, and otherwise the request and the number of head bytes it took.
    static func parse(_ buffer: Data) throws(Failure) -> (request: HTTPRequest, headLength: Int)? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeadBytes { throw .headTooLarge }
            return nil
        }
        let headLength = end.upperBound - buffer.startIndex
        guard headLength <= maxHeadBytes else { throw .headTooLarge }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { throw .malformed }

        var lines = head.components(separatedBy: "\r\n")[...]
        // A client may send empty lines ahead of a request.
        while lines.first?.isEmpty == true { lines = lines.dropFirst() }
        guard let requestLine = lines.popFirst() else { throw .malformed }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { throw .malformed }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw .malformed }

        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" ") else { throw .malformed }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        if let encoding = header("Transfer-Encoding"), encoding.lowercased() != "identity" { throw .unsupportedTransferEncoding }
        var contentLength = 0
        if let value = header("Content-Length") {
            guard let length = Int(value), length >= 0 else { throw .malformed }
            contentLength = length
        }

        let connection = header("Connection")?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")

        // Origin form ("/file?a=b"), or absolute form ("http://host/file?a=b").
        guard let components = URLComponents(string: target) else { throw .malformed }
        guard let path = components.percentEncodedPath.removingPercentEncoding else { throw .malformed }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }

        let request = HTTPRequest(
            method: method,
            path: path.isEmpty ? "/" : path,
            query: query,
            headers: headers,
            keepAlive: keepAlive,
            contentLength: contentLength
        )
        return (request, headLength)
    }
}
