import Foundation

/// The fixed layout of every subtitle playlist. A segment's time follows from its
/// index alone, so its URI needs no `runtimeTicks`.
struct SubtitleGrid: Sendable, Equatable {
    static let segmentTicks: Int64 = 100_000_000

    /// Length of the playlist timeline in 100 ns ticks.
    let totalTicks: Int64

    var count: Int { max(1, Int((totalTicks + Self.segmentTicks - 1) / Self.segmentTicks)) }

    func startTicks(of index: Int) -> Int64 { Int64(index) * Self.segmentTicks }

    func endTicks(of index: Int) -> Int64 { min(totalTicks, startTicks(of: index + 1)) }

    func duration(of index: Int) -> Double { Double(endTicks(of: index) - startTicks(of: index)) / 10_000_000 }
}

struct SubtitleCue: Sendable, Equatable {
    /// Position in the playlist timeline in 100 ns ticks.
    var startTicks: Int64
    var endTicks: Int64
    var text: String
    /// WebVTT cue settings, only from a WebVTT source.
    var settings: String?
}

enum WebVTT {
    /// Local time 0 is the playlist's start, which the media segments carry at the lead-in.
    static let header = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(Timeline.leadInMicroseconds * 90 / 1000),LOCAL:00:00:00.000\n"

    static func document(_ cues: [SubtitleCue]) -> String {
        var text = header
        for cue in cues {
            var timing = "\(timestamp(cue.startTicks)) --> \(timestamp(cue.endTicks))"
            if let settings = cue.settings { timing += " \(settings)" }
            text += "\n\(timing)\n\(cue.text)\n"
        }
        return text
    }

    static func timestamp(_ ticks: Int64) -> String {
        let milliseconds = (ticks + 5_000) / 10_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }

    /// A packet's payload as WebVTT cue text, nil when nothing would be shown.
    static func cueText(payload: [UInt8], format: SubtitleTextFormat) -> String? {
        switch format {
        case .subRip:
            return cleanLines(sanitized(removingOverrides(decoded(payload)), keepingTags: true))
        case .plainText:
            return cleanLines(sanitized(decoded(payload), keepingTags: false))
        case .webVTT:
            return cleanLines(escapingBareAmpersands(decoded(payload)))
        case .movText:
            // A big-endian length, the text, then style boxes.
            guard payload.count >= 2 else { return nil }
            let length = Int(payload[0]) << 8 | Int(payload[1])
            return cleanLines(sanitized(decoded(Array(payload.dropFirst(2).prefix(length))), keepingTags: false))
        }
    }

    private static func decoded(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        // Older SRT files are often Windows-1252, whatever the container claims.
        return String(bytes: trimmed, encoding: .utf8) ?? String(bytes: trimmed, encoding: .windowsCP1252) ?? String(decoding: trimmed, as: UTF8.self)
    }

    /// SRT often carries the ASS leftovers `{\an8}` and `\N`.
    private static func removingOverrides(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{\\") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                rest = rest[open.lowerBound...]
                break
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result.replacingOccurrences(of: "\\N", with: "\n")
    }

    /// Escapes what WebVTT reserves. With `keepingTags`, `<b>`, `<i>` and `<u>` stay and
    /// any other tag (SRT's `<font>`) goes.
    private static func sanitized(_ text: String, keepingTags: Bool) -> String {
        var result = ""
        var rest = Substring(text)
        while let first = rest.first {
            rest = rest.dropFirst()
            switch first {
            case "&": result += "&amp;"
            case ">": result += "&gt;"
            case "<":
                if keepingTags, let close = rest.firstIndex(of: ">"), let tag = tag(rest[..<close]) {
                    result += tag
                    rest = rest[rest.index(after: close)...]
                } else {
                    result += "&lt;"
                }
            default: result.append(first)
            }
        }
        return result
    }

    /// A WebVTT payload is already markup, but muxers do write a raw `&`, and AVPlayer
    /// drops one that doesn't start an entity.
    private static func escapingBareAmpersands(_ text: String) -> String {
        let entities = ["amp;", "lt;", "gt;", "lrm;", "rlm;", "nbsp;"]
        let parts = text.components(separatedBy: "&")
        return parts.dropFirst().reduce(parts[0]) { result, part in
            result + (entities.contains { part.hasPrefix($0) } ? "&" : "&amp;") + part
        }
    }

    /// What a tag's inside becomes: itself, nothing, or nil when it isn't a tag at all.
    private static func tag(_ inside: Substring) -> String? {
        let closing = inside.hasPrefix("/")
        let body = closing ? inside.dropFirst() : inside
        guard let first = body.first, first.isLetter, !body.contains("<") else { return nil }
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
        return ["b", "i", "u"].contains(name) ? "<\(closing ? "/" : "")\(name)>" : ""
    }

    /// A blank line would end the cue early.
    private static func cleanLines(_ text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
